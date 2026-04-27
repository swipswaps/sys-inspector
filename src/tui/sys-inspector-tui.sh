#!/usr/bin/env bash
# sys-inspector-tui.sh — Terminal UI dashboard for system transparency
# Requires: dialog(1) or whiptail(1)
# Self-healing: falls back to plain text mode if dialog unavailable
# Citation: dialog(1) — 'Dialog is a program that will let you present a variety
#   of questions or display messages using dialog boxes' [Tier 2: man7.org]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/config/sys-inspector.conf" 2>/dev/null || true
SYSTEM_INSPECTOR_DB="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"

# Detect available UI backend (dialog > whiptail > plain text)
if command -v dialog &>/dev/null; then
    DIALOG="dialog"
elif command -v whiptail &>/dev/null; then
    DIALOG="whiptail"
else
    DIALOG="text"
fi

# --- Data gathering functions (all read from SQLite DB) ---
get_boot_summary() {
    if [[ -f "$SYSTEM_INSPECTOR_DB" ]]; then
        sqlite3 -separator ' | ' "$SYSTEM_INSPECTOR_DB" \
            "SELECT boot_ts, printf('%.1fs', total_ms/1000.0), slowest_unit
             FROM boot_health ORDER BY id DESC LIMIT 5;" 2>/dev/null || echo "No data yet"
    else
        echo "Database not found. Run db-init.sh first."
    fi
}

get_resource_current() {
    local cpu mem iowait
    cpu=$(awk '{u=$2+$4; t=$2+$4+$5; if (t>0) printf "%.1f%%", (u/t)*100}' /proc/stat 2>/dev/null || echo "N/A")
    mem="$(free -h | awk 'NR==2{print $3"/"$2}')"
    iowait=$(iostat -c 1 1 2>/dev/null | awk 'END{print $4"%"}' || echo "N/A")
    echo "CPU: $cpu | RAM: $mem | IOWait: $iowait"
}

get_service_count() {
    local enabled masked
    enabled=$(systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | wc -l || echo "?")
    masked=$(systemctl list-unit-files --state=masked --no-legend 2>/dev/null | wc -l || echo "?")
    echo "Enabled: $enabled | Masked: $masked"
}

get_error_summary() {
    if [[ -f "$SYSTEM_INSPECTOR_DB" ]]; then
        sqlite3 -separator ' | ' "$SYSTEM_INSPECTOR_DB" \
            "SELECT source, count, last_seen FROM error_log WHERE resolved=0 ORDER BY count DESC LIMIT 5;" 2>/dev/null || echo "No errors"
    else
        echo "Database not found."
    fi
}

# --- Plain text mode (no dialog/whiptail installed) ---
text_mode() {
    while true; do
        clear
        echo "══════════════════════════════════════════════"
        echo "  SYS-INSPECTOR TUI  |  $(date)"
        echo "══════════════════════════════════════════════"
        echo ""
        echo "  RESOURCES: $(get_resource_current)"
        echo "  SERVICES:  $(get_service_count)"
        echo ""
        echo "  RECENT BOOTS:"
        get_boot_summary
        echo ""
        echo "  ACTIVE ERRORS:"
        get_error_summary
        echo ""
        echo "──────────────────────────────────────────────"
        echo "  [1] Refresh     [2] Full Boot History"
        echo "  [3] Service Audit   [4] Error Detail"
        echo "  [5] Database Stats  [0] Exit"
        echo "──────────────────────────────────────────────"
        read -p "  Choice: " choice
        case "$choice" in
            0) break ;;
            1) continue ;;
            2) bash "$REPO_ROOT/src/db/db-query.sh" boot-latest | less ;;
            3) bash "$REPO_ROOT/src/db/db-query.sh" manifest-summary | less ;;
            4) bash "$REPO_ROOT/src/db/db-query.sh" errors-active | less ;;
            5) bash "$REPO_ROOT/src/db/db-query.sh" baseline | less ;;
        esac
    done
}

# --- Dialog/whiptail mode (FIXED: menu selection captured correctly) ---
dialog_mode() {
    while true; do
        local resource_info service_info menu_choice choice_status
        resource_info="$(get_resource_current)"
        service_info="$(get_service_count)"
        # dialog sends output to stderr; capture it via 2>&1
        menu_choice=$($DIALOG --clear --title "SYS-INSPECTOR $(date '+%H:%M:%S')" \
            --menu "$resource_info\n$service_info\n\nSelect a view:" \
            24 80 12 \
            1 "Refresh Dashboard" \
            2 "Boot History" \
            3 "Service Audit" \
            4 "Active Errors" \
            5 "Database Statistics" \
            6 "Resource History (last hour)" \
            0 "Exit" \
            2>&1 1>/dev/tty)
        choice_status=$?
        clear
        if [ $choice_status -ne 0 ]; then
            exit 0  # User pressed Cancel or ESC
        fi
        case "$menu_choice" in
            0) exit 0 ;;
            1) continue ;;
            2) bash "$REPO_ROOT/src/db/db-query.sh" boot-latest | less ;;
            3) bash "$REPO_ROOT/src/db/db-query.sh" manifest-summary | less ;;
            4) bash "$REPO_ROOT/src/db/db-query.sh" errors-active | less ;;
            5) bash "$REPO_ROOT/src/db/db-query.sh" baseline | less ;;
            6) bash "$REPO_ROOT/src/db/db-query.sh" resources-recent | less ;;
        esac
    done
}

# --- Dispatch to appropriate mode ---
case "$DIALOG" in
    text) text_mode ;;
    *)    dialog_mode ;;
esac
