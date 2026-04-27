#!/usr/bin/env bash
# db-init.sh — Initialize or migrate the sys-inspector SQLite database
# Idempotent: safe to run multiple times
# Citation: SQLite CLI documentation [Tier 2: sqlite.org/cli.html]
set -euo pipefail

DB_PATH="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
SCHEMA_FILE="$(dirname "$0")/schema.sql"

main() {
    # Create data directory if missing
    sudo mkdir -p "$(dirname "$DB_PATH")"
    sudo chown "$(whoami):$(whoami)" "$(dirname "$DB_PATH")"

    # Initialize database from schema (idempotent via IF NOT EXISTS)
    if [[ ! -f "$DB_PATH" ]]; then
        echo "[db-init] Creating database at $DB_PATH"
        sqlite3 "$DB_PATH" < "$SCHEMA_FILE"
        echo "[db-init] Database created."
    else
        echo "[db-init] Database exists; applying schema migrations..."
        sqlite3 "$DB_PATH" < "$SCHEMA_FILE"
        echo "[db-init] Schema up to date."
    fi

    # Set restrictive permissions
    chmod 600 "$DB_PATH"
    echo "[db-init] Done."
}

main "$@"
