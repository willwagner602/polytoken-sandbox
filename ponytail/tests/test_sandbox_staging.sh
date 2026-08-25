#!/usr/bin/env bash
# Regression test for _pts_stage_ponytail() in polytoken-sandbox.sh — the
# function that copies the ponytail hook script, hook wiring, default-mode
# config, and this repo's AGENTS.md into a project's polytoken config dir.
# This staging silently regressed to a no-op once before (deleted during an
# unrelated refactor, never restored) with no test to catch it; this test
# exercises the copy logic directly against a scratch dir, no podman needed.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"

# shellcheck source=/dev/null
source "$repo_dir/polytoken-sandbox.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# _pts_stage_ponytail reads from "$HOME/.bashrc.d/polytoken-sandbox" — point
# HOME two levels above this checkout (repo_dir is .../.bashrc.d/polytoken-sandbox)
# so the function resolves back to these exact files, regardless of where the
# real $HOME is installed.
fake_home="$(dirname "$(dirname "$repo_dir")")"
HOME="$fake_home" _pts_stage_ponytail "$scratch/config"

fail=0
check() {
    if [[ ! -e "$1" ]]; then
        echo "FAIL: missing $1" >&2
        fail=1
    fi
}

check "$scratch/config/AGENTS.md"
check "$scratch/config/hooks/ponytail-hook.sh"
check "$scratch/config/hooks.json"
check "$scratch/config/ponytail-config.json"

if [[ -e "$scratch/config/hooks/ponytail-hook.sh" ]]; then
    perms="$(stat -c '%a' "$scratch/config/hooks/ponytail-hook.sh")"
    if [[ "$perms" != "755" ]]; then
        echo "FAIL: hooks/ponytail-hook.sh perms are $perms, expected 755" >&2
        fail=1
    fi
fi

if [[ -e "$scratch/config/AGENTS.md" ]] && ! diff -q "$repo_dir/AGENTS.md" "$scratch/config/AGENTS.md" >/dev/null; then
    echo "FAIL: staged AGENTS.md doesn't match repo root AGENTS.md" >&2
    fail=1
fi

if ((fail == 0)); then
    echo "Ponytail sandbox staging checks passed"
else
    exit 1
fi

# The shared image must provide the Codex CLI, and pts must expose the host
# Codex state separately from Polytoken's provider auth store.
grep -Fq -- '@openai/codex' "$repo_dir/Containerfile"
grep -Fq -- 'local codex_cli_host_dir="$HOME/.codex"' "$repo_dir/polytoken-sandbox.sh"
grep -Fq -- '-v "$codex_cli_host_dir:$codex_cli_dir"' "$repo_dir/polytoken-sandbox.sh"
printf 'Codex container contract checks passed\n'
