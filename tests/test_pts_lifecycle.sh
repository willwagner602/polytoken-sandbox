#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/polytoken-sandbox.sh"

if ! command -v podman >/dev/null 2>&1; then
  printf 'SKIP: Podman unavailable; real lifecycle not exercised\n'
  exit 0
fi
if ! podman info >/dev/null 2>&1; then
  printf 'SKIP: Podman unavailable or unsupported; real lifecycle not exercised\n'
  exit 0
fi
image="debian:12-slim"
if ! podman image exists "$image"; then
  printf 'SKIP: local disposable image %s is unavailable; generic lifecycle not exercised\n' "$image"
  exit 0
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
    [[ "$pty_status" -eq 2 ]] || exit "$pty_status"
  fi
else
  printf 'BLOCKED: python3 unavailable; PTY lifecycle not exercised\n'
fi
