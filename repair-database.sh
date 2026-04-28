#!/usr/bin/env bash
# repair-database.sh — RLM-based database repair with proper column migration
# Handles schema upgrades without data loss
# RLM Layer 8: Transactional schema upgrades

set -euo pipefail

DB_PATH="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
BACKUP_PATH="${DB_PATH}.backup.$(date +%Y%m%d-%H%M%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  SYS-INSPECTOR DATABASE REPAIR (RLM Layer 8)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Create backup
if [[ -f "$DB_PATH" ]]; then
    echo -e "${BLUE}[Backup]${NC} Creating backup..."
    cp "$DB_PATH" "$BACKUP_PATH"
    echo -e "  ${GREEN}✓${NC} Backup: $BACKUP_PATH"
fi

# Run the repair with proper column migration
echo -e "${BLUE}[Repair]${NC} Upgrading database schema..."

sqlite3 "$DB_PATH" << 'EOF'
-- Turn off foreign keys during migration
PRAGMA foreign_keys=OFF;

-- ============================================================
-- Step 1: Upgrade boot_health (ensure all columns exist)
-- ============================================================
CREATE TABLE IF NOT EXISTS boot_health (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    boot_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    total_ms INTEGER DEFAULT 0,
    kernel_ms INTEGER DEFAULT 0,
    initrd_ms INTEGER DEFAULT 0,
    userspace_ms INTEGER DEFAULT 0,
    slowest_unit TEXT DEFAULT '',
    baseline_dev REAL DEFAULT 0
);

-- ============================================================
-- Step 2: Upgrade resource_samples table (add missing columns)
-- ============================================================
-- Create new table with all 17 columns
DROP TABLE IF EXISTS resource_samples_new;
CREATE TABLE resource_samples_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    cpu_user REAL DEFAULT 0,
    cpu_system REAL DEFAULT 0,
    cpu_idle REAL DEFAULT 0,
    cpu_iowait REAL DEFAULT 0,
    mem_total INTEGER DEFAULT 0,
    mem_used INTEGER DEFAULT 0,
    mem_free INTEGER DEFAULT 0,
    mem_cached INTEGER DEFAULT 0,
    swap_used INTEGER DEFAULT 0,
    load_1min REAL DEFAULT 0,
    load_5min REAL DEFAULT 0,
    load_15min REAL DEFAULT 0,
    disk_read_kb INTEGER DEFAULT 0,
    disk_write_kb INTEGER DEFAULT 0,
    context_switches INTEGER DEFAULT 0,
    interrupts INTEGER DEFAULT 0
);

-- Copy data from old table (if exists)
INSERT INTO resource_samples_new (
    id, sampled_at, cpu_user, cpu_system, cpu_idle, cpu_iowait,
    mem_total, mem_used, mem_free, mem_cached, swap_used,
    load_1min, load_5min, load_15min, disk_read_kb, disk_write_kb
)
SELECT 
    id, 
    COALESCE(sampled_at, CURRENT_TIMESTAMP),
    COALESCE(cpu_user, 0), COALESCE(cpu_system, 0),
    COALESCE(cpu_idle, 0), COALESCE(cpu_iowait, 0),
    COALESCE(mem_total, 0), COALESCE(mem_used, 0),
    COALESCE(mem_free, 0), COALESCE(mem_cached, 0),
    COALESCE(swap_used, 0),
    COALESCE(load_1min, 0), COALESCE(load_5min, 0), COALESCE(load_15min, 0),
    COALESCE(disk_read_kb, 0), COALESCE(disk_write_kb, 0)
FROM resource_samples WHERE id IS NOT NULL;

-- Replace old table
DROP TABLE IF EXISTS resource_samples;
ALTER TABLE resource_samples_new RENAME TO resource_samples;

-- ============================================================
-- Step 3: Upgrade service_manifest (FIX collected_at column)
-- ============================================================
-- Create new table with all columns including collected_at
DROP TABLE IF EXISTS service_manifest_new;
CREATE TABLE service_manifest_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    collected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    unit_name TEXT NOT NULL,
    state TEXT NOT NULL,
    load_state TEXT DEFAULT '',
    active_state TEXT DEFAULT '',
    sub_state TEXT DEFAULT '',
    fragment_path TEXT DEFAULT '',
    unit_file_state TEXT DEFAULT ''
);

-- Copy data from old table
INSERT INTO service_manifest_new (
    id, collected_at, unit_name, state, load_state,
    active_state, sub_state, fragment_path, unit_file_state
)
SELECT 
    id,
    COALESCE(collected_at, CURRENT_TIMESTAMP),
    COALESCE(unit_name, 'unknown'),
    COALESCE(state, 'unknown'),
    COALESCE(load_state, ''),
    COALESCE(active_state, ''),
    COALESCE(sub_state, ''),
    COALESCE(fragment_path, ''),
    COALESCE(unit_file_state, '')
FROM service_manifest WHERE id IS NOT NULL;

-- Replace old table
DROP TABLE IF EXISTS service_manifest;
ALTER TABLE service_manifest_new RENAME TO service_manifest;

-- ============================================================
-- Step 4: Upgrade error_log table (add resolution_note column)
-- ============================================================
-- Create new table with all columns
DROP TABLE IF EXISTS error_log_new;
CREATE TABLE error_log_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    service TEXT NOT NULL,
    severity TEXT CHECK(severity IN ('ERROR', 'WARNING', 'CRITICAL')),
    message TEXT NOT NULL,
    resolved BOOLEAN DEFAULT 0,
    resolution_note TEXT DEFAULT ''
);

-- Copy data from old table
INSERT INTO error_log_new (
    id, timestamp, service, severity, message, resolved, resolution_note
)
SELECT 
    id, 
    COALESCE(timestamp, CURRENT_TIMESTAMP),
    COALESCE(service, 'unknown'),
    COALESCE(severity, 'ERROR'),
    COALESCE(message, ''),
    COALESCE(resolved, 0),
    ''
FROM error_log WHERE id IS NOT NULL;

-- Replace old table
DROP TABLE IF EXISTS error_log;
ALTER TABLE error_log_new RENAME TO error_log;

-- ============================================================
-- Step 5: Ensure shutdown_capture exists
-- ============================================================
CREATE TABLE IF NOT EXISTS shutdown_capture (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    shutdown_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uptime_seconds INTEGER DEFAULT 0,
    active_services INTEGER DEFAULT 0,
    failed_services INTEGER DEFAULT 0,
    cpu_temp REAL DEFAULT 0,
    reason TEXT DEFAULT ''
);

-- ============================================================
-- Step 6: Recreate indexes (safely, only if columns exist)
-- ============================================================
DROP INDEX IF EXISTS idx_resource_samples_time;
DROP INDEX IF EXISTS idx_error_log_time;
DROP INDEX IF EXISTS idx_error_log_unresolved;
DROP INDEX IF EXISTS idx_service_manifest_time;

-- Verify columns exist before creating indexes
SELECT CASE 
    WHEN (SELECT COUNT(*) FROM pragma_table_info('resource_samples') WHERE name='sampled_at') > 0
    THEN (CREATE INDEX idx_resource_samples_time ON resource_samples(sampled_at))
    ELSE 'SKIP: sampled_at missing'
END;

SELECT CASE 
    WHEN (SELECT COUNT(*) FROM pragma_table_info('error_log') WHERE name='timestamp') > 0
    THEN (CREATE INDEX idx_error_log_time ON error_log(timestamp))
    ELSE 'SKIP: timestamp missing'
END;

SELECT CASE 
    WHEN (SELECT COUNT(*) FROM pragma_table_info('error_log') WHERE name='resolved') > 0
    THEN (CREATE INDEX idx_error_log_unresolved ON error_log(resolved))
    ELSE 'SKIP: resolved missing'
END;

SELECT CASE 
    WHEN (SELECT COUNT(*) FROM pragma_table_info('service_manifest') WHERE name='collected_at') > 0
    THEN (CREATE INDEX idx_service_manifest_time ON service_manifest(collected_at))
    ELSE 'SKIP: collected_at missing'
END;

-- Turn foreign keys back on
PRAGMA foreign_keys=ON;

-- Final verification
SELECT '=== TABLE VERIFICATION ===' as info;
SELECT name, 
       (SELECT COUNT(*) FROM pragma_table_info(name)) as column_count,
       (SELECT COUNT(*) FROM name) as row_count
FROM sqlite_master 
WHERE type='table' 
  AND name IN ('boot_health', 'resource_samples', 'service_manifest', 'error_log', 'shutdown_capture')
ORDER BY name;
EOF

echo ""
echo -e "${GREEN}✓ Database repair completed${NC}"
echo ""

# Verify the repair
echo -e "${BLUE}Verification Results:${NC}"
sqlite3 "$DB_PATH" "SELECT 'boot_health: ' || COUNT(*) || ' records' FROM boot_health UNION ALL SELECT 'resource_samples: ' || COUNT(*) || ' records' FROM resource_samples UNION ALL SELECT 'service_manifest: ' || COUNT(*) || ' records' FROM service_manifest UNION ALL SELECT 'error_log: ' || COUNT(*) || ' records' FROM error_log UNION ALL SELECT 'shutdown_capture: ' || COUNT(*) || ' records' FROM shutdown_capture;"

echo ""
echo -e "${GREEN}✓ Database is ready${NC}"
echo "  Backup saved: $BACKUP_PATH"