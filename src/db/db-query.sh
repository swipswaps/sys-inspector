#!/usr/bin/env bash
# db-query.sh — Common queries against the sys-inspector database
# Usage: db-query.sh <query_name>
# Queries: boot-latest, resources-recent, errors-active, manifest-summary, baseline
set -euo pipefail

DB_PATH="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"

query_boot_latest() {
    sqlite3 -column -header "$DB_PATH" \
        "SELECT boot_ts, kernel_ver, printf('%.1fs', total_ms/1000.0) AS total_s,
                slowest_unit, printf('%dms', slowest_ms) AS slowest,
                printf('%.2fσ', baseline_dev) AS deviation
         FROM boot_health ORDER BY id DESC LIMIT 1;"
}

query_resources_recent() {
    sqlite3 -column -header "$DB_PATH" \
        "SELECT sample_ts, printf('%.1f%%', cpu_pct) AS cpu,
                printf('%d/%d MB', mem_used_mb, mem_total_mb) AS memory,
                printf('%.1f%%', iowait_pct) AS iowait,
                zombie_ct AS zombies
         FROM resource_samples
         WHERE sample_ts > datetime('now', '-1 hour')
         ORDER BY id DESC LIMIT 60;"
}

query_errors_active() {
    sqlite3 -column -header "$DB_PATH" \
        "SELECT source, message, count, first_seen, last_seen
         FROM error_log
         WHERE resolved = 0
         ORDER BY count DESC LIMIT 20;"
}

query_manifest_summary() {
    sqlite3 -column -header "$DB_PATH" \
        "SELECT state, COUNT(*) AS count
         FROM service_manifest
         GROUP BY state
         ORDER BY count DESC;"
}

query_baseline() {
    sqlite3 -column -header "$DB_PATH" \
        "SELECT metric_key, printf('n=%d', n) AS samples,
                printf('%.1f', mean) AS mean,
                printf('%.1f', sqrt(m2/n)) AS stddev
         FROM baseline
         WHERE n > 0
         ORDER BY metric_key;"
}

case "${1:-}" in
    boot-latest)       query_boot_latest ;;
    resources-recent)  query_resources_recent ;;
    errors-active)     query_errors_active ;;
    manifest-summary)  query_manifest_summary ;;
    baseline)          query_baseline ;;
    *)
        echo "Usage: db-query.sh {boot-latest|resources-recent|errors-active|manifest-summary|baseline}"
        exit 1
        ;;
esac
