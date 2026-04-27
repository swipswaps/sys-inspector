#!/usr/bin/env bash
# boot-health.sh — Capture boot metrics and compare against baseline
# Trigger: systemd service at multi-user.target
# Self-healing: if DB missing, init it; if baseline missing, create seed entry
# Citation: systemd-analyze(1) — 'systemd-analyze blame prints a list of all
#   running units, ordered by the time they took to initialize' [Tier 2: man7.org]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source configuration; skip gracefully if missing
if [[ -f "$REPO_ROOT/config/sys-inspector.conf" ]]; then
    source "$REPO_ROOT/config/sys-inspector.conf"
else
    SYSTEM_INSPECTOR_DB="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
    RETENTION_DAYS="${RETENTION_DAYS:-90}"
    BASELINE_MIN_SAMPLES="${BASELINE_MIN_SAMPLES:-5}"
    ANOMALY_SIGMA="${ANOMALY_SIGMA:-2.0}"
fi

LOG_FILE="${LOG_DIR:-/var/log/sys-inspector}/boot-health.log"
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$SYSTEM_INSPECTOR_DB")"

# --- Helper: log with timestamp to both file and stdout ---
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# --- Main collection ---
main() {
    log_msg "=== BOOT HEALTH CAPTURE START ==="

    # Ensure database exists (self-healing: init if missing)
    if [[ ! -f "$SYSTEM_INSPECTOR_DB" ]]; then
        log_msg "DB not found; running db-init.sh"
        bash "$REPO_ROOT/src/db/db-init.sh"
    fi

    # Collect boot metrics via systemd-analyze
    local kernel_ver analyze_output kernel_ms initrd_ms userspace_ms total_ms
    kernel_ver="$(uname -r)"
    analyze_output="$(systemd-analyze 2>/dev/null || echo '0 0 0')"

    # Parse: "Startup finished in 875ms (kernel) + 6.5s (initrd) + 28.3s (userspace) = 35.7s"
    kernel_ms=$(echo "$analyze_output" | grep -oE '[0-9]+ms.*kernel' | grep -oE '[0-9]+' | head -1 || echo "0")
    initrd_ms=$(echo "$analyze_output" | grep -oE '[0-9.]+s.*initrd' | sed 's/s.*//' | awk '{printf "%d", $1*1000}' 2>/dev/null || echo "0")
    userspace_ms=$(echo "$analyze_output" | grep -oE '[0-9.]+s.*userspace' | sed 's/s.*//' | awk '{printf "%d", $1*1000}' 2>/dev/null || echo "0")
    total_ms=$(echo "$analyze_output" | grep -oE '[0-9.]+s$' | sed 's/s//' | awk '{printf "%d", $1*1000}' 2>/dev/null || echo "0")

    # Get slowest unit from blame output
    local blame_line slowest_unit slowest_ms
    blame_line="$(systemd-analyze blame 2>/dev/null | head -1 || echo 'unknown 0ms')"
    slowest_unit="$(echo "$blame_line" | awk '{print $NF}')"
    slowest_ms="$(echo "$blame_line" | grep -oE '[0-9.]+s' | sed 's/s//' | awk '{printf "%d", $1*1000}' || echo "0")"

    # Capture critical chain as JSON; fall back to empty array if jq missing
    local critical_chain
    if command -v jq &>/dev/null; then
        critical_chain="$(systemd-analyze critical-chain 2>/dev/null | head -10 | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')"
    else
        critical_chain="[]"
    fi

    # Collect journal warnings from this boot
    local warnings
    if command -v jq &>/dev/null; then
        warnings="$(journalctl -b -p warning --no-pager -o json 2>/dev/null | jq -s -c '[.[] | {msg: .MESSAGE, src: (._SYSTEMD_UNIT // "kernel")}]' 2>/dev/null || echo '[]')"
    else
        warnings="[]"
    fi

    # --- Anomaly detection via Welford's online algorithm ---
    local baseline_data n mean m2 deviation
    baseline_data="$(sqlite3 "$SYSTEM_INSPECTOR_DB" \
        "SELECT n, mean, m2 FROM baseline WHERE metric_key='boot_total_ms'" 2>/dev/null || echo "")"
    n=0; mean=0; m2=0; deviation=0

    if [[ -n "$baseline_data" ]]; then
        IFS='|' read -r n mean m2 <<< "$baseline_data"
        local new_n=$((n + 1))
        local delta new_mean delta2 new_m2
        delta=$(awk "BEGIN {print $total_ms - $mean}")
        new_mean=$(awk "BEGIN {print $mean + ($delta / $new_n)}")
        delta2=$(awk "BEGIN {print $total_ms - $new_mean}")
        new_m2=$(awk "BEGIN {print $m2 + ($delta * $delta2)}")
        if (( new_n >= BASELINE_MIN_SAMPLES )); then
            local variance stddev
            variance=$(awk "BEGIN {print $new_m2 / ($new_n - 1)}")
            stddev=$(awk "BEGIN {print sqrt($variance)}")
            if (( $(awk "BEGIN {print ($stddev > 0)}") )); then
                deviation=$(awk "BEGIN {printf \"%.2f\", ($total_ms - $new_mean) / $stddev}")
            fi
        fi
        sqlite3 "$SYSTEM_INSPECTOR_DB" \
            "UPDATE baseline SET n=$new_n, mean=$new_mean, m2=$new_m2, updated_ts=datetime('now') WHERE metric_key='boot_total_ms'"
    else
        sqlite3 "$SYSTEM_INSPECTOR_DB" \
            "INSERT INTO baseline (metric_key, n, mean, m2) VALUES ('boot_total_ms', 1, $total_ms, 0.0)"
    fi

    # --- Persist to database ---
    sqlite3 "$SYSTEM_INSPECTOR_DB" <<SQL
INSERT INTO boot_health (kernel_ver, kernel_ms, initrd_ms, userspace_ms, total_ms,
    slowest_unit, slowest_ms, critical_chain, warnings, baseline_dev)
VALUES ('$kernel_ver', $kernel_ms, $initrd_ms, $userspace_ms, $total_ms,
    '${slowest_unit//\'/\'\'}', $slowest_ms, '${critical_chain//\'/\'\'}', '${warnings//\'/\'\'}', $deviation);
SQL

    # --- Retention: delete records older than RETENTION_DAYS ---
    sqlite3 "$SYSTEM_INSPECTOR_DB" \
        "DELETE FROM boot_health WHERE boot_ts < datetime('now', '-${RETENTION_DAYS} days');
         DELETE FROM resource_samples WHERE sample_ts < datetime('now', '-${RETENTION_DAYS} days');
         DELETE FROM shutdown_capture WHERE shutdown_ts < datetime('now', '-${RETENTION_DAYS} days');
         VACUUM;"

    # --- Flag anomaly if significant deviation ---
    if (( $(awk "BEGIN {print (${deviation#-} > $ANOMALY_SIGMA)}") )); then
        log_msg "WARNING ANOMALY: Boot time $total_ms ms deviates ${deviation}σ from baseline"
    fi

    log_msg "=== BOOT HEALTH CAPTURE COMPLETE ==="
}

main "$@"
