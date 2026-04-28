#!/bin/bash
set -euo pipefail

echo "═══════════════════════════════════════════════════════════════"
echo "  SYS-INSPECTOR FORCE FIX – BOOT RECORDS & PERMISSIONS"
echo "═══════════════════════════════════════════════════════════════"

# 1. Fix log directory permissions (for contention‑alert.sh)
echo ""
echo "[1/4] Fixing log directory permissions..."
sudo chown -R root:root /var/log/sys-inspector
sudo chmod 755 /var/log/sys-inspector
echo "  ✓ Permissions fixed"

# 2. Check database schema and manually insert a correct boot record
echo ""
echo "[2/4] Manually inserting a boot record with correct time..."
DB="/var/lib/sys-inspector/sys-inspector.db"

# Show current state
echo "  Current boot records (total_ms > 0): $(sqlite3 "$DB" "SELECT COUNT(*) FROM boot_health WHERE total_ms > 0;")"

# Parse current boot time from systemd-analyze
RAW=$(systemd-analyze time 2>&1)
TOTAL_MS=$(echo "$RAW" | grep -oP '=\s*\K[0-9.]+(?=s)' | head -1 | awk '{print $1*1000}')
KERNEL_MS=$(echo "$RAW" | grep -oP 'kernel\) \+\s*\K[0-9.]+(?=s?)' | head -1 | awk '{print $1*1000}')
INITRD_MS=$(echo "$RAW" | grep -oP 'initrd\) \+\s*\K[0-9.]+(?=s?)' | head -1 | awk '{print $1*1000}')
USERSPACE_MS=$(echo "$RAW" | grep -oP 'userspace\)\s*=\s*\K[0-9.]+' | head -1 | awk '{print $1*1000}')
SLOWEST_UNIT=$(systemd-analyze blame 2>/dev/null | head -1 | awk '{print $2}' | tr -d '\n')

# Use defaults if parsing failed
TOTAL_MS=${TOTAL_MS:-0}
KERNEL_MS=${KERNEL_MS:-0}
INITRD_MS=${INITRD_MS:-0}
USERSPACE_MS=${USERSPACE_MS:-0}
SLOWEST_UNIT=${SLOWEST_UNIT:-"unknown"}

echo "  Parsed boot time: ${TOTAL_MS}ms (${KERNEL_MS} / ${INITRD_MS} / ${USERSPACE_MS})"

# Insert directly (use current timestamp)
sqlite3 "$DB" << EOF
INSERT INTO boot_health (boot_ts, total_ms, kernel_ms, initrd_ms, userspace_ms, slowest_unit, baseline_dev)
VALUES (datetime('now'), $TOTAL_MS, $KERNEL_MS, $INITRD_MS, $USERSPACE_MS, '$SLOWEST_UNIT', 0);
EOF

# Verify
NEW_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM boot_health WHERE total_ms > 0;")
echo "  Boot records after insert: $NEW_COUNT"

# 3. Fix the boot‑health collector script – ensure it uses the same working INSERT
echo ""
echo "[3/4] Updating boot‑health collector script..."
sudo tee /usr/local/share/sys-inspector/src/collectors/boot-health.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
# boot-health.sh – Reliable insert with correct column mapping
set -euo pipefail

DB_PATH="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
LOG_DIR="${LOG_DIR:-/var/log/sys-inspector}"
LOG_FILE="$LOG_DIR/boot-health.log"

mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "=== BOOT HEALTH CAPTURE START ==="

RAW=$(systemd-analyze time 2>&1)
log "Raw output: $RAW"

TOTAL_MS=$(echo "$RAW" | grep -oP '=\s*\K[0-9.]+(?=s)' | head -1 | awk '{print $1*1000}')
KERNEL_MS=$(echo "$RAW" | grep -oP 'kernel\) \+\s*\K[0-9.]+(?=s?)' | head -1 | awk '{print $1*1000}')
INITRD_MS=$(echo "$RAW" | grep -oP 'initrd\) \+\s*\K[0-9.]+(?=s?)' | head -1 | awk '{print $1*1000}')
USERSPACE_MS=$(echo "$RAW" | grep -oP 'userspace\)\s*=\s*\K[0-9.]+' | head -1 | awk '{print $1*1000}')
SLOWEST_UNIT=$(systemd-analyze blame 2>/dev/null | head -1 | awk '{print $2}' | tr -d '\n')

TOTAL_MS=${TOTAL_MS:-0}
KERNEL_MS=${KERNEL_MS:-0}
INITRD_MS=${INITRD_MS:-0}
USERSPACE_MS=${USERSPACE_MS:-0}
SLOWEST_UNIT=${SLOWEST_UNIT:-"unknown"}

log "Parsed: total=${TOTAL_MS}ms kernel=${KERNEL_MS}ms initrd=${INITRD_MS}ms userspace=${USERSPACE_MS}ms slowest=$SLOWEST_UNIT"

sqlite3 "$DB_PATH" << SQL_EOF
INSERT INTO boot_health (boot_ts, total_ms, kernel_ms, initrd_ms, userspace_ms, slowest_unit, baseline_dev)
VALUES (datetime('now'), $TOTAL_MS, $KERNEL_MS, $INITRD_MS, $USERSPACE_MS, '$SLOWEST_UNIT', 0);
SQL_EOF

log "Boot record inserted (total=${TOTAL_MS}ms)"
log "=== BOOT HEALTH CAPTURE COMPLETE ==="
EOF

sudo chmod +x /usr/local/share/sys-inspector/src/collectors/boot-health.sh
echo "  ✓ Collector updated"

# 4. Restart API service and verify
echo ""
echo "[4/4] Restarting API service and verifying..."
sudo systemctl restart sys-inspector-api.service
sleep 2

echo ""
echo "=== FINAL VERIFICATION ==="
curl -s http://127.0.0.1:8765/api/stats | python3 -m json.tool
echo ""
echo "Boot records in database (positive time): $(sqlite3 "$DB" "SELECT COUNT(*) FROM boot_health WHERE total_ms > 0;")"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FIX COMPLETE – REFRESH DASHBOARD AND RUN TUI"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Dashboard: http://127.0.0.1:8765/ (reload with Ctrl+Shift+R)"
echo "  TUI:       sys-inspector-tui"
echo ""