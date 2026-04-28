#!/usr/bin/env bash
# network-collector.sh – Captures listening ports and active connections

set -euo pipefail
DB="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
LOG_DIR="${LOG_DIR:-/var/log/sys-inspector}"
LOG_FILE="$LOG_DIR/network.log"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "=== NETWORK COLLECTOR START ==="

sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS network_connections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    protocol TEXT,
    local_addr TEXT,
    remote_addr TEXT,
    state TEXT,
    pid INTEGER,
    process TEXT
);
CREATE TABLE IF NOT EXISTS listening_ports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    protocol TEXT,
    port INTEGER,
    pid INTEGER,
    process TEXT
);
SQL

# Active connections (using ss)
ss -tunap --no-header 2>/dev/null | while read -r net state recv send local remote proc; do
    proto=$(echo "$net" | tr -d ':')
    # extract pid/process
    pid_proc=$(echo "$proc" | grep -oP 'pid=\K[0-9]+' || echo "0")
    process=$(echo "$proc" | grep -oP 'name=\K[^,]+' || echo "unknown")
    sqlite3 "$DB" "INSERT INTO network_connections (protocol, local_addr, remote_addr, state, pid, process) VALUES ('$proto', '$local', '$remote', '$state', ${pid_proc:-0}, '$process');"
done

# Listening ports
ss -tuln --no-header 2>/dev/null | while read -r net state recv send local; do
    proto=$(echo "$net" | tr -d ':')
    port=$(echo "$local" | rev | cut -d: -f1 | rev)
    sqlite3 "$DB" "INSERT INTO listening_ports (protocol, port) VALUES ('$proto', $port);"
done

log "Network connections captured"
log "=== NETWORK COLLECTOR COMPLETE ==="