-- Complete schema for sys-inspector
-- RLM §3.3: Every layer must be verifiable

-- Layer 0: Boot health tracking
CREATE TABLE IF NOT EXISTS boot_health (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    boot_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    total_ms INTEGER,
    kernel_ms INTEGER,
    initrd_ms INTEGER,
    userspace_ms INTEGER,
    slowest_unit TEXT,
    baseline_dev REAL
);

-- Layer 1: Resource samples (FIXES missing table)
CREATE TABLE IF NOT EXISTS resource_samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    cpu_user REAL,
    cpu_system REAL,
    cpu_idle REAL,
    cpu_iowait REAL,
    mem_total INTEGER,
    mem_used INTEGER,
    mem_free INTEGER,
    mem_cached INTEGER,
    swap_used INTEGER,
    load_1min REAL,
    load_5min REAL,
    load_15min REAL,
    disk_read_kb INTEGER,
    disk_write_kb INTEGER,
    context_switches INTEGER,
    interrupts INTEGER
);

-- Layer 2: Service manifest (unit state tracking)
CREATE TABLE IF NOT EXISTS service_manifest (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    collected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    unit_name TEXT NOT NULL,
    state TEXT NOT NULL,
    load_state TEXT,
    active_state TEXT,
    sub_state TEXT,
    fragment_path TEXT,
    unit_file_state TEXT
);

-- Layer 3: Error log (FIXES missing table)
CREATE TABLE IF NOT EXISTS error_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    service TEXT NOT NULL,
    severity TEXT CHECK(severity IN ('ERROR', 'WARNING', 'CRITICAL')),
    message TEXT NOT NULL,
    resolved BOOLEAN DEFAULT 0,
    resolution_note TEXT
);

-- Layer 4: Shutdown capture (system state at shutdown)
CREATE TABLE IF NOT EXISTS shutdown_capture (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    shutdown_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uptime_seconds INTEGER,
    active_services INTEGER,
    failed_services INTEGER,
    cpu_temp REAL,
    reason TEXT
);

-- Layer 5: Contention events
CREATE TABLE IF NOT EXISTS contention_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    detected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resource_type TEXT,
    resource_name TEXT,
    waiting_pid INTEGER,
    waiting_process TEXT,
    held_by_pid INTEGER,
    held_by_process TEXT,
    duration_ms INTEGER
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_resource_samples_time ON resource_samples(sampled_at);
CREATE INDEX IF NOT EXISTS idx_service_manifest_time ON service_manifest(collected_at);
CREATE INDEX IF NOT EXISTS idx_error_log_time ON error_log(timestamp);
CREATE INDEX IF NOT EXISTS idx_error_log_unresolved ON error_log(resolved);

-- RLM §3.1 verification query
SELECT 'Schema version: v2.0' as status,
       COUNT(*) as table_count
FROM sqlite_master 
WHERE type='table';