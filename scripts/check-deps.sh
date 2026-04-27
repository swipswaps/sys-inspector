#!/usr/bin/env bash
# check-deps.sh — Verify all sys-inspector dependencies and report status
# Usage: bash check-deps.sh
# Exit code: 0 = all required deps present; 1 = at least one missing
set -euo pipefail

REQUIRED=0
OPTIONAL=0
MISSING_REQUIRED=""
MISSING_OPTIONAL=""

# Required: collectors/API will fail without these
declare -A REQUIRED_DEPS=(
    [sqlite3]="SQLite database engine (package: sqlite3)"
    [python3]="Python 3 interpreter (package: python3)"
    [systemctl]="systemd service manager (package: systemd)"
)

# Optional: graceful degradation if missing
declare -A OPTIONAL_DEPS=(
    [dialog]="TUI dashboard (package: dialog) — falls back to plain text"
    [jq]="JSON processing for journal analysis (package: jq) — falls back to empty JSON"
    [mpstat]="CPU metrics (package: sysstat) — falls back to /proc/loadavg"
    [iostat]="Disk I/O metrics (package: sysstat) — falls back to 0.0"
    [notify-send]="Desktop alerts (package: libnotify) — falls back to journal only"
)

echo "=== SYS-INSPECTOR DEPENDENCY CHECK ==="
echo ""

for cmd in "${!REQUIRED_DEPS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
        echo "  PASS $cmd — ${REQUIRED_DEPS[$cmd]}"
    else
        echo "  FAIL $cmd — ${REQUIRED_DEPS[$cmd]}"
        MISSING_REQUIRED="$MISSING_REQUIRED $cmd"
        REQUIRED=1
    fi
done

echo ""
for cmd in "${!OPTIONAL_DEPS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
        echo "  PASS $cmd — ${OPTIONAL_DEPS[$cmd]}"
    else
        echo "  WARN $cmd — ${OPTIONAL_DEPS[$cmd]}"
        MISSING_OPTIONAL="$MISSING_OPTIONAL $cmd"
        OPTIONAL=1
    fi
done

echo ""
if [ $REQUIRED -eq 0 ]; then
    echo "All required dependencies present."
else
    echo "Missing required dependencies:$MISSING_REQUIRED"
    echo "Install: sudo dnf install${MISSING_REQUIRED}"
fi

if [ $OPTIONAL -eq 1 ]; then
    echo "Missing optional dependencies:$MISSING_OPTIONAL"
    echo "Install: sudo dnf install${MISSING_OPTIONAL}"
    echo "These degrade gracefully; full functionality needs them."
fi

exit $REQUIRED
