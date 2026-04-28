#!/usr/bin/env bash
# process-collector.sh – Captures process tree with resource usage

set -euo pipefail
DB="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
LOG_DIR="${LOG_DIR:-/var/log/sys-inspector}"
LOG_FILE="$LOG_DIR/process.log"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "=== PROCESS COLLECTOR START ==="

sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS processes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    pid INTEGER,
    ppid INTEGER,
    name TEXT,
    cpu_percent REAL,
    mem_percent REAL,
    rss_kb INTEGER,
    state TEXT,
    cmdline TEXT
);
SQL

# Clear old records (keep last 10 samples per process)
sqlite3 "$DB" "DELETE FROM processes WHERE sampled_at < datetime('now', '-1 hour');"

# Collect current processes
ps -eo pid,ppid,pcpu,pmem,rss,stat,comm --no-headers | while read -r pid ppid pcpu pmem rss stat comm; do
    cmdline=$(ps -p "$pid" -o args --no-headers 2>/dev/null | head -c 500)
    sqlite3 "$DB" "INSERT INTO processes (pid, ppid, name, cpu_percent, mem_percent, rss_kb, state, cmdline) VALUES ($pid, $ppid, '$comm', $pcpu, $pmem, $rss, '$stat', '$cmdline');"
done

log "Process tree captured"
log "=== PROCESS COLLECTOR COMPLETE ==="