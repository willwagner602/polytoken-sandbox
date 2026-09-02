#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/polytoken-sandbox.sh"

# PTS_STRICT_LIFECYCLE=1 turns any skip into a failure, so CI can never
# report green without having exercised this suite's real paths.
lifecycle_skip() {
  printf 'SKIP: %s\n' "$1"
  if [[ -n "${PTS_STRICT_LIFECYCLE:-}" ]]; then
    printf 'FAIL: PTS_STRICT_LIFECYCLE=1 — lifecycle skip not allowed: %s\n' "$1" >&2
    exit 1
  fi
  exit 0
}

if ! command -v podman >/dev/null 2>&1; then
  lifecycle_skip 'Podman unavailable; real lifecycle not exercised'
fi
if ! podman info >/dev/null 2>&1; then
  lifecycle_skip 'Podman unavailable or unsupported; real lifecycle not exercised'
fi
image="debian:12-slim"
if ! podman image exists "$image"; then
  lifecycle_skip "local disposable image $image is unavailable; generic lifecycle not exercised"
fi
id="$(podman create --name "pts-test-$RANDOM" --label 'pts.owner=polytoken.pts' --label 'pts.schema=1' --memory 12g --memory-swap 16g --pids-limit 2048 --init "$image" sh -c 'sleep 300')"
cleanup() { podman rm -f "$id" >/dev/null 2>&1 || true; }
trap cleanup EXIT
podman start "$id" >/dev/null
inspect="$(podman inspect --format '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.PidsLimit}} {{.HostConfig.Init}} {{index .Config.Labels "pts.owner"}}' "$id")"
[[ "$inspect" == "12884901888 17179869184 2048 true polytoken.pts" ]] || { echo "FAIL: effective limits/init/label: $inspect" >&2; exit 1; }
podman stop --time 1 "$id" >/dev/null
[[ "$(podman inspect --format '{{.State.Status}}' "$id")" == exited ]]
printf 'Generic Podman lifecycle checks passed\n'
if command -v python3 >/dev/null 2>&1; then
  if python3 "$root/tests/pts_pty_harness.py"; then
    printf 'Provider-free PTS end-to-end lifecycle checks passed\n'
  else
    pty_status=$?
    if [[ "$pty_status" -eq 2 ]]; then
      lifecycle_skip 'PTY harness prerequisites unavailable; PTY lifecycle not exercised'
    fi
    exit "$pty_status"
  fi
else
  lifecycle_skip 'python3 unavailable; PTY lifecycle not exercised'
fi
