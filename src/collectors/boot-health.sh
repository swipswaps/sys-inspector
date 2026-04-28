#!/usr/bin/env bash
# boot-health.sh — RLM-hardened boot time collector
# Correctly parses systemd-analyze output on Fedora/RHEL

set -euo pipefail

DB_PATH="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
LOG_DIR="${LOG_DIR:-/var/log/sys-inspector}"
LOG_FILE="$LOG_DIR/boot-health.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== BOOT HEALTH CAPTURE START ==="

# Get raw systemd-analyze output
RAW=$(systemd-analyze time 2>&1)
log "Raw systemd-analyze output:"
log "$RAW"

# Parse using robust grep for Fedora format:
# "Startup finished in 853ms (kernel) + 6.431s (initrd) + 26.993s (userspace) = 34.278s"
KERNEL_MS=$(echo "$RAW" | grep -oP 'kernel\) \+\s*\K[0-9.]+(?=s?)' | head -1 | awk '{print $1*1000}')
INITRD_MS=$(echo "$RAW" | grep -oP 'initrd\) \+\s*\K[0-9.]+(?=s?)' | head -1 | awk '{print $1*1000}')
USERSPACE_MS=$(echo "$RAW" | grep -oP 'userspace\)\s*=\s*\K[0-9.]+' | head -1 | awk '{print $1*1000}')
TOTAL_MS=$(echo "$RAW" | grep -oP '=\s*\K[0-9.]+(?=s)' | head -1 | awk '{print $1*1000}')

# Fallbacks if parsing fails
KERNEL_MS=${KERNEL_MS:-0}
INITRD_MS=${INITRD_MS:-0}
USERSPACE_MS=${USERSPACE_MS:-0}
TOTAL_MS=${TOTAL_MS:-0}

log "Parsed metrics: kernel=${KERNEL_MS}ms initrd=${INITRD_MS}ms userspace=${USERSPACE_MS}ms total=${TOTAL_MS}ms"

if [[ "$TOTAL_MS" -eq 0 ]]; then
    log "WARNING: total boot time parsed as 0ms. Will still record entry."
fi

# Get slowest unit from systemd-analyze blame
SLOWEST_UNIT=$(systemd-analyze blame 2>/dev/null | head -1 | awk '{print $2}' | tr -d '\n')
SLOWEST_UNIT=${SLOWEST_UNIT:-"unknown"}

# Insert into database (using collected_at column)
sqlite3 "$DB_PATH" << EOF
INSERT INTO boot_health (boot_ts, total_ms, kernel_ms, initrd_ms, userspace_ms, slowest_unit, baseline_dev)
VALUES (datetime('now'), $TOTAL_MS, $KERNEL_MS, $INITRD_MS, $USERSPACE_MS, '$SLOWEST_UNIT', 0);
EOF

log "Boot health record inserted into database"
log "=== BOOT HEALTH CAPTURE COMPLETE ==="