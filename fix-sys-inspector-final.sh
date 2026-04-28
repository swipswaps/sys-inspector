#!/bin/bash
# RLM Complete Fix – Run as root or with sudo

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "  SYS-INSPECTOR FINAL REPAIR (RLM LAYERS 0-7)"
echo "═══════════════════════════════════════════════════════════════"

# 1. Install Flask globally (so root can use it)
echo ""
echo "[1/4] Installing Flask for system Python..."
sudo pip3 install flask --break-system-packages 2>/dev/null || sudo pip3 install flask
echo "  ✓ Flask installed"

# 2. Fix systemd service with absolute paths
echo ""
echo "[2/4] Recreating systemd service..."
sudo tee /etc/systemd/system/sys-inspector-api.service > /dev/null << 'EOF'
[Unit]
Description=Sys-Inspector API Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/home/owner/Documents/8aa812a2-06af-4313-81f8-bddfde353308/sys-inspector
ExecStart=/usr/bin/python3 /home/owner/Documents/8aa812a2-06af-4313-81f8-bddfde353308/sys-inspector/src/api/api-server.py
Restart=always
RestartSec=5
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl restart sys-inspector-api.service
sleep 2
echo "  ✓ API service restarted"

# 3. Verify API is responding
echo ""
echo "[3/4] Testing API endpoints..."
if curl -s -f http://127.0.0.1:8765/api/stats > /dev/null; then
    echo "  ✓ API is reachable"
    curl -s http://127.0.0.1:8765/api/stats | python3 -m json.tool
else
    echo "  ✗ API not responding – check journal: sudo journalctl -u sys-inspector-api.service -n 20"
    exit 1
fi

# 4. Replace TUI with terminal-native version (fully selectable)
echo ""
echo "[4/4] Installing terminal‑native TUI (no dialog, fully selectable)..."

cat > /home/owner/Documents/8aa812a2-06af-4313-81f8-bddfde353308/sys-inspector/src/tui/sys-inspector-tui.sh << 'TUI_EOF'
#!/usr/bin/env bash
# sys-inspector-tui.sh — Terminal‑native UI – FULL TEXT SELECTION
# No dialog, no whiptail – pure echo/read. All output selectable.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/config/sys-inspector.conf" 2>/dev/null || true
DB_PATH="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"

# Simple colors (optional, won't break selection)
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

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
    echo -e "${CYAN}📊 SYSTEM STATUS${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${GREEN}CPU:${NC} ${cpu:-0}%    ${GREEN}RAM:${NC} ${mem:-0}% (${mem_free:-0} free)    ${GREEN}Manifests:${NC} ${manifest_count:-0}"
    echo "  ${GREEN}Last manifest:${NC} ${last_manifest:-never run}"
    echo ""
}

show_menu() {
    echo -e "${CYAN}📋 MENU${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${GREEN}[1]${NC} Boot History        ${GREEN}[2]${NC} Service Audit     ${GREEN}[3]${NC} Active Errors"
    echo -e "  ${GREEN}[4]${NC} Database Stats      ${GREEN}[5]${NC} Run Collectors    ${GREEN}[6]${NC} System Check"
    echo -e "  ${GREEN}[0]${NC} Exit"
    echo ""
    echo -n "  Choose (0-6): "
}

action_boot_history() {
    clear_screen
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo "  BOOT HISTORY (last 20 boots)"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    local output=$(sqlite3 -column -header "$DB_PATH" \
        "SELECT boot_ts, printf('%.1fs', COALESCE(total_ms,0)/1000.0) AS total_seconds, 
                COALESCE(slowest_unit, 'N/A') AS slowest_unit
         FROM boot_health ORDER BY id DESC LIMIT 20;" 2>/dev/null)
    if [[ -z "$output" ]]; then
        echo "  No boot history found. Run collector [5] → Boot Health"
    else
        echo "$output"
    fi
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
    local output=$(sqlite3 -column -header "$DB_PATH" \
        "SELECT state, COUNT(*) as count FROM service_manifest GROUP BY state ORDER BY count DESC;" 2>/dev/null)
    if [[ -z "$output" ]]; then
        echo "  No service manifest found. Run collector [5] → Service Manifest"
    else
        echo "$output"
    fi
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
        "SELECT timestamp, service, severity, message FROM error_log WHERE resolved=0 ORDER BY timestamp DESC LIMIT 30;" 2>/dev/null)
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
    local boot_count=$(db_query "SELECT COUNT(*) FROM boot_health;")
    local samples=$(db_query "SELECT COUNT(*) FROM resource_samples;")
    local shutdown=$(db_query "SELECT COUNT(*) FROM shutdown_capture;")
    local manifests=$(db_query "SELECT COUNT(*) FROM service_manifest;")
    local errors=$(db_query "SELECT COUNT(*) FROM error_log WHERE resolved=0;")
    echo "  Boot records:      $boot_count"
    echo "  Resource samples:  $samples"
    echo "  Shutdown captures: $shutdown"
    echo "  Service manifests: $manifests"
    echo "  Active errors:     $errors"
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
        echo "  [0] Back to Main Menu"
        echo ""
        echo -n "  Choose (0-3): "
        read choice
        case "$choice" in
            1) run_collector "Boot Health" "$REPO_ROOT/src/collectors/boot-health.sh" ;;
            2) run_collector "Service Manifest" "$REPO_ROOT/src/collectors/service-manifest.sh" ;;
            3) run_collector "Resource Sample" "$REPO_ROOT/src/collectors/contention-alert.sh" ;;
            0) break ;;
            *) echo "  Invalid choice"; sleep 1 ;;
        esac
    done
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
            *) echo -e "\n  ${RED}Invalid choice: $choice${NC}"; sleep 1 ;;
        esac
    done
}

main "$@"
TUI_EOF

chmod +x /home/owner/Documents/8aa812a2-06af-4313-81f8-bddfde353308/sys-inspector/src/tui/sys-inspector-tui.sh
sudo rm -f /usr/local/bin/sys-inspector-tui
sudo ln -sf /home/owner/Documents/8aa812a2-06af-4313-81f8-bddfde353308/sys-inspector/src/tui/sys-inspector-tui.sh /usr/local/bin/sys-inspector-tui
echo "  ✓ Terminal‑native TUI installed"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  REPAIR COMPLETE"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Dashboard:  http://127.0.0.1:8765/"
echo "  TUI:        sys-inspector-tui    (fully selectable)"
echo "  Quick TUI:  QUICK_MODE=1 sys-inspector-tui"
echo ""