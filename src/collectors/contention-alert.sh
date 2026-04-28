#!/usr/bin/env bash
# contention-alert.sh — Resource sample collector (RLM fixed)

set -euo pipefail

DB_PATH="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
LOG_DIR="${LOG_DIR:-/var/log/sys-inspector}"
LOG_FILE="$LOG_DIR/contention.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== RESOURCE SAMPLE START ==="

# CPU stats from mpstat (if available)
if command -v mpstat &>/dev/null; then
    CPU_DATA=$(mpstat 1 1 | tail -1)
    CPU_USER=$(echo "$CPU_DATA" | awk '{print $4}')
    CPU_SYSTEM=$(echo "$CPU_DATA" | awk '{print $6}')
    CPU_IDLE=$(echo "$CPU_DATA" | awk '{print $12}')
    CPU_IOWAIT=$(echo "$CPU_DATA" | awk '{print $7}')
else
    # fallback using /proc/stat
    read -r cpu line < /proc/stat
    set -- $line
    USER=$2; NICE=$3; SYSTEM=$4; IDLE=$5; IOWAIT=$6; IRQ=$7; SOFTIRQ=$8; STEAL=$9; GUEST=$10
    TOTAL=$((USER+SYSTEM+IDLE+IOWAIT+IRQ+SOFTIRQ+STEAL))
    CPU_USER=$((100 * USER / TOTAL))
    CPU_SYSTEM=$((100 * SYSTEM / TOTAL))
    CPU_IDLE=$((100 * IDLE / TOTAL))
    CPU_IOWAIT=$((100 * IOWAIT / TOTAL))
fi

# Memory stats
MEM_TOTAL=$(free -b | awk 'NR==2{print $2}')
MEM_USED=$(free -b | awk 'NR==2{print $3}')
MEM_FREE=$(free -b | awk 'NR==2{print $4}')
MEM_CACHED=$(free -b | awk 'NR==2{print $7}')
SWAP_USED=$(free -b | awk 'NR==3{print $3}')

# Load averages
LOAD=$(uptime | awk -F 'load average:' '{print $2}')
LOAD_1MIN=$(echo "$LOAD" | awk -F',' '{print $1}')
LOAD_5MIN=$(echo "$LOAD" | awk -F',' '{print $2}')
LOAD_15MIN=$(echo "$LOAD" | awk -F',' '{print $3}')

# Disk I/O (from iostat if available)
if command -v iostat &>/dev/null; then
    IOSTAT_DATA=$(iostat -d 1 1 | tail -1)
    DISK_READ=$(echo "$IOSTAT_DATA" | awk '{print $3}')
    DISK_WRITE=$(echo "$IOSTAT_DATA" | awk '{print $4}')
else
    DISK_READ=0
    DISK_WRITE=0
fi

# Context switches & interrupts from /proc/stat
read -r ctx line < /proc/stat
CONTEXT_SWITCHES=$(grep ctxt /proc/stat | awk '{print $2}')
INTERRUPTS=$(grep intr /proc/stat | awk '{print $2}')

# Insert into database (fixed SQL – no trailing comma)
sqlite3 "$DB_PATH" << EOF
INSERT INTO resource_samples (
    sampled_at, cpu_user, cpu_system, cpu_idle, cpu_iowait,
    mem_total, mem_used, mem_free, mem_cached, swap_used,
    load_1min, load_5min, load_15min,
    disk_read_kb, disk_write_kb,
    context_switches, interrupts
) VALUES (
    datetime('now'),
    ${CPU_USER:-0}, ${CPU_SYSTEM:-0}, ${CPU_IDLE:-0}, ${CPU_IOWAIT:-0},
    ${MEM_TOTAL:-0}, ${MEM_USED:-0}, ${MEM_FREE:-0}, ${MEM_CACHED:-0}, ${SWAP_USED:-0},
    ${LOAD_1MIN:-0}, ${LOAD_5MIN:-0}, ${LOAD_15MIN:-0},
    ${DISK_READ:-0}, ${DISK_WRITE:-0},
    ${CONTEXT_SWITCHES:-0}, ${INTERRUPTS:-0}
);
EOF

log "Resource sample inserted"
log "=== RESOURCE SAMPLE COMPLETE ==="