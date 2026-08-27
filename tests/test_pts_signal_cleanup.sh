#!/usr/bin/env bash
# Behavioral regression test for the pts() abnormal-termination path.
#
# Runs the real launcher in a child shell against a fake `podman` that
# hangs inside `podman start -ai`, then TERMs the child. The cleanup trap
# must fire *while the attach client is still alive*: diagnostics captured
# under the project, the container stopped/killed/removed by exact ID, the
# attach client killed, and the child exited 143 — all within seconds.
# If `podman start -ai` were a foreground call again, bash would defer the
# trapped signal until the 60s fake client exits on its own, and the
# elapsed-time assertion below fails.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$(mktemp -d)"
log="$(mktemp -u)"
ready="$(mktemp -u)"
child_err="$(mktemp -u)"
trap 'rm -rf "$project" "$log" "$ready" "$child_err"' EXIT
cid="fakeid0123456789abcdef"

child_payload='
cd "$PT_PROJECT"
podman() {
    printf "podman %s\n" "$*" >>"$PT_LOG"
    case "$1" in
        create) printf "%s\n" "$PT_CID"; : >"$PT_READY"; return 0 ;;
        start) sleep 60; return 0 ;;
        inspect)
            case "$*" in
                *".Id}}"*) printf "%s\t/pts-fake\trunning\t0\t0\t%s\t%s\t12g\t16g\t2048\ttrue\t1\n" "$PT_CID" "$PWD" "$PWD" ;;
                *".State.Status}}"*) printf "running\n" ;;
            esac
            return 0 ;;
    esac
    return 0
}
source "$PT_ROOT/polytoken-sandbox.sh"
pts
'

start=$(date +%s)
env PT_ROOT="$root" PT_PROJECT="$project" PT_LOG="$log" PT_READY="$ready" PT_CID="$cid" \
    bash -c "$child_payload" 2>"$child_err" &
child=$!

# Wait until the launcher has created its container before signalling.
for _ in $(seq 1 100); do
    [[ -f "$ready" ]] && break
    sleep 0.1
done
if [[ ! -f "$ready" ]]; then
    echo "FAIL: child never reached podman create" >&2
    cat "$child_err" >&2
    exit 1
fi

kill -TERM "$child"
wait "$child" || status=$?
elapsed=$(( $(date +%s) - start ))

if [[ "$status" -ne 143 ]]; then
    echo "FAIL: expected exit 143 after TERM, got $status" >&2
    cat "$child_err" >&2
    exit 1
fi
if [[ "$elapsed" -ge 30 ]]; then
    echo "FAIL: cleanup took ${elapsed}s — the trap only ran after the attach client exited (foreground podman start regression?)" >&2
    exit 1
fi
grep -Fq "stop --time 10 $cid" "$log" || { echo "FAIL: exact-ID graceful stop not issued" >&2; exit 1; }
grep -Fq "kill $cid" "$log" || { echo "FAIL: exact-ID kill escalation not issued" >&2; exit 1; }
grep -Fq "rm $cid" "$log" || { echo "FAIL: exact-ID removal not issued" >&2; exit 1; }
if [[ -z "$(find "$project/.polytoken/pts/diagnostics" -name metadata -print -quit 2>/dev/null)" ]]; then
    echo "FAIL: no diagnostics bundle captured before forced cleanup" >&2
    exit 1
fi

printf 'PTS signal-cleanup checks passed\n'
