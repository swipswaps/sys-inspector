sudo tee /usr/local/share/sys-inspector/src/collectors/journald-collector.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

DB="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
LOG_DIR="${LOG_DIR:-/var/log/sys-inspector}"
mkdir -p "$LOG_DIR"

sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS journal_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    priority INTEGER,
    syslog_identifier TEXT,
    message TEXT,
    unit TEXT,
    pid INTEGER
);"

# Get last recorded timestamp, or default to an empty string (all entries)
LAST_RUN=$(sqlite3 "$DB" "SELECT MAX(recorded_at) FROM journal_entries;" 2>/dev/null || echo "")

# If LAST_RUN is empty or not a valid timestamp, use a safe default
if [[ -z "$LAST_RUN" || "$LAST_RUN" == "1970-01-01" ]]; then
    SINCE=""
else
    # Ensure timestamp is in a format journalctl accepts (YYYY-MM-DD HH:MM:SS)
    SINCE="--since=\"$LAST_RUN\""
fi

# Collect journal entries
eval journalctl $SINCE --output=json --no-pager 2>/dev/null | jq -r '
  select(.PRIORITY != null) |
  [.PRIORITY, .SYSLOG_IDENTIFIER, .MESSAGE, .UNIT, .PID] | @tsv' | while IFS=$'\t' read -r prio ident msg unit pid; do
    # Escape single quotes in message
    msg="${msg//\'/\'\'}"
    sqlite3 "$DB" "INSERT INTO journal_entries (priority, syslog_identifier, message, unit, pid)
                   VALUES ($prio, '$ident', '$msg', '$unit', $pid);"
done
EOF

sudo chmod +x /usr/local/share/sys-inspector/src/collectors/journald-collector.sh