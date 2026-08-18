#!/bin/bash
# polytoken-sandbox.sh
#
# Defines `pts` — runs polytoken inside a podman container.
#
# The container only mounts the invocation directory (read/write), the
# ~/.job_digest/secrets.json file (read-only), and the polytoken binary
# (read-only) — not the rest of $HOME. Polytoken's own config/cache/auth/
# session state lives in a `.polytoken/` dir under the invocation
# directory, so it persists per-project across runs. Shares the host
# network so LLM API calls work normally.
#
# The polytoken binary on the host is mounted read-only into the container,
# so it stays in sync — no image rebuild needed when polytoken updates.
#
# Usage:
#   pts                  # run polytoken (TUI) in the sandbox
#   pts --print-session  # pass arguments through to polytoken
#
# Requirements: podman installed and configured for rootless use.

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
    if [[ -f "$project_containerfile" ]]; then
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
    local project_config="$state_dir/.config/polytoken/config.yaml"
    local global_config_dir="$state_dir/.config/polytoken"
    mkdir -p "$global_config_dir"
    cp "$HOME/.bashrc.d/polytoken-sandbox/config-template.yaml" "$project_config"
    cp "$HOME/.bashrc.d/polytoken-sandbox/AGENTS.md" "$global_config_dir/AGENTS.md"
    mkdir -p "$global_config_dir/hooks"
    cp "$HOME/.bashrc.d/polytoken-sandbox/ponytail/hooks/ponytail-hook.sh" "$global_config_dir/hooks/ponytail-hook.sh"
    chmod 755 "$global_config_dir/hooks/ponytail-hook.sh"
    cp "$HOME/.bashrc.d/polytoken-sandbox/ponytail/hooks.json" "$global_config_dir/hooks.json"

    # Only the invocation directory (which contains the polytoken state
    # dir above), the read-only polytoken binary, and the job-digest
    # secrets file are exposed — not the rest of $HOME.
    local secrets_file="$HOME/.job_digest/secrets.json"
    local -a volumes=(
        -v "$workdir:$workdir"
        -v "$HOME/.local/bin/polytoken:/usr/local/bin/polytoken:ro"
    )
    if [[ -f "$secrets_file" ]]; then
        volumes+=(-v "$secrets_file:$secrets_file:ro")
    fi

    # A project can also mount extra host paths (e.g. external media) by
    # committing a `.polytoken/volumes` file: one `-v`-style mount spec per
    # line (HOST:CONTAINER[:OPTS]), passed straight through to `podman run
    # -v`. Only used when present, so this is opt-in per project.
    local project_volumes="$workdir/.polytoken/volumes"
    if [[ -f "$project_volumes" ]]; then
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
    local -a _key_names=(OPENAI_API_KEY ANTHROPIC_API_KEY ZAI_API_KEY NEURALWATT_API_KEY BRAVE_API_KEY TAVILY_API_KEY EXA_API_KEY KAGI_API_KEY)
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

    local -a git_env=()
    if [[ -n "$gh_token" ]]; then
        git_env=(
            -e GH_TOKEN="$gh_token"
            -e GIT_CONFIG_COUNT=2
            -e GIT_CONFIG_KEY_0="credential.https://github.com.helper"
            -e GIT_CONFIG_VALUE_0=""
            -e GIT_CONFIG_KEY_1="credential.https://github.com.helper"
            -e GIT_CONFIG_VALUE_1='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
        )
    fi

    podman run --rm -it \
        --userns=keep-id \
        --security-opt label=disable \
        --network=host \
        "${volumes[@]}" \
        -w "$workdir" \
        -e HOME="$state_dir" \
        -e TERM \
        -e OPENAI_API_KEY \
        -e ANTHROPIC_API_KEY \
        -e ZAI_API_KEY \
        -e NEURALWATT_API_KEY \
        -e BRAVE_API_KEY \
        -e TAVILY_API_KEY \
        -e EXA_API_KEY \
        -e KAGI_API_KEY \
        "${git_env[@]}" \
        --entrypoint /usr/local/bin/polytoken \
        "$image" \
        "$@"
}
