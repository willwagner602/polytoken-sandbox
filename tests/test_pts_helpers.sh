#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/polytoken-sandbox.sh"

test_slug_hash() {
  local p="/tmp/project with punctuation!"
  [[ "$(_pts_project_slug "$p")" == project-with-punctuation ]]
  [[ "$(_pts_project_hash "$p")" =~ ^[0-9a-f]{16}$ ]]
  [[ "$(_pts_name "$p" "$(_pts_project_hash "$p")")" != "$(_pts_name "$p" "$(_pts_project_hash "$p")")" ]]
}

test_no_unsafe_operations() {
  ! grep -Eq 'pkill|killall|podman (stop|kill|rm)[^|;&]*\*' "$root/polytoken-sandbox.sh"
  grep -Fq -- '--init' "$root/polytoken-sandbox.sh"
  grep -Fq -- 'podman create -it' "$root/polytoken-sandbox.sh"
  grep -Fq -- 'podman start -ai --sig-proxy=true' "$root/polytoken-sandbox.sh"
  grep -Fq -- 'podman attach --sig-proxy=true "$full"' "$root/polytoken-sandbox.sh"
  ! grep -Fq -- 'exec podman attach' "$root/polytoken-sandbox.sh"
  grep -Fq -- "printf 'pts: container=%s id=%.12s" "$root/polytoken-sandbox.sh"
  ! grep -Fq -- "pids=%s\\n' \\\\" "$root/polytoken-sandbox.sh"
  ! grep -Fq -- 'podman run --rm -it \\' "$root/polytoken-sandbox.sh"
  ! grep -Eq -- '-e GH_TOKEN=' "$root/polytoken-sandbox.sh"
  grep -Fq -- 'local -x GH_TOKEN="$gh_token"' "$root/polytoken-sandbox.sh"
  ! grep -Fq -- 'GH_TOKEN="$gh_token" container_id=' "$root/polytoken-sandbox.sh"
  grep -Fq -- 'trap _pts_owner_signal HUP TERM INT' "$root/polytoken-sandbox.sh"
  ! grep -Fq -- '_pts_forward_int' "$root/polytoken-sandbox.sh"
  grep -Fq -- 'polytoken_args=(continue)' "$root/polytoken-sandbox.sh"
  grep -Fq -- 'sh "${polytoken_args[@]}"' "$root/polytoken-sandbox.sh"
}

test_management_is_early() {
  local dispatch setup
  dispatch="$(grep -n 'local management_command' "$root/polytoken-sandbox.sh" | cut -d: -f1)"
  setup="$(grep -n 'podman image exists' "$root/polytoken-sandbox.sh" | head -1 | cut -d: -f1)"
  (( dispatch < setup ))
}

test_github_token_precedence() {
  gh() {
    [[ "$*" == 'auth token' ]] || return 1
    printf 'gh-cli-token'
  }

  [[ "$(GH_TOKEN=explicit-gh GITHUB_TOKEN=explicit-github _pts_github_token)" == explicit-gh ]]
  [[ "$(GH_TOKEN= GITHUB_TOKEN=explicit-github _pts_github_token)" == explicit-github ]]
  [[ "$(GH_TOKEN= GITHUB_TOKEN= _pts_github_token)" == gh-cli-token ]]
}

test_fake_podman_resolution_and_stop() {
  local calls=() state='running'
  podman() {
    calls+=("$*")
    case "$1" in
      ps) printf 'full-one\nfull-two\n' ;;
      inspect)
        if [[ "$*" == *full-one* ]]; then
          printf 'full-one\t/pts-one\t%s\t0\thash\t/project\t/project\t12g\t16g\t2048\ttrue\t1\n' "$state"
        else
          printf 'full-two\t/pts-two\trunning\t0\thash\t/project\t/project\t12g\t16g\t2048\ttrue\t1\n'
        fi
        ;;
      stop|kill|rm) [[ "$2" == full-one || "$3" == full-one ]] ;;
    esac
  }
  [[ "$(_pts_resolve pts-one '')" == full-one ]] 
  if _pts_resolve full </dev/null 2>/dev/null; then return 1; fi
  PTS_STOP_TIMEOUT=0 PTS_DIAG_PROJECT="$(mktemp -d)" _pts_stop_exact full-one
  printf '%s\n' "${calls[@]}" | grep -Fq 'stop --time 0 full-one'
  printf '%s\n' "${calls[@]}" | grep -Fq 'rm full-one'
}

test_diagnostics_do_not_dump_environment() {
  local d
  d="$(mktemp -d)"
  podman() {
    case "$1" in
      inspect) printf 'full-one\t/pts-one\texited\t1\thash\t%s\t%s\t12g\t16g\t2048\ttrue\t1\n' "$d" "$d" ;;
      stats) printf 'safe-stat\nSECRET_FROM_STATS_SHOULD_NOT_APPEAR\n' ;;
      ps) printf 'full-one\n' ;;
    esac
  }
  _pts_diag full-one "$d"
  ! grep -R -Fq SECRET_FROM_STATS_SHOULD_NOT_APPEAR "$d/.polytoken/pts/diagnostics" 2>/dev/null
  rm -rf "$d"
}

test_docs_contract() {
  for f in README.md PTS-CONTAINER.md POLYTOKEN-REPO.md; do
    grep -Fq 'PTS_MEMORY' "$root/$f"
    grep -Fq 'pts diagnose' "$root/$f"
    grep -Fq 'detach' "$root/$f"
    grep -Fq 'continue' "$root/$f"
  done
}

test_slug_hash
test_no_unsafe_operations
test_management_is_early
test_github_token_precedence
test_fake_podman_resolution_and_stop
test_diagnostics_do_not_dump_environment
test_docs_contract
printf 'PTS helper contract checks passed\n'
