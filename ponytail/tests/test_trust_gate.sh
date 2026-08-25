#!/usr/bin/env bash
# Regression test for _pts_confirm_trust() in polytoken-sandbox.sh — the
# confirmation gate on project-local `.polytoken/Containerfile` and
# `.polytoken/volumes` files (a cloned repo could otherwise silently escalate
# to arbitrary host access via `.polytoken/volumes` the moment `pts` runs).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"

# shellcheck source=/dev/null
source "$repo_dir/polytoken-sandbox.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

target="$scratch/volumes"
printf '/some/media:/media\n' >"$target"

# 1. Closed/empty stdin (EOF) must refuse immediately, not hang or auto-approve.
if _pts_confirm_trust "$target" "test reason" </dev/null; then
    echo "FAIL: EOF on stdin should have refused" >&2
    exit 1
fi
[[ ! -f "$target.trusted-sha256" ]] || { echo "FAIL: refusal should not write a trust marker" >&2; exit 1; }

# 2. Declining interactively (answers "n") must also refuse.
if echo "n" | _pts_confirm_trust "$target" "test reason"; then
    echo "FAIL: declining should have refused" >&2
    exit 1
fi

# 3. Approving interactively (answers "y") must succeed and pin a hash.
if ! echo "y" | _pts_confirm_trust "$target" "test reason"; then
    echo "FAIL: approving should have succeeded" >&2
    exit 1
fi
[[ -f "$target.trusted-sha256" ]] || { echo "FAIL: approval should write a trust marker" >&2; exit 1; }

# 4. Re-running with the SAME content must succeed without prompting again
#    (no stdin provided at all — if this reads from stdin it hangs/fails).
if ! _pts_confirm_trust "$target" "test reason" </dev/null; then
    echo "FAIL: unchanged, already-trusted content should not re-prompt" >&2
    exit 1
fi

# 5. Changing the file's content must invalidate the pinned trust — this is
#    the supply-chain-swap case (approve a benign version once, then swap in
#    something malicious) that a plain boolean "trusted this project" flag
#    would silently miss.
printf '/:/hostroot\n' >"$target"
if _pts_confirm_trust "$target" "test reason" </dev/null; then
    echo "FAIL: changed content should require re-approval, not inherit old trust" >&2
    exit 1
fi

printf 'Trust gate checks passed\n'
