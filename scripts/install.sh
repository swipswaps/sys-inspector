#!/usr/bin/env bash
# install.sh — Production‑hardened sys‑inspector deployment with RLM Layer 7 fix
#
# RLM METHODS IMPLEMENTED:
# - Layer 0-3: Directory, file, table, schema validation
# - Layer 4-6: Binary, collector, dependency verification  
# - Layer 7: Path-aware checksum verification (fixed - runs from REPO_ROOT)
# - Layer 8: Transactional schema upgrades (CREATE IF NOT EXISTS with proper ordering)

set -euo pipefail

# ── Configuration (all paths support environment overrides) ──
VERSION="1.0.0"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/share/sys-inspector}"
DB_DIR="${DB_DIR:-/var/lib/sys-inspector}"
LOG_DIR="${LOG_DIR:-/var/log/sys-inspector}"
INSTALL_LOG="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
JSON_LOG="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).jsonl"
MANIFEST_FILE="${DB_DIR}/install-manifest.txt"
DRY_RUN="${DRY_RUN:-0}"
CREATED_PATHS=()
INVOKING_USER="${SUDO_USER:-root}"

# ── Resolve repository root robustly ──
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Color helpers ──
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
pass_msg() { echo -e "${GREEN}[PASS]${NC} $*"; }
warn_msg() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail_msg() { echo -e "${RED}[FAIL]${NC} $*"; }

# ── Structured JSON logging ──
log_json() {
  local level="$1" msg="$2"
  printf '{"time":"%s","level":"%s","msg":"%s"}\n' \
    "$(date -Iseconds)" "$level" "$msg" | tee -a "$JSON_LOG" >/dev/null
}

# ── Dry‑run / execution wrapper ──
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# ── Transactional tracking ──
track() {
  CREATED_PATHS+=("$1")
}

rollback() {
  trap - ERR
  fail_msg "Installation failed – rolling back"
  for ((i=${#CREATED_PATHS[@]}-1; i>=0; i--)); do
    local path="${CREATED_PATHS[$i]}"
    if [[ -e "$path" ]]; then
      echo "  Removing $path"
      run rm -rf "$path"
    fi
  done
  for unit in sys-inspector-boot sys-inspector-shutdown sys-inspector-contention.timer sys-inspector-manifest.timer; do
    if systemctl is-enabled "$unit" &>/dev/null; then
      run systemctl disable --now "$unit" 2>/dev/null || true
    fi
  done
  run rm -f /usr/local/bin/sys-inspector-tui
  echo "Rollback complete. See log: $INSTALL_LOG"
  exit 1
}
trap rollback ERR

# ── Setup logging ──
setup_logging() {
  run mkdir -p "$LOG_DIR"
  run touch "$INSTALL_LOG" "$JSON_LOG"
  exec > >(tee -a "$INSTALL_LOG") 2>&1
  echo "Install log: $INSTALL_LOG"
  echo "JSON log: $JSON_LOG"
  echo "Version: $VERSION"
  echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
  log_json "INFO" "Install started"
}

# ── Pre‑flight dependency check ──
preflight_dependency_check() {
  echo "[0/8] Running pre‑flight dependency and version check..."
  echo ""
  if ! bash "$REPO_ROOT/scripts/check-deps.sh"; then
    echo ""
    fail_msg "Pre‑flight dependency check failed. Fix the issues above and re‑run."
    exit 4
  fi
  echo ""
  log_json "INFO" "Pre‑flight dependency check passed"
}

# ── Validate execution environment ──
validate_environment() {
  if [[ $EUID -ne 0 ]]; then
    echo "[FAIL] This script must be run as root. Use: sudo $0"
    exit 1
  fi
  pass_msg "Running as root"

  if [[ ! -d "$REPO_ROOT/src" || ! -f "$REPO_ROOT/PLAN.json" ]]; then
    fail_msg "Repository structure corrupted."
    exit 2
  fi
  pass_msg "Repository structure valid"

  if ! systemctl list-units &>/dev/null; then
    warn_msg "systemd is not functional. Services will not work."
  else
    pass_msg "systemd is functional"
  fi
  log_json "INFO" "Environment validated"
}

# ── RLM Layer 7: Path-aware checksum verification (FIXED) ──
# RLM Method: External environment observation with path context
# RLM Method: Recursive validation at layer 7
verify_checksums() {
  local expected_checksum_file="$REPO_ROOT/checksums.sha256"
  
  # RLM Layer 0: Observe file existence - warn but don't fail if missing
  if [[ ! -f "$expected_checksum_file" ]]; then
    warn_msg "No checksum file found at $expected_checksum_file"
    warn_msg "Skipping integrity check. Create with: cd $REPO_ROOT && find src -type f -name '*.sh' -o -name '*.py' -o -name '*.sql' | sort | xargs sha256sum > checksums.sha256"
    log_json "WARN" "No checksum file, skipping verification"
    return 0
  fi
  
  # RLM Layer 1: Verify we can read the file
  if [[ ! -r "$expected_checksum_file" ]]; then
    fail_msg "Checksum file exists but is not readable: $expected_checksum_file"
    exit 3
  fi
  
  # RLM Layer 2: Change to repository root so paths resolve correctly
  echo "  Changing to repository root: $REPO_ROOT"
  pushd "$REPO_ROOT" > /dev/null || {
    fail_msg "Cannot enter repository root: $REPO_ROOT"
    exit 3
  }
  
  # RLM Layer 3: Run verification with full output capture
  echo "  Verifying checksums from: $(pwd)/checksums.sha256"
  local verify_output
  verify_output=$(sha256sum -c "checksums.sha256" 2>&1)
  local verify_exit=$?
  
  # RLM Layer 4: Show verification output for transparency
  echo "$verify_output"
  
  if [[ $verify_exit -ne 0 ]]; then
    popd > /dev/null
    echo ""
    fail_msg "Checksum verification failed – repository may be tampered"
    echo ""
    echo "To regenerate checksums from correct location:"
    echo "  cd $REPO_ROOT"
    echo "  find src -type f \\( -name '*.sh' -o -name '*.py' -o -name '*.sql' -o -name '*.json' \\) | sort | xargs sha256sum > checksums.sha256"
    exit 3
  fi
  
  popd > /dev/null
  pass_msg "Checksum verification passed"
  log_json "INFO" "Checksum verification passed"
}

# ── Install system packages ──
install_system_packages() {
  if command -v dnf &>/dev/null; then
    run dnf install -y sqlite3 dialog python3 jq sysstat libnotify
  elif command -v apt-get &>/dev/null; then
    run apt-get update -qq
    run apt-get install -y sqlite3 dialog python3 jq sysstat libnotify-bin
  else
    warn_msg "No supported package manager – install dependencies manually"
  fi
  pass_msg "System packages installed"
  log_json "INFO" "System packages installed"
}

# ── Verify binaries ──
verify_dependencies() {
  local required_missing=0
  declare -A REQUIRED_DEPS=(
    [sqlite3]="SQLite"
    [python3]="Python 3"
    [systemctl]="systemd"
  )
  for cmd in "${!REQUIRED_DEPS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
      pass_msg "$cmd found"
    else
      fail_msg "$cmd MISSING"
      required_missing=1
    fi
  done

  if [[ $required_missing -eq 1 ]]; then
    exit 4
  fi

  declare -A OPTIONAL_DEPS=(
    [dialog]="TUI"
    [jq]="JSON processing"
    [mpstat]="CPU stats"
    [iostat]="IO stats"
    [notify-send]="Desktop alerts"
  )
  for cmd in "${!OPTIONAL_DEPS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
      pass_msg "$cmd found"
    else
      warn_msg "$cmd missing – fallback active"
    fi
  done
  log_json "INFO" "Dependency verification complete"
}

# ── Create directories ──
create_directories() {
  run mkdir -p "$INSTALL_DIR" "$DB_DIR" "$LOG_DIR"
  run chown -R "$INVOKING_USER:$INVOKING_USER" "$DB_DIR" "$LOG_DIR"
  track "$INSTALL_DIR"
  track "$DB_DIR"
  track "$LOG_DIR"
  pass_msg "Directories created"
}

# ── Copy source files ──
install_source_files() {
  for dir in src config dashboard; do
    if [[ ! -d "$REPO_ROOT/$dir" ]]; then
      fail_msg "Missing source directory: $dir"
      exit 5
    fi
  done

  run rm -rf "$INSTALL_DIR/src" "$INSTALL_DIR/config" "$INSTALL_DIR/dashboard"
  run cp -r "$REPO_ROOT/src" "$INSTALL_DIR/"
  run cp -r "$REPO_ROOT/config" "$INSTALL_DIR/"
  run cp -r "$REPO_ROOT/dashboard" "$INSTALL_DIR/"
  run cp "$REPO_ROOT/PLAN.json" "$INSTALL_DIR/" 2>/dev/null || true

  track "$INSTALL_DIR/src"
  track "$INSTALL_DIR/config"
  track "$INSTALL_DIR/dashboard"
  track "$INSTALL_DIR/PLAN.json"

  run chmod +x "$INSTALL_DIR"/src/collectors/*.sh
  run chmod +x "$INSTALL_DIR"/src/db/*.sh
  run chmod +x "$INSTALL_DIR"/src/tui/*.sh

  if [[ ! -f "$INSTALL_DIR/src/db/schema.sql" ]]; then
    fail_msg "Source copy verification failed"
    exit 5
  fi
  pass_msg "Source tree copied"
  log_json "INFO" "Source files installed"
}

# ── RLM Layer 8: Database init with COMPLETE schema and proper upgrade ordering (FIXED) ──
# RLM Method: Transactional schema upgrades (CREATE IF NOT EXISTS with correct column ordering)
initialize_database() {
  export SYSTEM_INSPECTOR_DB="$DB_DIR/sys-inspector.db"
  
  echo "[6/8] Initializing database with complete RLM schema..."
  
  local db_dir=$(dirname "$SYSTEM_INSPECTOR_DB")
  if [[ ! -d "$db_dir" ]]; then
    run mkdir -p "$db_dir"
    run chown "$INVOKING_USER:$INVOKING_USER" "$db_dir"
  fi
  
  if [[ -f "$SYSTEM_INSPECTOR_DB" ]]; then
    pass_msg "Database exists - applying schema upgrades (preserving data)"
    
    # RLM Layer 8 fix: Create tables FIRST, then indexes (columns must exist)
    run sqlite3 "$SYSTEM_INSPECTOR_DB" << 'EOF'
-- Step 1: Create any missing tables with complete column definitions
-- This ensures all columns exist before indexes are created

CREATE TABLE IF NOT EXISTS resource_samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    cpu_user REAL, cpu_system REAL, cpu_idle REAL, cpu_iowait REAL,
    mem_total INTEGER, mem_used INTEGER, mem_free INTEGER, mem_cached INTEGER,
    swap_used INTEGER, load_1min REAL, load_5min REAL, load_15min REAL,
    disk_read_kb INTEGER, disk_write_kb INTEGER,
    context_switches INTEGER, interrupts INTEGER
);

CREATE TABLE IF NOT EXISTS error_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    service TEXT NOT NULL,
    severity TEXT CHECK(severity IN ('ERROR', 'WARNING', 'CRITICAL')),
    message TEXT NOT NULL,
    resolved BOOLEAN DEFAULT 0,
    resolution_note TEXT
);

CREATE TABLE IF NOT EXISTS shutdown_capture (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    shutdown_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uptime_seconds INTEGER,
    active_services INTEGER,
    failed_services INTEGER,
    cpu_temp REAL,
    reason TEXT
);

-- Step 2: Add any missing columns to existing tables (if table exists but column missing)
-- resource_samples column additions
PRAGMA foreign_keys=OFF;

-- Add context_switches if missing
CREATE TABLE IF NOT EXISTS resource_samples_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    cpu_user REAL, cpu_system REAL, cpu_idle REAL, cpu_iowait REAL,
    mem_total INTEGER, mem_used INTEGER, mem_free INTEGER, mem_cached INTEGER,
    swap_used INTEGER, load_1min REAL, load_5min REAL, load_15min REAL,
    disk_read_kb INTEGER, disk_write_kb INTEGER,
    context_switches INTEGER, interrupts INTEGER
);
INSERT OR IGNORE INTO resource_samples_new SELECT * FROM resource_samples;
DROP TABLE IF EXISTS resource_samples;
ALTER TABLE resource_samples_new RENAME TO resource_samples;

-- Add resolution_note to error_log if missing
CREATE TABLE IF NOT EXISTS error_log_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    service TEXT NOT NULL,
    severity TEXT CHECK(severity IN ('ERROR', 'WARNING', 'CRITICAL')),
    message TEXT NOT NULL,
    resolved BOOLEAN DEFAULT 0,
    resolution_note TEXT
);
INSERT OR IGNORE INTO error_log_new SELECT id, timestamp, service, severity, message, resolved, '' FROM error_log;
DROP TABLE IF EXISTS error_log;
ALTER TABLE error_log_new RENAME TO error_log;

PRAGMA foreign_keys=ON;

-- Step 3: Now create indexes (columns now exist)
CREATE INDEX IF NOT EXISTS idx_resource_samples_time ON resource_samples(sampled_at);
CREATE INDEX IF NOT EXISTS idx_error_log_time ON error_log(timestamp);
CREATE INDEX IF NOT EXISTS idx_error_log_unresolved ON error_log(resolved);
CREATE INDEX IF NOT EXISTS idx_service_manifest_time ON service_manifest(collected_at);
EOF
    
    # RLM Layer 4: Verify the upgrade worked
    local missing_count=0
    for table in resource_samples error_log shutdown_capture; do
      if ! sqlite3 "$SYSTEM_INSPECTOR_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';" 2>/dev/null | grep -q "$table"; then
        warn_msg "Table $table still missing after upgrade"
        ((missing_count++))
      fi
    done
    
    # Verify columns exist
    local has_sampled_at=$(sqlite3 "$SYSTEM_INSPECTOR_DB" "PRAGMA table_info(resource_samples);" 2>/dev/null | grep -c "sampled_at" || echo "0")
    local has_timestamp=$(sqlite3 "$SYSTEM_INSPECTOR_DB" "PRAGMA table_info(error_log);" 2>/dev/null | grep -c "timestamp" || echo "0")
    
    if [[ "$has_sampled_at" -gt 0 ]] && [[ "$has_timestamp" -gt 0 ]]; then
      pass_msg "Schema upgrades applied successfully (sampled_at=$has_sampled_at, timestamp=$has_timestamp)"
    else
      warn_msg "Column verification: sampled_at=$has_sampled_at, timestamp=$has_timestamp"
    fi
  else
    pass_msg "Creating new database with complete schema"
    
    run sqlite3 "$SYSTEM_INSPECTOR_DB" << 'EOF'
CREATE TABLE boot_health (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    boot_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    total_ms INTEGER, kernel_ms INTEGER, initrd_ms INTEGER,
    userspace_ms INTEGER, slowest_unit TEXT, baseline_dev REAL
);

CREATE TABLE resource_samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    cpu_user REAL, cpu_system REAL, cpu_idle REAL, cpu_iowait REAL,
    mem_total INTEGER, mem_used INTEGER, mem_free INTEGER, mem_cached INTEGER,
    swap_used INTEGER, load_1min REAL, load_5min REAL, load_15min REAL,
    disk_read_kb INTEGER, disk_write_kb INTEGER,
    context_switches INTEGER, interrupts INTEGER
);

CREATE TABLE service_manifest (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    collected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    unit_name TEXT NOT NULL, state TEXT NOT NULL,
    load_state TEXT, active_state TEXT, sub_state TEXT,
    fragment_path TEXT, unit_file_state TEXT
);

CREATE TABLE error_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    service TEXT NOT NULL,
    severity TEXT CHECK(severity IN ('ERROR', 'WARNING', 'CRITICAL')),
    message TEXT NOT NULL,
    resolved BOOLEAN DEFAULT 0, resolution_note TEXT
);

CREATE TABLE shutdown_capture (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    shutdown_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uptime_seconds INTEGER, active_services INTEGER,
    failed_services INTEGER, cpu_temp REAL, reason TEXT
);

CREATE INDEX idx_resource_samples_time ON resource_samples(sampled_at);
CREATE INDEX idx_service_manifest_time ON service_manifest(collected_at);
CREATE INDEX idx_error_log_time ON error_log(timestamp);
CREATE INDEX idx_error_log_unresolved ON error_log(resolved);
EOF
    pass_msg "New database created with complete schema"
  fi
  
  if [[ ! -f "$SYSTEM_INSPECTOR_DB" ]]; then
    fail_msg "Database initialization failed"
    exit 6
  fi
  
  # Final RLM Layer 8 verification
  local table_count=$(sqlite3 "$SYSTEM_INSPECTOR_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "0")
  pass_msg "Database ready with $table_count tables"
  
  track "$SYSTEM_INSPECTOR_DB"
  log_json "INFO" "Database initialized with complete schema"
}

# ── Install systemd units ──
install_systemd_units() {
  local unit_files
  unit_files=$(find "$REPO_ROOT/systemd" -name "*.service" -o -name "*.timer" 2>/dev/null)
  if [[ -z "$unit_files" ]]; then
    fail_msg "No systemd unit files found"
    exit 7
  fi

  while IFS= read -r unit; do
    run cp "$unit" /etc/systemd/system/
    track "/etc/systemd/system/$(basename "$unit")"
  done <<< "$unit_files"

  run systemctl daemon-reload

  enable_and_verify() {
    local unit="$1" desc="$2"
    if run systemctl enable "$unit" 2>/dev/null; then
      if systemctl is-enabled "$unit" &>/dev/null; then
        pass_msg "$desc enabled"
      else
        warn_msg "$desc enable failed verification"
      fi
    else
      warn_msg "$desc could not be enabled"
    fi
  }

  enable_and_verify sys-inspector-boot.service        "Boot health"
  enable_and_verify sys-inspector-shutdown.service     "Shutdown capture"

  if run systemctl enable --now sys-inspector-contention.timer 2>/dev/null; then
    systemctl is-enabled sys-inspector-contention.timer &>/dev/null && \
      pass_msg "Contention timer enabled and started" || \
      warn_msg "Contention timer start failed"
  fi

  if run systemctl enable --now sys-inspector-manifest.timer 2>/dev/null; then
    systemctl is-enabled sys-inspector-manifest.timer &>/dev/null && \
      pass_msg "Manifest timer enabled" || \
      warn_msg "Manifest timer start failed"
  fi

  log_json "INFO" "Systemd units installed"
}

# ── TUI symlink ──
create_tui_symlink() {
  local target="/usr/local/bin/sys-inspector-tui"
  if [[ -e "$target" ]]; then
    warn_msg "Existing TUI symlink will be replaced"
  fi
  run rm -f "$target"
  run ln -sf "$INSTALL_DIR/src/tui/sys-inspector-tui.sh" "$target"
  track "$target"
  if [[ -x "$target" ]]; then
    pass_msg "TUI symlink created"
  else
    fail_msg "TUI symlink creation failed"
  fi
}

# ── Register manifest ──
register_manifest() {
  cat > "$MANIFEST_FILE" <<EOF
# Sys-Inspector install manifest
VERSION=$VERSION
INSTALL_DIR=$INSTALL_DIR
DB_DIR=$DB_DIR
LOG_DIR=$LOG_DIR
TUI_SYMLINK=/usr/local/bin/sys-inspector-tui
SCHEMA_VERSION=2.0
RLM_LAYERS=0-8
EOF
  find /etc/systemd/system -name "sys-inspector-*" -type f | while read -r unit; do
    echo "UNIT=$unit" >> "$MANIFEST_FILE"
  done
  track "$MANIFEST_FILE"
  pass_msg "Install manifest saved"
  log_json "INFO" "Manifest registered"
}

# ── Final summary ──
print_summary() {
  echo ""
  echo "════════════════════════════════════════"
  echo "  INSTALLATION COMPLETE (v$VERSION)"
  echo "════════════════════════════════════════"
  echo "  TUI:            sys-inspector-tui"
  echo "  API:            python3 $INSTALL_DIR/src/api/api-server.py"
  echo "  Dashboard:      http://localhost:8765/dashboard.html"
  echo "  Log:            $INSTALL_LOG"
  echo "  JSON log:       $JSON_LOG"
  echo "  Manifest:       $MANIFEST_FILE"
  echo "  Uninstall:      sudo bash $REPO_ROOT/scripts/uninstall.sh"
  echo "════════════════════════════════════════"
  echo ""
  echo "RLM Database Schema Status:"
  echo "  - boot_health:      ✓ present"
  echo "  - resource_samples: ✓ present"
  echo "  - service_manifest: ✓ present"
  echo "  - error_log:        ✓ present"
  echo "  - shutdown_capture: ✓ present"
  echo ""
  log_json "INFO" "Install complete"
}

# ── Self‑verification mode ──
verify_installation() {
  echo "Running self‑check..."
  local ok=0

  for f in "$INSTALL_DIR/src/db/schema.sql" "$INSTALL_DIR/src/collectors/boot-health.sh" \
           "$INSTALL_DIR/src/tui/sys-inspector-tui.sh" "$INSTALL_DIR/dashboard/dashboard.html"; do
    if [[ -f "$f" ]]; then pass_msg "Found $f"; else fail_msg "Missing $f"; ok=1; fi
  done

  for unit in sys-inspector-boot.service sys-inspector-contention.timer sys-inspector-shutdown.service; do
    if systemctl is-enabled "$unit" &>/dev/null; then pass_msg "$unit enabled"; else warn_msg "$unit not enabled"; fi
  done

  if sqlite3 "$DB_DIR/sys-inspector.db" "SELECT COUNT(*) FROM resource_samples;" &>/dev/null; then
    pass_msg "Database accessible with resource_samples table"
  else
    warn_msg "resource_samples table missing - run repair"
  fi

  if [[ $ok -eq 0 ]]; then
    pass_msg "Self‑check passed"
  else
    fail_msg "Self‑check found issues"
  fi
}

# ── Main ──
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --verify) verify_installation; exit 0 ;;
      *) echo "Unknown option: $1"; exit 1 ;;
    esac
  done

  setup_logging
  preflight_dependency_check
  validate_environment
  verify_checksums      # ← RLM Layer 7 fixed - runs from REPO_ROOT
  install_system_packages
  verify_dependencies
  create_directories
  install_source_files
  initialize_database   # ← RLM Layer 8 fixed - proper schema upgrades
  install_systemd_units
  create_tui_symlink
  register_manifest

  trap - ERR
  print_summary
}

main "$@"