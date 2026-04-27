#!/usr/bin/env bash
# service-manifest.sh — Generate a complete service audit with rationale
# Usage: service-manifest.sh [--json]
# Self-healing: regenerates idempotently; old entries superseded
# Citation: systemctl(1) — 'list-unit-files lists all installed unit files' [Tier 2: man7.org]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -f "$REPO_ROOT/config/sys-inspector.conf" ]]; then
    source "$REPO_ROOT/config/sys-inspector.conf"
else
    SYSTEM_INSPECTOR_DB="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
fi

OUTPUT_FORMAT="${1:-text}"

# --- Rationale database: why each service is in its current state ---
# Format: "unit_name|state|rationale"
declare -a RATIONALE=(
    "abrtd.service|enabled|Crash forensics — captures app/core dumps for debugging"
    "accounts-daemon.service|enabled|Required by SDDM for user login management"
    "audit-rules.service|enabled|Kernel audit framework — required by selinux"
    "crond.service|enabled|Scheduled task runner — check 'crontab -l' for jobs"
    "dbus-broker.service|enabled|System IPC bus — essential for desktop operation"
    "firewalld.service|disabled|D-Bus activated — starts on demand, doesn't block boot"
    "NetworkManager.service|enabled|Wi-Fi/Ethernet connectivity — essential"
    "sddm.service|enabled|Display manager — login screen"
    "sshd.service|enabled|Secure shell for remote access — disable if not needed"
    "systemd-journald.service|static|Core logging — never disable"
    "systemd-oomd.service|disabled|Userspace OOM killer — kernel OOM sufficient for desktop"
    "fix-wifi.service|enabled|BCM4331 Wi-Fi recovery post-boot — custom script"
    "ollama.service|masked|LLM inference server — start manually when needed"
    "tuned.service|masked|Enterprise performance tuning — no benefit on laptop"
    "rsyslog.service|masked|Redundant text logger — systemd-journald handles all logging"
    "ModemManager.service|masked|WWAN modem management — no cellular modem present"
    "bluetooth.service|masked|Bluetooth — disabled per user preference"
    "avahi-daemon.service|masked|mDNS/Bonjour — no .local name resolution needed"
    "bolt.service|masked|Thunderbolt device manager — no TB devices connected"
    "haveged.service|masked|Entropy daemon — kernel 5.4+ has built-in entropy"
    "irqbalance.service|masked|IRQ balancer for multi-socket servers — single socket laptop"
    "mcelog.service|masked|Machine check exception logger — kernel handles MCEs directly"
    "smartd.service|masked|SMART disk monitoring — check manually with smartctl"
    "rtkit-daemon.service|masked|Realtime kit for pro-audio — not needed"
    "chronyd.service|masked|NTP client — dual-boot macOS handles time sync"
    "gssproxy.service|masked|Kerberos/NFS credential proxy — no enterprise auth"
    "kdeconnectd.service|masked|KDE Connect phone sync — not used"
    "akonadi.service|masked|KDE PIM database — no KDE email/calendar usage"
    "dnf-makecache.timer|disabled|Package metadata cache — run dnf manually"
    "NetworkManager-wait-online.service|disabled|Boot waits for network — unnecessary on laptop"
)

main() {
    local manifest_ts
    manifest_ts="$(date '+%Y-%m-%d %H:%M:%S')"

    if [[ -f "$SYSTEM_INSPECTOR_DB" ]]; then
        # Remove previous manifest entries
        sqlite3 "$SYSTEM_INSPECTOR_DB" \
            "DELETE FROM service_manifest WHERE manifest_ts < '$manifest_ts';"

        # Build associative array for O(1) rationale lookup
        declare -A RATIONALE_MAP
        for entry in "${RATIONALE[@]}"; do
            IFS='|' read -r unit state reason <<< "$entry"
            RATIONALE_MAP["$unit"]="$reason"
        done

        # Iterate all systemd units and insert with rationale
        while IFS=' ' read -r unit state preset; do
            local reason="${RATIONALE_MAP[$unit]:-No rationale recorded}"
            sqlite3 "$SYSTEM_INSPECTOR_DB" \
                "INSERT INTO service_manifest (manifest_ts, unit_name, state, preset, rationale)
                 VALUES ('$manifest_ts', '$unit', '$state', '$preset', '${reason//\'/\'\'}');" 2>/dev/null || true
        done < <(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1, $2, $3}')
    fi

    # Output in requested format
    if [[ "$OUTPUT_FORMAT" == "--json" ]]; then
        for entry in "${RATIONALE[@]}"; do
            IFS='|' read -r unit state reason <<< "$entry"
            printf '{"unit":"%s","state":"%s","rationale":"%s"}\n' "$unit" "$state" "$reason"
        done
    else
        printf "%-50s %-12s %s\n" "UNIT" "STATE" "RATIONALE"
        printf "%-50s %-12s %s\n" "----" "-----" "---------"
        for entry in "${RATIONALE[@]}"; do
            IFS='|' read -r unit state reason <<< "$entry"
            printf "%-50s %-12s %s\n" "$unit" "$state" "$reason"
        done
    fi
}

main "$@"
