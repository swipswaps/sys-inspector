#!/usr/bin/env bash
# contention-alert.sh — Sample system resources and alert on threshold breach
# Trigger: systemd timer every 5 minutes
# Self-healing: if DB missing, init it automatically
# Citation: Gregg 2021, 'Systems Performance', ch.6 'CPU' p.208 —
#   'CPU utilization should be measured as percent of one CPU and aggregated' [Tier 1]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source config with fallbacks for every variable
if [[ -f "$REPO_ROOT/config/sys-inspector.conf" ]]; then
    source "$REPO_ROOT/config/sys-inspector.conf"
else
    SYSTEM_INSPECTOR_DB="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
    CPU_THRESHOLD_PCT=90; MEM_THRESHOLD_PCT=80; IOWAIT_THRESHOLD_PCT=50; ZOMBIE_THRESHOLD=5
fi

main() {
    # Self-healing: ensure DB exists before writing
    if [[ ! -f "$SYSTEM_INSPECTOR_DB" ]]; then
        bash "$REPO_ROOT/src/db/db-init.sh" 2>/dev/null || true
    fi

    # --- Collect CPU metrics (mpstat preferred, /proc/loadavg fallback) ---
    local cpu_pct
    if command -v mpstat &>/dev/null; then
        cpu_pct=$(mpstat 1 1 2>/dev/null | awk 'END{print 100 - $NF}' || echo "0")
    else
        local ncpu load1
        ncpu=$(nproc)
        load1=$(awk '{print $1}' /proc/loadavg)
        cpu_pct=$(awk "BEGIN {printf \"%.1f\", ($load1 / $ncpu) * 100}")
    fi

    # --- Collect memory metrics ---
    local mem_used mem_total mem_pct
    mem_used=$(free -m | awk 'NR==2{print $3}')
    mem_total=$(free -m | awk 'NR==2{print $2}')
    mem_pct=$(awk "BEGIN {printf \"%.1f\", ($mem_used / $mem_total) * 100}")

    # --- Collect I/O wait (iostat preferred, zero fallback) ---
    local iowait_pct
    if command -v iostat &>/dev/null; then
        iowait_pct=$(iostat -c 1 2 2>/dev/null | awk 'END{print $4}' || echo "0")
    else
        iowait_pct="0.0"
    fi

    # --- Collect load averages and zombie count ---
    local load1 load5 load15 zombie_ct
    read -r load1 load5 load15 _ < /proc/loadavg
    zombie_ct=$(ps -eo stat | awk '$1 ~ /Z/' | wc -l)

    # --- Determine if any threshold is breached ---
    local alert=0
    (( $(awk "BEGIN {print ($cpu_pct > $CPU_THRESHOLD_PCT)}") )) && alert=1
    (( $(awk "BEGIN {print ($mem_pct > $MEM_THRESHOLD_PCT)}") )) && alert=1
    (( $(awk "BEGIN {print ($iowait_pct > $IOWAIT_THRESHOLD_PCT)}") )) && alert=1
    (( zombie_ct > ZOMBIE_THRESHOLD )) && alert=1

    # --- Persist sample to database ---
    if [[ -f "$SYSTEM_INSPECTOR_DB" ]]; then
        sqlite3 "$SYSTEM_INSPECTOR_DB" <<SQL
INSERT INTO resource_samples
    (cpu_pct, mem_used_mb, mem_total_mb, iowait_pct, load_1m, load_5m, load_15m, zombie_ct, alert_triggered)
VALUES ($cpu_pct, $mem_used, $mem_total, $iowait_pct, $load1, $load5, $load15, $zombie_ct, $alert);
SQL
    fi

    # --- Alert if threshold breached ---
    if (( alert )); then
        local msg="ALERT: CPU=${cpu_pct}% RAM=${mem_pct}% IOWait=${iowait_pct}% Zombies=${zombie_ct}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" | systemd-cat -t sys-inspector -p warning
        logger -t sys-inspector "$msg"
        command -v notify-send &>/dev/null && \
            DISPLAY=:0 notify-send "sys-inspector" "$msg" --icon=dialog-warning 2>/dev/null || true
    fi
}

main "$@"
