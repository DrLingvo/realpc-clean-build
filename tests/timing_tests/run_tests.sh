#!/usr/bin/env bash
# Build + run the detectability tests inside a guest and analyze the results.
#
# Transport is pluggable so this is not tied to Proxmox:
#   TRANSPORT=qm   ./run_tests.sh <vmid>        # Proxmox qemu-guest-agent (default)
#   TRANSPORT=ssh  ./run_tests.sh user@host     # any VM reachable by ssh
#   TRANSPORT=local ./run_tests.sh              # run on THIS machine (e.g. inside the guest)
# Results + analysis go to results/<timestamp>/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TRANSPORT="${TRANSPORT:-qm}"
TARGET="${1:-}"
RES="$HERE/results/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RES"
log(){ echo "[*] $*"; }

build_and_run_remote_cmds='
  set -e; cd /root && rm -rf timing_tests && tar xzf timing-tests.tar.gz
  cd timing_tests
  command -v gcc >/dev/null || { apt-get update -qq && apt-get install -y -qq build-essential >/dev/null; }
  make -s clean && make -s run >/dev/null
  tar -czf /tmp/results.tar.gz -C build . '

case "$TRANSPORT" in
  local)
    log "running locally"
    cd "$HERE"; command -v gcc >/dev/null || { echo "install build-essential first" >&2; exit 1; }
    make -s clean && make -s run >/dev/null
    cp build/*.json "$RES/"
    ;;
  qm)
    [ -n "$TARGET" ] || { echo "usage: TRANSPORT=qm $0 <vmid>" >&2; exit 1; }
    qm status "$TARGET" | grep -q "status: running" || { echo "VM $TARGET not running" >&2; exit 1; }
    tar -czf /tmp/timing-tests.tar.gz -C "$HERE" .
    log "pushing to VM $TARGET (needs qemu-guest-agent in the guest)"
    qm guest exec-status "$TARGET" >/dev/null 2>&1 || echo "  (if this hangs, the guest agent is not running)"
    qm push "$TARGET" /tmp/timing-tests.tar.gz /root/timing-tests.tar.gz
    rm -f /tmp/timing-tests.tar.gz
    log "building + running inside guest"
    qm guest exec "$TARGET" --timeout 600 -- bash -c "$build_and_run_remote_cmds"
    qm pull "$TARGET" /tmp/results.tar.gz "$RES/results.tar.gz"
    tar -xzf "$RES/results.tar.gz" -C "$RES"; rm -f "$RES/results.tar.gz"
    ;;
  ssh)
    [ -n "$TARGET" ] || { echo "usage: TRANSPORT=ssh $0 user@host" >&2; exit 1; }
    tar -czf /tmp/timing-tests.tar.gz -C "$HERE" .
    log "copying to $TARGET"
    scp -q /tmp/timing-tests.tar.gz "$TARGET:/root/timing-tests.tar.gz"
    rm -f /tmp/timing-tests.tar.gz
    ssh "$TARGET" "bash -c '$build_and_run_remote_cmds'"
    scp -q "$TARGET:/tmp/results.tar.gz" "$RES/results.tar.gz"
    tar -xzf "$RES/results.tar.gz" -C "$RES"; rm -f "$RES/results.tar.gz"
    ;;
  *) echo "unknown TRANSPORT=$TRANSPORT (use qm|ssh|local)" >&2; exit 1 ;;
esac

log "results in $RES"
python3 "$HERE/analyze.py" "$RES" "$HERE/reference/thresholds.json"
