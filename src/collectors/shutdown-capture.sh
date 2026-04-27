#!/usr/bin/env bash
# shutdown-capture.sh — Snapshot system state before shutdown
# Trigger: systemd service with Conflicts=shutdown.target
# Self-healing: if DB missing, log to journal as fallback
# Citation: kill(1) man page — 'SIGTERM is the default signal sent to processes
#   by shutdown' [Tier 2: man7.org]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -f "$REPO_ROOT/config/sys-inspector.conf" ]]; then
    source "$REPO_ROOT/config/sys-inspector.conf"
else
    SYSTEM_INSPECTOR_DB="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
fi

main() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    # Capture top 20 processes by memory as JSON array
    local procs
    procs="$(ps aux --sort=-%mem | head -21 | tail -20 | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')"

    # Capture mount states excluding pseudo-filesystems
    local mounts
    mounts="$(mount | grep -v 'proc\|sysfs\|devpts\|tmpfs\|cgroup' | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')"

    # Count open files
    local open_ct
    open_ct="$(lsof 2>/dev/null | wc -l || echo "0")"

    # Detect unclean shutdown (any failed units?)
    local unclean=0
    systemctl list-units --state=failed --no-legend 2>/dev/null | grep -q . && unclean=1

    # Persist to DB if available; otherwise log to journal
    if [[ -f "$SYSTEM_INSPECTOR_DB" ]]; then
        sqlite3 "$SYSTEM_INSPECTOR_DB" <<SQL
INSERT INTO shutdown_capture (shutdown_ts, running_procs, mount_states, open_files_ct, unclean)
VALUES ('$ts', '${procs//\'/\'\'}', '${mounts//\'/\'\'}', $open_ct, $unclean);
SQL
    else
        echo "[shutdown-capture] DB unavailable; logging to journal." | systemd-cat -t sys-inspector
        echo "[shutdown-capture] Top procs: $(ps aux --sort=-%mem | head -5 | tail +2 | awk '{print $11}')" | systemd-cat -t sys-inspector
    fi

    echo "[shutdown-capture] Shutdown snapshot stored at $ts"
}

main "$@"
