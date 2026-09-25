#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/polytoken-sandbox.sh"

# Behavioral coverage for what the source-text pins in test_pts_helpers.sh
# cannot prove: management-command dispatch against a fake Podman inventory,
# the generated `podman create` argv (credential-refresh wiring, reference-
# only env passing, seed-script integrity, trusted-volume passthrough), and
# stale project-image pruning. The fake podman appends every invocation to a
# file so calls made inside process/command substitutions survive.

test_management_dispatch() {
  local d scratch calls out fakebin
  d="$(mktemp -d)"
  scratch="$(mktemp -d)"
  calls="$scratch/calls"
  : >"$calls"
  _TEST_CALLS="$calls" _TEST_STATE=running _TEST_DIR="$d"
  podman() {
    printf '%s\n' "$*" >>"$_TEST_CALLS"
    case "$1" in
      ps)
        if [[ "$*" == *'--format {{.ID}}'* ]]; then
          printf 'full-one\n'
        fi
        ;;
      inspect)
        if [[ "$*" == *'--format {{.State.Status}}'* ]]; then
          printf '%s\n' "$_TEST_STATE"
        else
          printf 'full-one\t/pts-one\t%s\t0\t%s\t%s\t%s\t12g\t16g\t2048\ttrue\t1\n' \
            "$_TEST_STATE" "$(_pts_project_hash "$_TEST_DIR")" "$_TEST_DIR" "$_TEST_DIR"
        fi
        ;;
      stats|stop|kill|rm|rmi|images) : ;;
    esac
    return 0
  }

  # ps: inventory query is label-filtered; the table shows the container.
  out="$(cd "$d" && _pts_management ps)"
  [[ "$out" == *pts-one* ]]
  grep -Fq -- '--filter label=pts.owner=polytoken.pts --format {{.ID}}' "$calls"

  # stats: the exact resolved ID reaches `podman stats --no-stream` (exec
  # path — swap the function for a fake executable that also serves the
  # inventory/inspect queries resolution needs, so exec is observable).
  fakebin="$scratch/bin"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%s\ncase "$1" in\n  ps) [ "$2" = -a ] && printf "full-one\\n" ;;\n  inspect) printf "full-one\\t/pts-one\\texited\\t0\\t%s\\t%s\\t%s\\t12g\\t16g\\t2048\\ttrue\\t1\\n" ;;\nesac\nexit 0\n' \
    "$calls" "$(_pts_project_hash "$d")" "$d" "$d" >"$fakebin/podman"
  chmod +x "$fakebin/podman"
  (cd "$d" && unset -f podman && PATH="$fakebin:$PATH" _pts_management stats full-one)
  grep -Fq -- 'stats --no-stream full-one' "$calls"

  # stop on an exited container: exact ID, no kill, no diagnostics.
  : >"$calls"
  _TEST_STATE=exited
  (cd "$d" && PTS_DIAG_PROJECT="$scratch" _pts_management stop full-one) >/dev/null 2>&1
  grep -Fq -- 'stop --time 10 full-one' "$calls"
  grep -Fq -- 'rm full-one' "$calls"
  ! grep -Fq -- 'kill full-one' "$calls"

  # stop on a still-running container escalates: diagnostics, kill, rm.
  : >"$calls"
  _TEST_STATE=running
  (cd "$d" && PTS_DIAG_PROJECT="$scratch" _pts_management stop full-one) >/dev/null 2>&1
  grep -Fq -- 'stats --no-stream full-one' "$calls"
  grep -Fq -- 'kill full-one' "$calls"
  grep -Fq -- 'rm full-one' "$calls"

  # attach to a non-running container refuses rather than calling attach.
  _TEST_STATE=exited
  if (cd "$d" && _pts_management attach full-one) 2>/dev/null; then
    echo 'FAIL: attach to exited container should fail' >&2
    return 1
  fi
  ! grep -Fq -- 'attach --sig-proxy=true' "$calls"
}

test_prune_removes_stale_images() {
  local d scratch calls ph
  d="$(mktemp -d)"
  scratch="$(mktemp -d)"
  calls="$scratch/calls"
  : >"$calls"
  ph="$(_pts_project_hash "$d")"
  _TEST_CALLS="$calls" _TEST_STATE=exited _TEST_DIR="$d" _TEST_PODMAN_IMAGES=1
  podman() {
    printf '%s\n' "$*" >>"$_TEST_CALLS"
    case "$1" in
      ps)
        if [[ "$*" == *'--format {{.ID}}'* ]]; then
          printf 'full-one\n'
        fi
        ;;
      inspect)
        printf 'full-one\t/pts-one\t%s\t0\t%s\t%s\t%s\t12g\t16g\t2048\ttrue\t1\n' \
          "$_TEST_STATE" "$(_pts_project_hash "$_TEST_DIR")" "$_TEST_DIR" "$_TEST_DIR"
        ;;
      images)
        # Newest first: current context tag, a stale older tag, and another
        # project's only (newest) tag.
        printf '%s\n' \
          "localhost/polytoken-sandbox-$ph-1111111111111112:latest" \
          "localhost/polytoken-sandbox-$ph-1111111111111111:latest" \
          'localhost/polytoken-sandbox-cccccccccccccccc-2222222222222222:latest'
        ;;
      rm|rmi) : ;;
    esac
    return 0
  }
  printf 'y\ny\n' | (cd "$d" && _pts_management prune) >/dev/null 2>&1
  grep -Fq -- 'rm full-one' "$calls"
  grep -Fq -- "rmi localhost/polytoken-sandbox-$ph-1111111111111111:latest" "$calls"
  ! grep -Fq -- "rmi localhost/polytoken-sandbox-$ph-1111111111111112:latest" "$calls"
  ! grep -Fq -- 'rmi localhost/polytoken-sandbox-cccccccccccccccc' "$calls"
}

# Runs a full (fake-Podman) `pts` launch in a controlled HOME/project and
# asserts the generated `podman create` argv: refreshed credentials arrive
# via the environment, env keys are passed by reference (never literals),
# trusted volumes pass through verbatim, labels carry the project hash, the
# embedded seed script stays a syntactically valid shell payload, and the
# polytoken argument wiring lands as `sh continue`.
test_pts_create_argv_wiring() {
  local d home state scratch calls ph trust_dir marker
  d="$(mktemp -d)"
  home="$(mktemp -d)"
  state="$(mktemp -d)"
  scratch="$(mktemp -d)"
  calls="$scratch/calls"
  : >"$calls"
  ph="$(_pts_project_hash "$d")"

  # Every ~/.bashrc assignment form the refresh must understand.
  {
    echo 'export OPENAI_API_KEY="dq-key"'
    echo "export ANTHROPIC_API_KEY='sq-key'"
    echo 'export ZAI_API_KEY=uq-key'
    echo 'EXA_API_KEY=two-step'
    echo 'export EXA_API_KEY'
  } >"$home/.bashrc"

  # Trusted extra mounts, including blank and comment lines that must be
  # skipped without producing argv entries. The configured shared workspace
  # should also be mounted, but only when it exists.
  mkdir -p "$d/.polytoken" "$home/work/docker_files" /tmp/pts-test-vol-a /tmp/pts-test-vol-b
  printf '# comment\n\n/tmp/pts-test-vol-a:/mnt/vola:ro\n/tmp/pts-test-vol-b:/mnt/volb\n' >"$d/.polytoken/volumes"
  trust_dir="$state/polytoken/pts/trust"
  mkdir -p -m 700 "$trust_dir"
  marker="$trust_dir/$(_pts_project_hash "$d/.polytoken")-volumes.sha256"
  (umask 077; printf '%s\n' "$(sha256sum "$d/.polytoken/volumes" | cut -d' ' -f1)" >"$marker")

  _TEST_CALLS="$calls" _TEST_STATE=exited _TEST_DIR="$d" _TEST_DIR_HASH="$ph"
  podman() {
    printf '%s\n' "$*" >>"$_TEST_CALLS"
    case "$1" in
      ps) [[ "$*" == *'--format {{.ID}}'* ]] || true ;;
      image) return 0 ;;
      run) return 0 ;;
      --version) printf 'podman version 5.2.0\n' ;;
      inspect)
        if [[ "$*" == *'--format {{.State.Status}}'* ]]; then
          printf 'exited\n'
        else
          printf 'created-full-idx\t/pts-one\t%s\t0\t%s\t%s\t%s\t12g\t16g\t2048\ttrue\t1\n' \
            "$_TEST_STATE" "$_TEST_DIR_HASH" "$_TEST_DIR" "$_TEST_DIR"
        fi
        ;;
      create)
        local i prev='' script=''
        for i in "$@"; do
          [[ "$prev" == -c ]] && script="$i"
          prev="$i"
        done
        if [[ "${OPENAI_API_KEY:-}" != dq-key ]]; then echo 'FAIL: double-quoted export not refreshed' >&2; exit 9; fi
        if [[ "${ANTHROPIC_API_KEY:-}" != sq-key ]]; then echo 'FAIL: single-quoted export not refreshed' >&2; exit 9; fi
        if [[ "${ZAI_API_KEY:-}" != uq-key ]]; then echo 'FAIL: unquoted export not refreshed' >&2; exit 9; fi
        if [[ "${EXA_API_KEY:-}" != two-step ]]; then echo 'FAIL: assignment-then-export not refreshed' >&2; exit 9; fi
        if [[ -n "${KAGI_API_KEY:-}" ]]; then echo 'FAIL: key absent from bashrc must be unset' >&2; exit 9; fi
        if [[ "$*" != *'-e OPENAI_API_KEY -e ANTHROPIC_API_KEY'* ]]; then echo 'FAIL: env keys not passed by reference' >&2; exit 9; fi
        if [[ "$*" == *'OPENAI_API_KEY='* ]]; then echo 'FAIL: literal key value leaked into argv' >&2; exit 9; fi
        if [[ "$*" == *'-e GH_TOKEN='* ]]; then echo 'FAIL: literal GH token in argv' >&2; exit 9; fi
        if [[ "$*" != *'-v /tmp/pts-test-vol-a:/mnt/vola:ro -v /tmp/pts-test-vol-b:/mnt/volb'* ]]; then echo 'FAIL: trusted volumes not passed verbatim' >&2; exit 9; fi
        if [[ "$*" != *"-v $HOME/work/docker_files:$HOME/work/docker_files"* ]]; then echo 'FAIL: shared docker_files workspace not mounted' >&2; exit 9; fi
        if [[ "$*" != *"pts.project-hash=$_TEST_DIR_HASH"* ]]; then echo 'FAIL: project-hash label missing' >&2; exit 9; fi
        if [[ "$*" != *'GIT_CONFIG_COUNT=2'* ]]; then echo 'FAIL: git identity env wiring changed' >&2; exit 9; fi
        if [[ "$*" == *'--network=host'* ]]; then echo 'FAIL: outer PTS must own a private network namespace for nested Docker' >&2; exit 9; fi
        if [[ -z "$script" ]]; then echo 'FAIL: no -c seed script in argv' >&2; exit 9; fi
        if ! printf '%s\n' "$script" | sh -n; then echo 'FAIL: seed script is not valid shell' >&2; exit 9; fi
        if [[ "$script" != *'export DOCKER_CONFIG="$HOME/.docker"'* || "$script" != *'chown "${PTS_UID:-$(id -u)}:${PTS_GID:-$(id -g)}" "$DOCKER_CONFIG"'* ]]; then echo 'FAIL: writable project Docker config wiring changed' >&2; exit 9; fi
        if [[ "$script" != *'[ -e /opt/polytoken-bin/polytoken ]'* || "$script" != *'chown "${PTS_UID:-$(id -u)}:${PTS_GID:-$(id -g)}" /opt/polytoken-bin/polytoken'* ]]; then echo 'FAIL: Polytoken binary ownership not prepared for self-update' >&2; exit 9; fi
        if [[ "$script" != *'exec setpriv --reuid'* ]]; then echo 'FAIL: seed script lost its setpriv exec' >&2; exit 9; fi
        if [[ "${*: -1}" != continue || "${*: -2:1}" != sh ]]; then echo 'FAIL: polytoken args wiring changed' >&2; exit 9; fi
        printf 'created-full-idx\n'
        ;;
      start|stop|kill|rm|stats|rmi|images) : ;;
    esac
    return 0
  }

  (
    cd "$d"
    gh() { return 1; }
    HOME="$home" XDG_STATE_HOME="$state" GH_TOKEN= GITHUB_TOKEN= pts
  ) >"$scratch/out.log" 2>&1 || { cat "$scratch/out.log" >&2; return 1; }
  grep -Fq -- 'create -it' "$calls"
  grep -Fq -- 'start -ai --sig-proxy=true created-full-idx' "$calls"
}

# A trusted volumes file containing a denylisted host path must abort the
# launch before any `podman create` happens.
test_pts_refuses_unsafe_volumes() {
  local d home state scratch calls trust_dir marker
  d="$(mktemp -d)"
  home="$(mktemp -d)"
  state="$(mktemp -d)"
  scratch="$(mktemp -d)"
  calls="$scratch/calls"
  : >"$calls"
  mkdir -p "$d/.polytoken"
  printf '/tmp:/mnt/evil\n' >"$d/.polytoken/volumes"
  trust_dir="$state/polytoken/pts/trust"
  mkdir -p -m 700 "$trust_dir"
  marker="$trust_dir/$(_pts_project_hash "$d/.polytoken")-volumes.sha256"
  (umask 077; printf '%s\n' "$(sha256sum "$d/.polytoken/volumes" | cut -d' ' -f1)" >"$marker")

  _TEST_CALLS="$calls" _TEST_STATE=exited _TEST_DIR="$d" _TEST_DIR_HASH="$(_pts_project_hash "$d")"
  podman() {
    printf '%s\n' "$*" >>"$_TEST_CALLS"
    case "$1" in
      ps) : ;;
      image|run) return 0 ;;
      --version) printf 'podman version 5.2.0\n' ;;
      inspect) : ;;
      create|start|rm|stats) : ;;
    esac
    return 0
  }

  if (
    cd "$d"
    gh() { return 1; }
    HOME="$home" XDG_STATE_HOME="$state" pts
  ) >"$scratch/out.log" 2>&1; then
    cat "$scratch/out.log" >&2
    echo 'FAIL: unsafe volume specification must abort the launch' >&2
    return 1
  fi
  grep -Fq 'refusing unsafe volume specification' "$scratch/out.log"
  ! grep -Fq -- 'create -it' "$calls"
}

test_management_dispatch
test_prune_removes_stale_images
test_pts_create_argv_wiring
test_pts_refuses_unsafe_volumes
printf 'PTS behavioral (fake-Podman) checks passed\n'
