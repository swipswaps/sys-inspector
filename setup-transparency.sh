#!/bin/bash
set -euo pipefail

echo "═══════════════════════════════════════════════════════════════"
echo "  SYS-INSPECTOR TRANSPARENCY SETUP (RLM COMPLIANT)"
echo "═══════════════════════════════════════════════════════════════"

# ------------------------------------------------------------------
# 1. Create collector scripts (with correct permissions)
# ------------------------------------------------------------------
COLLECTOR_DIR="/usr/local/share/sys-inspector/src/collectors"
mkdir -p "$COLLECTOR_DIR"

cat > "$COLLECTOR_DIR/journald-collector.sh" << 'EOF'
#!/usr/bin/env bash
# journald-collector.sh – Streams recent journal entries into database

set -euo pipefail
DB="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
LOG_DIR="${LOG_DIR:-/var/log/sys-inspector}"
LOG_FILE="$LOG_DIR/journald.log"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "=== JOURNALD COLLECTOR START ==="

sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS journal_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    priority INTEGER,
    syslog_identifier TEXT,
    message TEXT,
    unit TEXT,
    pid INTEGER
);
SQL

LAST_RUN=$(sqlite3 "$DB" "SELECT MAX(recorded_at) FROM journal_entries;" 2>/dev/null || echo "1970-01-01")
journalctl --since "$LAST_RUN" --output=json --no-pager 2>/dev/null | jq -r '
  select(.PRIORITY != null) |
  [.PRIORITY, .SYSLOG_IDENTIFIER, .MESSAGE, .UNIT, .PID] | @tsv' | while IFS=$'\t' read -r prio ident msg unit pid; do
    msg="${msg//\'/\'\'}"
    sqlite3 "$DB" "INSERT INTO journal_entries (priority, syslog_identifier, message, unit, pid) VALUES ($prio, '$ident', '$msg', '$unit', $pid);"
done

log "Journal entries captured"
log "=== JOURNALD COLLECTOR COMPLETE ==="
EOF

cat > "$COLLECTOR_DIR/process-collector.sh" << 'EOF'
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

sqlite3 "$DB" "DELETE FROM processes WHERE sampled_at < datetime('now', '-1 hour');"

ps -eo pid,ppid,pcpu,pmem,rss,stat,comm --no-headers | while read -r pid ppid pcpu pmem rss stat comm; do
    cmdline=$(ps -p "$pid" -o args --no-headers 2>/dev/null | head -c 500 | sed "s/'/''/g")
    sqlite3 "$DB" "INSERT INTO processes (pid, ppid, name, cpu_percent, mem_percent, rss_kb, state, cmdline) VALUES ($pid, $ppid, '$comm', $pcpu, $pmem, $rss, '$stat', '$cmdline');"
done

log "Process tree captured"
log "=== PROCESS COLLECTOR COMPLETE ==="
EOF

cat > "$COLLECTOR_DIR/network-collector.sh" << 'EOF'
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

ss -tunap --no-header 2>/dev/null | while read -r net state recv send local remote proc; do
    proto=$(echo "$net" | tr -d ':')
    pid_proc=$(echo "$proc" | grep -oP 'pid=\K[0-9]+' || echo "0")
    process=$(echo "$proc" | grep -oP 'name=\K[^,]+' | sed "s/'/''/g" || echo "unknown")
    sqlite3 "$DB" "INSERT INTO network_connections (protocol, local_addr, remote_addr, state, pid, process) VALUES ('$proto', '$local', '$remote', '$state', ${pid_proc:-0}, '$process');"
done

ss -tuln --no-header 2>/dev/null | while read -r net state recv send local; do
    proto=$(echo "$net" | tr -d ':')
    port=$(echo "$local" | rev | cut -d: -f1 | rev)
    sqlite3 "$DB" "INSERT INTO listening_ports (protocol, port) VALUES ('$proto', $port);"
done

log "Network connections captured"
log "=== NETWORK COLLECTOR COMPLETE ==="
EOF

cat > "$COLLECTOR_DIR/alerter.sh" << 'EOF'
#!/usr/bin/env bash
# alerter.sh – Desktop notifications for critical journal entries

set -euo pipefail
LAST_ALERT_FILE="/tmp/sys-inspector-last-alert"
mkdir -p "$(dirname "$LAST_ALERT_FILE")"

LAST_RUN=$(cat "$LAST_ALERT_FILE" 2>/dev/null || echo "1970-01-01")
journalctl --since "$LAST_RUN" --priority=3 --output=short --no-pager | while read -r line; do
    msg=$(echo "$line" | cut -c1-200 | sed 's/"/\\"/g')
    notify-send -u critical "⚠️ Sys‑Inspector Alert" "$msg"
    echo "$(date -Iseconds)" > "$LAST_ALERT_FILE"
done
EOF

chmod +x "$COLLECTOR_DIR"/*.sh
echo "✓ Collectors installed"

# ------------------------------------------------------------------
# 2. Enhanced TUI (with journal, process, network views)
# ------------------------------------------------------------------
TUI_FILE="/usr/local/share/sys-inspector/src/tui/sys-inspector-tui.sh"
cat > "$TUI_FILE" << 'EOF'
#!/usr/bin/env bash
# sys-inspector-tui.sh – Full system transparency (terminal native)

set -euo pipefail

DB_PATH="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
COLLECTOR_DIR="/usr/local/share/sys-inspector/src/collectors"

db_query() { sqlite3 "$DB_PATH" "$1" 2>/dev/null || echo ""; }
clear_screen() { printf "\033[2J\033[H"; }

show_header() {
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  SYS-INSPECTOR  |  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
}

show_health() {
    local cpu=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    local mem=$(free | awk 'NR==2{printf "%.0f", ($3/$2)*100}')
    local mem_free=$(free -h | awk 'NR==2{print $4}')
    local last_manifest=$(db_query "SELECT MAX(collected_at) FROM service_manifest;")
    local manifest_count=$(db_query "SELECT COUNT(*) FROM service_manifest;")
    echo "📊 SYSTEM STATUS"
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo "  CPU: ${cpu:-0}%    RAM: ${mem:-0}% (${mem_free:-0} free)    Manifests: ${manifest_count:-0}"
    echo "  Last manifest: ${last_manifest:-never run}"
    echo ""
}

show_menu() {
    echo "📋 MENU"
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo "  [1] Boot History        [2] Service Audit     [3] Active Errors"
    echo "  [4] Database Stats      [5] Run Collectors    [6] System Check"
    echo "  [7] 📰 Journal Logs     [8] 📈 Process Tree    [9] 🌐 Network"
    echo "  [0] Exit"
    echo ""
    echo -n "  Choose (0-9): "
}

action_boot_history() {
    clear_screen
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  BOOT HISTORY (last 20 boots)"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    sqlite3 -column -header "$DB_PATH" \
        "SELECT boot_ts, printf('%.1fs', total_ms/1000.0) AS total_seconds, slowest_unit
         FROM boot_health WHERE total_ms > 0 ORDER BY id DESC LIMIT 20;"
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo -n "  Press Enter to return to menu... "
    read
}

action_service_audit() {
    clear_screen
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  SERVICE AUDIT (state counts)"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    sqlite3 -column -header "$DB_PATH" \
        "SELECT state, COUNT(*) as count FROM service_manifest GROUP BY state ORDER BY count DESC;"
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo -n "  Press Enter to return to menu... "
    read
}

action_errors() {
    clear_screen
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  ACTIVE ERRORS"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    local output=$(sqlite3 -column -header "$DB_PATH" \
        "SELECT timestamp, service, severity, message FROM error_log WHERE resolved=0 ORDER BY timestamp DESC LIMIT 30;")
    if [[ -z "$output" ]]; then
        echo "  ✓ No active errors. System is running cleanly."
    else
        echo "$output"
    fi
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo -n "  Press Enter to return to menu... "
    read
}

action_db_stats() {
    clear_screen
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  DATABASE STATISTICS"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Boot records:      $(db_query "SELECT COUNT(*) FROM boot_health WHERE total_ms > 0;")"
    echo "  Resource samples:  $(db_query "SELECT COUNT(*) FROM resource_samples;")"
    echo "  Shutdown captures: $(db_query "SELECT COUNT(*) FROM shutdown_capture;")"
    echo "  Service manifests: $(db_query "SELECT COUNT(*) FROM service_manifest;")"
    echo "  Active errors:     $(db_query "SELECT COUNT(*) FROM error_log WHERE resolved=0;")"
    echo "  Journal entries:   $(db_query "SELECT COUNT(*) FROM journal_entries;")"
    echo "  Processes:         $(db_query "SELECT COUNT(*) FROM processes;")"
    echo "  Network conns:     $(db_query "SELECT COUNT(*) FROM network_connections;")"
    echo "  Listening ports:   $(db_query "SELECT COUNT(*) FROM listening_ports;")"
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo -n "  Press Enter to return to menu... "
    read
}

run_collector() {
    local name="$1" script="$2"
    clear_screen
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  RUNNING COLLECTOR: $name"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    if [[ ! -f "$script" ]]; then
        echo "  ERROR: Collector script not found: $script"
    else
        bash "$script"
    fi
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo -n "  Press Enter to continue... "
    read
}

action_collectors_menu() {
    while true; do
        clear_screen
        echo ""
        echo "════════════════════════════════════════════════════════════════════════════════════"
        echo "  RUN COLLECTOR"
        echo "════════════════════════════════════════════════════════════════════════════════════"
        echo ""
        echo "  [1] Boot Health"
        echo "  [2] Service Manifest"
        echo "  [3] Resource Sample"
        echo "  [4] 📰 Journal Logs"
        echo "  [5] 📈 Process Tree"
        echo "  [6] 🌐 Network"
        echo "  [0] Back to Main Menu"
        echo ""
        echo -n "  Choose (0-6): "
        read choice
        case "$choice" in
            1) run_collector "Boot Health" "$COLLECTOR_DIR/boot-health.sh" ;;
            2) run_collector "Service Manifest" "$COLLECTOR_DIR/service-manifest.sh" ;;
            3) run_collector "Resource Sample" "$COLLECTOR_DIR/contention-alert.sh" ;;
            4) run_collector "Journal Logs" "$COLLECTOR_DIR/journald-collector.sh" ;;
            5) run_collector "Process Tree" "$COLLECTOR_DIR/process-collector.sh" ;;
            6) run_collector "Network" "$COLLECTOR_DIR/network-collector.sh" ;;
            0) break ;;
            *) echo "  Invalid choice"; sleep 1 ;;
        esac
    done
}

action_journal_view() {
    clear_screen
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  RECENT JOURNAL ENTRIES (last 100)"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    sqlite3 -column -header "$DB_PATH" \
        "SELECT datetime(recorded_at,'localtime') as ts, priority, syslog_identifier, substr(message,1,80) as msg 
         FROM journal_entries ORDER BY recorded_at DESC LIMIT 100;"
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo -n "  Press Enter to return to menu... "
    read
}

action_process_view() {
    clear_screen
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  PROCESS TREE (top 50 by CPU)"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    sqlite3 -column -header "$DB_PATH" \
        "SELECT name, pid, cpu_percent, mem_percent, state, substr(cmdline,1,60) as cmd 
         FROM processes ORDER BY cpu_percent DESC LIMIT 50;"
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo -n "  Press Enter to return to menu... "
    read
}

action_network_view() {
    clear_screen
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  LISTENING PORTS"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    sqlite3 -column -header "$DB_PATH" \
        "SELECT protocol, port FROM listening_ports ORDER BY port;"
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  ACTIVE CONNECTIONS"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    sqlite3 -column -header "$DB_PATH" \
        "SELECT protocol, local_addr, remote_addr, state, process FROM network_connections ORDER BY sampled_at DESC LIMIT 50;"
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo -n "  Press Enter to return to menu... "
    read
}

action_system_check() {
    clear_screen
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  SYSTEM CHECK"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Disk Space:"
    df -h /var/lib/sys-inspector /var/log/sys-inspector 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  Database Status:"
    if [[ -f "$DB_PATH" ]]; then
        local db_size=$(du -h "$DB_PATH" | cut -f1)
        echo "    File: $DB_PATH"
        echo "    Size: $db_size"
        echo "    Integrity: $(sqlite3 "$DB_PATH" 'PRAGMA integrity_check;')"
    else
        echo "    Database not found"
    fi
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo -n "  Press Enter to return to menu... "
    read
}

main() {
    if [[ ! -f "$DB_PATH" ]]; then
        echo "ERROR: Database not found at $DB_PATH"
        echo "Run: sudo ./scripts/install.sh"
        exit 1
    fi
    while true; do
        clear_screen
        show_header
        show_health
        show_menu
        read choice
        case "$choice" in
            0) clear_screen; echo ""; echo "  Goodbye!"; echo ""; exit 0 ;;
            1) action_boot_history ;;
            2) action_service_audit ;;
            3) action_errors ;;
            4) action_db_stats ;;
            5) action_collectors_menu ;;
            6) action_system_check ;;
            7) action_journal_view ;;
            8) action_process_view ;;
            9) action_network_view ;;
            *) echo -e "\n  Invalid choice: $choice"; sleep 1 ;;
        esac
    done
}

main "$@"
EOF

chmod +x "$TUI_FILE"
# Symlink for easy access
ln -sf "$TUI_FILE" /usr/local/bin/sys-inspector-tui
echo "✓ Enhanced TUI installed"

# ------------------------------------------------------------------
# 3. Systemd timers for automatic collection
# ------------------------------------------------------------------
cat > /etc/systemd/system/sys-inspector-journal.timer << 'EOF'
[Unit]
Description=Collect journal logs every minute

[Timer]
OnCalendar=*:0/1

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/sys-inspector-journal.service << 'EOF'
[Unit]
Description=Journal log collector

[Service]
ExecStart=/usr/local/share/sys-inspector/src/collectors/journald-collector.sh
User=root
EOF

cat > /etc/systemd/system/sys-inspector-process.timer << 'EOF'
[Unit]
Description=Collect process tree every 5 minutes

[Timer]
OnCalendar=*:0/5

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/sys-inspector-process.service << 'EOF'
[Unit]
Description=Process tree collector

[Service]
ExecStart=/usr/local/share/sys-inspector/src/collectors/process-collector.sh
User=root
EOF

cat > /etc/systemd/system/sys-inspector-network.timer << 'EOF'
[Unit]
Description=Collect network connections every 5 minutes

[Timer]
OnCalendar=*:0/5

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/sys-inspector-network.service << 'EOF'
[Unit]
Description=Network collector

[Service]
ExecStart=/usr/local/share/sys-inspector/src/collectors/network-collector.sh
User=root
EOF

cat > /etc/systemd/system/sys-inspector-alerter.timer << 'EOF'
[Unit]
Description=Check for critical alerts every minute

[Timer]
OnCalendar=*:0/1

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/sys-inspector-alerter.service << 'EOF'
[Unit]
Description=Desktop alert service

[Service]
ExecStart=/usr/local/share/sys-inspector/src/collectors/alerter.sh
User=owner
Environment=DISPLAY=:0
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
EOF

# Reload systemd and enable timers
systemctl daemon-reload
for timer in journal process network alerter; do
    systemctl enable --now "sys-inspector-$timer.timer" 2>/dev/null || true
done

echo "✓ Systemd timers enabled"

# ------------------------------------------------------------------
# 4. Run collectors once to populate data
# ------------------------------------------------------------------
echo "Running collectors for initial data..."
"$COLLECTOR_DIR/journald-collector.sh" || true
"$COLLECTOR_DIR/process-collector.sh" || true
"$COLLECTOR_DIR/network-collector.sh" || true

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  SETUP COMPLETE"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  ▶ TUI:        sys-inspector-tui   (now with journal, process, network views)"
echo "  ▶ Dashboard:  http://127.0.0.1:8765/"
echo ""
echo "  All collectors will run automatically via systemd timers."
echo "  Desktop alerts will appear for critical journal messages."
echo ""