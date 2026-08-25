#!/bin/bash
# polytoken-sandbox.sh
#
# Defines `pts` — runs polytoken inside a podman container.
#
# The container only mounts the invocation directory (read/write), the
# ~/.job_digest/secrets.json file (read-only), and a persistent named volume
# holding the polytoken binary — not the rest of $HOME. Polytoken's own
# config/cache/auth/session state lives in a `.polytoken/` dir under the
# invocation directory, so it persists per-project across runs. Shares the
# host network so LLM API calls work normally.
#
# The polytoken binary lives in the `polytoken-sandbox-bin` named volume,
# shared across every project (like the image) rather than mounted from the
# host. It's seeded once from ~/.local/bin/polytoken the first time the
# volume is empty; after that the container maintains its own copy,
# decoupled from the host binary. Run `pts update` to upgrade it in place —
# that self-update persists in the volume across --rm'd container runs.
#
# Runs --privileged so nested `docker`/`podman` (installed in the image) can
# actually start containers, not just run as CLIs — genuine nested container
# execution needs real host-level capabilities (kernel module access, device
# nodes, a real subordinate-uid delegation) that a plain rootless container
# can't grant itself, no matter how its --userns/capabilities/subuid are
# configured (tried; see the Containerfile's comment on this for what was
# ruled out and why). This is a deliberate, real reduction in this sandbox's
# isolation from the host — accepted in exchange for nested containers
# working, not an oversight.
#
# Usage:
#   pts                  # run polytoken (TUI) in the sandbox
#   pts --print-session  # pass arguments through to polytoken
#
# Requirements: podman installed and configured for rootless use.

# Copies Ponytail's hook script, hook wiring, and default-mode config into
# the per-project polytoken config dir, plus this repo's own root AGENTS.md
# (the "lazy senior dev" instructions the hook injects). Extracted from
# pts() so it can be exercised directly against a scratch directory in
# ponytail/tests/test_sandbox_staging.sh without needing podman.
_pts_stage_ponytail() {
    local global_config_dir="$1"
    mkdir -p "$global_config_dir"
    cp "$HOME/.bashrc.d/polytoken-sandbox/AGENTS.md" "$global_config_dir/AGENTS.md"
    mkdir -p "$global_config_dir/hooks"
    cp "$HOME/.bashrc.d/polytoken-sandbox/ponytail/hooks/ponytail-hook.sh" "$global_config_dir/hooks/ponytail-hook.sh"
    chmod 755 "$global_config_dir/hooks/ponytail-hook.sh"
    cp "$HOME/.bashrc.d/polytoken-sandbox/ponytail/hooks.json" "$global_config_dir/hooks.json"
    cp "$HOME/.bashrc.d/polytoken-sandbox/ponytail/config.json" "$global_config_dir/ponytail-config.json"
}

# Gates a project-local `.polytoken/` extension file (Containerfile or
# volumes) behind one-time interactive confirmation before it's built/mounted
# — without this, cloning an untrusted repo and running `pts` inside it lets
# that repo silently extend the image or bind-mount arbitrary host paths
# (e.g. a `.polytoken/volumes` line of `/:/hostroot`) into an already
# --privileged container with live API keys and a GitHub token. Approval is
# pinned to a sha256 of the file's content, not just "this project", in a
# marker alongside it — so editing the file after approval (a supply-chain
# swap: get a benign version trusted once, then change it) re-prompts rather
# than silently inheriting the old trust decision. Markers live under
# `.polytoken/` (gitignored, per-project, never committed).
_pts_confirm_trust() {
    local target_file="$1" reason="$2"
    local trust_marker="$target_file.trusted-sha256"
    local current_hash
    current_hash="$(sha256sum "$target_file" | cut -d' ' -f1)"
    if [[ -f "$trust_marker" && "$(<"$trust_marker")" == "$current_hash" ]]; then
        return 0
    fi
    echo "pts: $target_file $reason" >&2
    # Bounded, not unconditional: EOF (piped/closed stdin) returns immediately
    # (declined); a genuinely interactive terminal gets up to 30s to answer;
    # an inherited-but-silent stream (e.g. backgrounded invocation) times out
    # rather than hanging forever.
    local reply=""
    read -r -t 30 -p "pts: trust and apply this file? [y/N] " reply || true
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        printf '%s\n' "$current_hash" >"$trust_marker"
        return 0
    fi
    echo "pts: not trusted — skipping $target_file for this run." >&2
    return 1
}

pts() {
    if ! command -v podman &>/dev/null; then
        echo "Error: podman is not installed or not on PATH" >&2
        return 1
    fi

    local base_image="localhost/polytoken-sandbox:latest"

    # Build the shared sandbox image (fedora-minimal + python3) on first
    # run. Cached afterwards; rebuild manually with:
    #   podman build -t localhost/polytoken-sandbox:latest ~/.bashrc.d/polytoken-sandbox
    #
    # The Containerfile lives in a subdirectory (not directly in
    # ~/.bashrc.d/) so ~/.bashrc's `for rc in ~/.bashrc.d/*` loop doesn't
    # try to source it as a shell script.
    if ! podman image exists "$base_image" 2>/dev/null; then
        echo "Building sandbox image (one-time setup)..." >&2
        podman build -t "$base_image" "$HOME/.bashrc.d/polytoken-sandbox" >&2 || return 1
    fi

    local workdir
    workdir="$(pwd)"

    # A project can extend the shared image by committing its own
    # `.polytoken/Containerfile` (FROM localhost/polytoken-sandbox:latest,
    # plus whatever extra packages that project needs). When present, it's
    # built into a separate image tagged by directory name and used instead
    # of the shared image — every other project keeps using the untouched
    # shared image. Cached afterwards; rebuild manually with:
    #   podman build -t localhost/polytoken-sandbox-<dirname>:latest -f .polytoken/Containerfile .polytoken
    local image="$base_image"
    local project_containerfile="$workdir/.polytoken/Containerfile"
    if [[ -f "$project_containerfile" ]] && _pts_confirm_trust "$project_containerfile" \
        "will be built and used as this project's sandbox image"; then
        image="localhost/polytoken-sandbox-$(basename "$workdir"):latest"
        if ! podman image exists "$image" 2>/dev/null; then
            echo "Building project sandbox image (one-time setup)..." >&2
            podman build -t "$image" -f "$project_containerfile" "$(dirname "$project_containerfile")" >&2 || return 1
        fi
    fi

    # Polytoken state (cache/auth/sessions) lives under the invocation
    # directory, not $HOME, so it's per-project. config.yaml is re-synced
    # from the template on every run (not just the first) so provider/
    # integration changes here always reach every project — it references
    # provider keys via ${OPENAI_API_KEY} etc. (polytoken supports env-var
    # interpolation in `auth.key`), which are already passed into the
    # container below, so no literal key is ever duplicated across project
    # directories. Do not hand-edit a project's config.yaml — it's
    # overwritten on the next `pts` invocation.
    local state_dir="$workdir/.polytoken"
    local global_config_dir="$state_dir/.config/polytoken"
    local project_config="$global_config_dir/config.yaml"
    mkdir -p "$global_config_dir"
    cp "$HOME/.bashrc.d/polytoken-sandbox/config-template.yaml" "$project_config"
    _pts_stage_ponytail "$global_config_dir"

    # Polytoken auto-discovers project context from a file named AGENTS.md
    # in the project root (Claude Code's equivalent is CLAUDE.md). If a
    # project already has a CLAUDE.md and no AGENTS.md yet, symlink one to
    # the other so polytoken ingests the same context automatically on
    # every run, instead of it needing to be re-explained each session.
    # Never overwrites an AGENTS.md that's already there (hand-authored or
    # from a previous run).
    if [[ -f "$workdir/CLAUDE.md" && ! -e "$workdir/AGENTS.md" ]]; then
        ln -s CLAUDE.md "$workdir/AGENTS.md"
    fi

    # Ensure the polytoken-binary volume exists and is owned by the
    # invoking host user (rather than root/uid-0 in the rootless
    # namespace), so the --userns=keep-id container can write the
    # seeded/self-updated binary into it. Deliberately NOT world-writable
    # (no chmod 1777 etc.): polytoken's own self-updater refuses to write
    # into a group/world-writable directory as a TOCTOU safety check, so
    # ownership — not permissive mode bits — is what has to grant the
    # write access.
    #
    # The chown has to happen inside a *plain* rootless container (no
    # --userns=keep-id), running as its default uid 0. Podman's default
    # rootless mapping identity-maps container uid 0 to the real host uid,
    # so `chown 0:0` there writes your real host uid to disk — which is
    # exactly the uid a later --userns=keep-id container expects to see
    # (keep-id identity-maps that same real host uid to itself). Using
    # `podman unshare chown $(id -u)` instead is a common-looking but
    # *wrong* fix here: podman unshare's own uid-0 identity-maps to the
    # real host uid, but non-zero requested uids like $(id -u) get run
    # through the subuid table instead, landing on some unrelated
    # subordinate uid rather than your real one — it looked like it worked
    # (no error) but silently produced a directory owned by the wrong uid.
    # Cheap and idempotent, so it's safe to redo on every invocation.
    local bin_volume="polytoken-sandbox-bin"
    podman run --rm -v "$bin_volume:/opt/polytoken-bin" \
        --entrypoint /bin/sh "$image" -c 'chown 0:0 /opt/polytoken-bin' >/dev/null

    # Codex (OpenAI's device-code OAuth login, not a static API key — see
    # config-template.yaml's `codex` provider) stores its auth token under
    # Polytoken's global host data directory. Bind-mount that directory into
    # the container so one `polytoken auth provider login` works both outside
    # and inside pts. It is intentionally read/write because Polytoken may
    # refresh the token; other auth/session state remains per-project.
    local codex_auth_host_dir="$HOME/.local/share/polytoken/auth/codex"
    local codex_auth_dir="$state_dir/.local/share/polytoken/auth/codex"
    mkdir -p "$codex_auth_host_dir" "$codex_auth_dir"

    # OpenAI Codex CLI keeps its ChatGPT/subscription login and CLI state in
    # ~/.codex. Mount the host directory into the container's effective HOME
    # so `codex` can reuse and refresh the host login across PTS projects.
    # This is separate from Polytoken's auth store above.
    local codex_cli_host_dir="$HOME/.codex"
    local codex_cli_dir="$state_dir/.codex"
    mkdir -p "$codex_cli_host_dir" "$codex_cli_dir"

    # NineAngel ("angel") is a multi-persona code-review skill, adapted from
    # github.com/PropterMalone/NineAngel (vendored as a pinned git submodule
    # at angel/vendor/nineangel/, upstream's own Claude-Code-specific
    # orchestration rewritten for polytoken's skill/subagent model — see
    # angel/skills/angel/SKILL.md). It's made available in every project the
    # same way as everything else here: a read-only bind mount, not a
    # per-project copy. Unlike the codex-auth volume, nothing inside the
    # container ever writes to these paths, so no named volume or ownership
    # fix is needed — a plain read-only bind of the dotfiles-tracked
    # directory is enough. This occupies polytoken's only discovery tier for
    # subagents (project-local `.polytoken/subagents/`, no global tier
    # exists) and skills' effectively-only-usable tier under pts's own HOME
    # redirection — a project can't layer its own additional subagent
    # alongside Angel's without further plumbing (accepted tradeoff).
    # Angel's own per-project run/memory state (read-write, NOT mounted —
    # this container writes here) lives under .polytoken/angel/.
    local angel_skills_dir="$HOME/.bashrc.d/polytoken-sandbox/angel/skills"
    local angel_subagents_dir="$HOME/.bashrc.d/polytoken-sandbox/angel/subagents"
    mkdir -p "$state_dir/skills" "$state_dir/subagents" "$state_dir/angel/memory"

    # Only the invocation directory (which contains the polytoken state
    # dir above), the polytoken-binary volume, and the job-digest secrets
    # file are exposed — not the rest of $HOME.
    #
    # The host binary is mounted read-only too, but only as a seed source:
    # the entrypoint below copies it into the named volume the first time
    # the volume is empty, then always runs the volume's copy. If the host
    # binary isn't installed, the seed mount is skipped and the volume must
    # already be populated (e.g. from a previous run).
    local secrets_file="$HOME/.job_digest/secrets.json"
    local -a volumes=(
        -v "$workdir:$workdir"
        -v "polytoken-sandbox-bin:/opt/polytoken-bin"
        -v "$codex_auth_host_dir:$codex_auth_dir"
        -v "$codex_cli_host_dir:$codex_cli_dir"
        -v "$angel_skills_dir:$state_dir/skills:ro"
        -v "$angel_subagents_dir:$state_dir/subagents:ro"
    )
    local host_binary="$HOME/.local/bin/polytoken"
    if [[ -f "$host_binary" ]]; then
        volumes+=(-v "$host_binary:/opt/polytoken-seed/polytoken:ro")
    fi
    if [[ -f "$secrets_file" ]]; then
        volumes+=(-v "$secrets_file:$secrets_file:ro")
    fi

    # A project can also mount extra host paths (e.g. external media) by
    # committing a `.polytoken/volumes` file: one `-v`-style mount spec per
    # line (HOST:CONTAINER[:OPTS]), passed straight through to `podman run
    # -v`. Only used when present, so this is opt-in per project.
    local project_volumes="$workdir/.polytoken/volumes"
    if [[ -f "$project_volumes" ]] && _pts_confirm_trust "$project_volumes" \
        "will have every line bind-mounted verbatim into this --privileged container"; then
        local _volume_line
        while IFS= read -r _volume_line || [[ -n "$_volume_line" ]]; do
            [[ -z "$_volume_line" ]] && continue
            volumes+=(-v "$_volume_line")
        done <"$project_volumes"
        unset _volume_line
    fi

    # Reload provider keys fresh from ~/.bashrc (the canonical source) on
    # every invocation, rather than trusting this shell's inherited env
    # vars — a long-lived shell can hold stale values from before a key
    # was rotated, since export only happens once at shell startup.
    local -a _key_names=(OPENAI_API_KEY ANTHROPIC_API_KEY ZAI_API_KEY NEURALWATT_API_KEY OPENCODE_API_KEY BRAVE_API_KEY TAVILY_API_KEY EXA_API_KEY KAGI_API_KEY)
    local _k _v
    for _k in "${_key_names[@]}"; do
        _v="$(grep -oP "(?<=export ${_k}=\")[^\"]*" "$HOME/.bashrc" 2>/dev/null | tail -n1)"
        [[ -n "$_v" ]] && export "$_k=$_v"
    done
    unset _k _v _key_names

    # Fetch the GitHub token fresh each run (never cached to disk or shell
    # env) and wire it up as a git credential helper via GIT_CONFIG_*, so
    # the host's ~/.gitconfig (whose helper calls the host's `gh`, and
    # isn't mounted into the container) is never touched. The same
    # GH_TOKEN also auto-authenticates the container's own `gh` CLI.
    local gh_token=""
    if command -v gh &>/dev/null; then
        gh_token="$(gh auth token 2>/dev/null)"
    fi

    # Git identity for commits made inside the container. Wired via
    # GIT_CONFIG_* rather than mounting the host's ~/.gitconfig, since
    # $HOME inside the container points at the project's .polytoken/ dir
    # instead. Hardcoded rather than read from `git config` each run.
    local git_user_name="Will Wagner"
    local git_user_email="willwagner602@users.noreply.github.com"

    local -a git_env=()
    local -i _cfg_count=0
    if [[ -n "$gh_token" ]]; then
        git_env+=(
            -e GH_TOKEN="$gh_token"
            -e GIT_CONFIG_KEY_${_cfg_count}="credential.https://github.com.helper"
            -e GIT_CONFIG_VALUE_${_cfg_count}=""
        )
        ((_cfg_count++))
        git_env+=(
            -e GIT_CONFIG_KEY_${_cfg_count}="credential.https://github.com.helper"
            -e GIT_CONFIG_VALUE_${_cfg_count}='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
        )
        ((_cfg_count++))
    fi
    if [[ -n "$git_user_name" ]]; then
        git_env+=(
            -e GIT_CONFIG_KEY_${_cfg_count}="user.name"
            -e GIT_CONFIG_VALUE_${_cfg_count}="$git_user_name"
        )
        ((_cfg_count++))
    fi
    if [[ -n "$git_user_email" ]]; then
        git_env+=(
            -e GIT_CONFIG_KEY_${_cfg_count}="user.email"
            -e GIT_CONFIG_VALUE_${_cfg_count}="$git_user_email"
        )
        ((_cfg_count++))
    fi
    if ((_cfg_count > 0)); then
        git_env+=(-e GIT_CONFIG_COUNT="$_cfg_count")
    fi

    # The volume's copy of polytoken is what actually runs. If it's not
    # there yet (first-ever run, or the volume was pruned), seed it from the
    # host binary mount above. Once seeded, `pts update` self-updates this
    # copy in place — the host binary is never touched or consulted again.
    #
    # Before actually launching the requested command, opportunistically
    # check whether Codex (the default provider — see config-template.yaml)
    # is logged in, and kick off its interactive device-code login if not.
    # `polytoken auth provider status` always exits 0 regardless of auth
    # state, so login-ness has to be sniffed from its text output rather
    # than its exit code. Skipped for `pts auth ...` (avoid interfering
    # with the user driving auth commands themselves, e.g. re-running login
    # with --force) and `pts update` (self-update shouldn't be gated on an
    # unrelated provider's auth). A failed/declined login doesn't abort
    # `pts` — it just falls through to launching polytoken as usual, so
    # non-Codex providers still work and the user can retry the login
    # manually.
    local seed_and_exec='
set -e
if [ ! -x /opt/polytoken-bin/polytoken ]; then
    if [ -x /opt/polytoken-seed/polytoken ]; then
        cp /opt/polytoken-seed/polytoken /opt/polytoken-bin/polytoken
        chmod +x /opt/polytoken-bin/polytoken
    else
        echo "pts: /opt/polytoken-bin/polytoken not found in the sandbox volume, and no host binary at ~/.local/bin/polytoken to seed it from." >&2
        exit 1
    fi
fi
case "$1" in
    auth|update) ;;
    *)
        codex_status="$(/opt/polytoken-bin/polytoken auth provider status --provider codex 2>&1)" || true
        if echo "$codex_status" | grep -qi "not logged in"; then
            echo "pts: Codex is not authenticated yet — starting device-code login..." >&2
            /opt/polytoken-bin/polytoken auth provider login --provider codex || \
                echo "pts: Codex login failed or was skipped; continuing anyway." >&2
        fi
        ;;
esac
exec /opt/polytoken-bin/polytoken "$@"
'

    podman run --rm -it \
        --privileged \
        --userns=keep-id:size=65536 \
        --security-opt label=disable \
        --network=host \
        --device /dev/fuse \
        --device /dev/net/tun \
        "${volumes[@]}" \
        -w "$workdir" \
        -e HOME="$state_dir" \
        -e TERM \
        -e OPENAI_API_KEY \
        -e ANTHROPIC_API_KEY \
        -e ZAI_API_KEY \
        -e NEURALWATT_API_KEY \
        -e OPENCODE_API_KEY \
        -e BRAVE_API_KEY \
        -e TAVILY_API_KEY \
        -e EXA_API_KEY \
        -e KAGI_API_KEY \
        -e PONYTAIL_DEFAULT_MODE \
        "${git_env[@]}" \
        --entrypoint /bin/sh \
        "$image" \
        -c "$seed_and_exec" sh "$@"
}
