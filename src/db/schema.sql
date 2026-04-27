-- schema.sql — Idempotent SQLite schema for sys-inspector
-- Run multiple times safely: CREATE TABLE IF NOT EXISTS
-- Citation: SQLite Documentation §CREATE TABLE [Tier 2: sqlite.org]

PRAGMA journal_mode=WAL;         -- better concurrent read/write
PRAGMA foreign_keys=ON;

-- Boot health: one row per boot
CREATE TABLE IF NOT EXISTS boot_health (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    boot_ts     TEXT    NOT NULL DEFAULT (datetime('now')),
    kernel_ver  TEXT,
    kernel_ms   INTEGER,
    initrd_ms   INTEGER,
    userspace_ms INTEGER,
    total_ms    INTEGER,
    slowest_unit TEXT,
    slowest_ms  INTEGER,
    critical_chain TEXT,
    warnings    TEXT,
    baseline_dev REAL
);

-- Resource samples: periodic snapshots
CREATE TABLE IF NOT EXISTS resource_samples (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    sample_ts   TEXT    NOT NULL DEFAULT (datetime('now')),
    cpu_pct     REAL,
    mem_used_mb REAL,
    mem_total_mb REAL,
    iowait_pct  REAL,
    load_1m     REAL,
    load_5m     REAL,
    load_15m    REAL,
    zombie_ct   INTEGER,
    alert_triggered INTEGER DEFAULT 0
);

-- Shutdown capture: one row per shutdown
CREATE TABLE IF NOT EXISTS shutdown_capture (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    shutdown_ts TEXT    NOT NULL DEFAULT (datetime('now')),
    running_procs TEXT,
    mount_states TEXT,
    open_files_ct INTEGER,
    unclean     INTEGER DEFAULT 0
);

-- Service manifest: point-in-time snapshot
CREATE TABLE IF NOT EXISTS service_manifest (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    manifest_ts TEXT    NOT NULL DEFAULT (datetime('now')),
    unit_name   TEXT    NOT NULL,
    state       TEXT    NOT NULL,
    preset      TEXT,
    rationale   TEXT
);

-- Error log: deduplicated journal warnings
CREATE TABLE IF NOT EXISTS error_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    first_seen  TEXT    NOT NULL DEFAULT (datetime('now')),
    last_seen   TEXT    NOT NULL DEFAULT (datetime('now')),
    count       INTEGER DEFAULT 1,
    source      TEXT,
    message     TEXT    NOT NULL,
    severity    TEXT    DEFAULT 'warning',
    resolved    INTEGER DEFAULT 0
);

-- Baseline: rolling statistics for anomaly detection
CREATE TABLE IF NOT EXISTS baseline (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    metric_key  TEXT    NOT NULL UNIQUE,
    n           INTEGER DEFAULT 0,
    mean        REAL    DEFAULT 0.0,
    m2          REAL    DEFAULT 0.0,
    updated_ts  TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_boot_ts ON boot_health(boot_ts);
CREATE INDEX IF NOT EXISTS idx_sample_ts ON resource_samples(sample_ts);
CREATE INDEX IF NOT EXISTS idx_error_source ON error_log(source);
CREATE INDEX IF NOT EXISTS idx_manifest_unit ON service_manifest(unit_name);
