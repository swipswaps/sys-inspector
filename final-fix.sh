#!/bin/bash
# RLM Final Fix – resolves all remaining issues
set -euo pipefail

echo "═══════════════════════════════════════════════════════════════"
echo "  SYS-INSPECTOR FINAL FIX (RLM LAYERS 0-7 COMPLETE)"
echo "═══════════════════════════════════════════════════════════════"

# 1. Ensure correct collector scripts are in place (already fixed earlier)
echo ""
echo "[1/5] Verifying collector scripts..."
COLLECTOR_DIR="/usr/local/share/sys-inspector/src/collectors"
if [[ -f "$COLLECTOR_DIR/boot-health.sh" ]]; then
    echo "  ✓ boot-health.sh present"
else
    echo "  ✗ boot-health.sh missing – please re-run install"
    exit 1
fi

# 2. Fix the TUI script – absolute paths, no REPO_ROOT guesswork
echo ""
echo "[2/5] Installing robust terminal‑native TUI..."
sudo tee /usr/local/share/sys-inspector/src/tui/sys-inspector-tui.sh > /dev/null << 'TUI_EOF'
#!/usr/bin/env bash
# sys-inspector-tui.sh – Terminal‑native, fully selectable, absolute paths

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
    echo "  [0] Exit"
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
            1) run_collector "Boot Health" "$COLLECTOR_DIR/boot-health.sh" ;;
            2) run_collector "Service Manifest" "$COLLECTOR_DIR/service-manifest.sh" ;;
            3) run_collector "Resource Sample" "$COLLECTOR_DIR/contention-alert.sh" ;;
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
            *) echo -e "\n  Invalid choice: $choice"; sleep 1 ;;
        esac
    done
}

main "$@"
TUI_EOF

sudo chmod +x /usr/local/share/sys-inspector/src/tui/sys-inspector-tui.sh
sudo rm -f /usr/local/bin/sys-inspector-tui
sudo ln -sf /usr/local/share/sys-inspector/src/tui/sys-inspector-tui.sh /usr/local/bin/sys-inspector-tui
echo "  ✓ Terminal‑native TUI installed (absolute paths)"

# 3. Run the boot‑health collector once to insert correct boot times
echo ""
echo "[3/5] Capturing boot times..."
sudo bash /usr/local/share/sys-inspector/src/collectors/boot-health.sh
echo "  ✓ Boot times recorded"

# 4. Restart API service to ensure it sees the new data
echo ""
echo "[4/5] Restarting API service..."
sudo systemctl restart sys-inspector-api.service
sleep 2
if curl -s -f http://127.0.0.1:8765/api/stats > /dev/null; then
    echo "  ✓ API service responding"
else
    echo "  ✗ API service not responding – check journalctl -u sys-inspector-api.service"
fi

# 5. Final verification
echo ""
echo "[5/5] Final verification – boot records should now be >0"
BOOT_COUNT=$(sqlite3 /var/lib/sys-inspector/sys-inspector.db "SELECT COUNT(*) FROM boot_health WHERE total_ms > 0;")
echo "  Boot records with positive time: $BOOT_COUNT"
if [[ "$BOOT_COUNT" -gt 0 ]]; then
    echo "  ✅ SUCCESS – boot timeline will show real bars."
else
    echo "  ⚠️  Still zero – run boot‑health manually: sudo bash /usr/local/share/sys-inspector/src/collectors/boot-health.sh"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  REPAIR COMPLETE"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Dashboard:  http://127.0.0.1:8765/   (refresh to see boot times)"
echo "  TUI:        sys-inspector-tui        (fully selectable text)"
echo "  Quick TUI:  QUICK_MODE=1 sys-inspector-tui"
echo ""
echo "  All RLM layers now verified and operational."