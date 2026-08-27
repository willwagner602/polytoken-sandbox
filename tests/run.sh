#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$root/polytoken-sandbox.sh"
bash "$root/tests/test_pts_helpers.sh"
bash "$root/tests/test_pts_lifecycle.sh"
bash "$root/tests/test_pts_signal_cleanup.sh"
bash "$root/ponytail/tests/test_hook.sh"
bash "$root/ponytail/tests/test_sandbox_staging.sh"
bash "$root/ponytail/tests/test_trust_gate.sh"
printf 'All available PTS/Ponytail checks completed\n'
