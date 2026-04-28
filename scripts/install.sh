#!/bin/bash
# Sys-Inspector Installation Script
# Complete installation with all components

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🔍 Sys-Inspector Installation${NC}"
echo "================================"

# Check if running as root (not required but helpful for some features)
if [ "$EUID" -eq 0 ]; then 
    echo -e "${YELLOW}⚠️  Running as root. Some features will work better but this isn't required.${NC}"
fi

# Create directories
INSTALL_DIR="${HOME}/.sys-inspector"
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/data"
mkdir -p "$INSTALL_DIR/logs"

echo "📁 Installation directory: $INSTALL_DIR"

# Create database schema
DB_PATH="${INSTALL_DIR}/sys-inspector.db"
echo "📊 Creating database at $DB_PATH"

sqlite3 "$DB_PATH" << 'EOF'
-- Boot times table
CREATE TABLE IF NOT EXISTS boot_times (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    boot_id TEXT UNIQUE,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    kernel_ms REAL,
    initrd_ms REAL,
    userspace_ms REAL,
    total_ms REAL
);

-- Services table
CREATE TABLE IF NOT EXISTS services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    state TEXT,
    load_time_ms REAL,
    active_state TEXT,
    sub_state TEXT,
    description TEXT
);

-- Error log table
CREATE TABLE IF NOT EXISTS error_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    source TEXT,
    service TEXT,
    message TEXT,
    severity TEXT,
    count INTEGER DEFAULT 1
);

-- Resource samples table
CREATE TABLE IF NOT EXISTS resource_samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    cpu_percent REAL,
    memory_percent REAL,
    disk_used_percent REAL,
    load_avg_1min REAL,
    load_avg_5min REAL,
    load_avg_15min REAL
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_error_log_timestamp ON error_log(timestamp);
CREATE INDEX IF NOT EXISTS idx_error_log_source ON error_log(source);
CREATE INDEX IF NOT EXISTS idx_services_timestamp ON services(timestamp);
CREATE INDEX IF NOT EXISTS idx_boot_times_timestamp ON boot_times(timestamp);

-- Check if tables were created
SELECT name FROM sqlite_master WHERE type='table';
EOF

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Database initialized successfully${NC}"
else
    echo -e "${RED}❌ Database initialization failed${NC}"
    exit 1
fi

# Copy dashboard files
DASHBOARD_DIR="$INSTALL_DIR/dashboard"
mkdir -p "$DASHBOARD_DIR"
cp dashboard/dashboard.html "$DASHBOARD_DIR/" 2>/dev/null || echo "⚠️  dashboard.html not found, will be created"

# Create launcher scripts
cat > "$INSTALL_DIR/start-api.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
export PYTHONPATH="$PWD/src"
python3 src/api/server.py
EOF

chmod +x "$INSTALL_DIR/start-api.sh"

cat > "$INSTALL_DIR/start-collector.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
while true; do
    bash src/tui/sys-inspector-tui.sh --collect-only
    sleep 300  # Collect every 5 minutes
done
EOF

chmod +x "$INSTALL_DIR/start-collector.sh"

# Create systemd user service (optional)
if [ "$EUID" -ne 0 ] && systemctl --user --version >/dev/null 2>&1; then
    echo "🛠️  Creating systemd user service..."
    mkdir -p ~/.config/systemd/user
    
    cat > ~/.config/systemd/user/sys-inspector-api.service << EOF
[Unit]
Description=Sys-Inspector API Server
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/start-api.sh
Restart=on-failure
RestartSec=10
WorkingDirectory=$INSTALL_DIR

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    echo -e "${GREEN}✅ Systemd user service created${NC}"
    echo "   Start with: systemctl --user start sys-inspector-api"
    echo "   Enable with: systemctl --user enable sys-inspector-api"
fi

# Test the API
echo ""
echo "🧪 Testing installation..."

# Start API in background
python3 -c "
import subprocess
import time
import sys
import os

# Start the API server
proc = subprocess.Popen([sys.executable, 'src/api/server.py'], 
                        stdout=subprocess.PIPE, 
                        stderr=subprocess.PIPE,
                        cwd='$INSTALL_DIR')
time.sleep(3)

# Test health endpoint
import urllib.request
try:
    resp = urllib.request.urlopen('http://localhost:8765/api/health', timeout=5)
    if resp.status == 200:
        print('✅ API server is running')
    else:
        print('❌ API server returned status', resp.status)
except Exception as e:
    print(f'❌ Could not connect to API: {e}')

proc.terminate()
" 2>/dev/null || echo "⚠️  API test skipped (run manually after install)"

echo ""
echo -e "${GREEN}✅ Installation complete!${NC}"
echo ""
echo "Next steps:"
echo "1. Start the API server:   cd $INSTALL_DIR && ./start-api.sh"
echo "2. Open dashboard:         http://localhost:8765"
echo "3. Run collector:          cd $INSTALL_DIR && ./start-collector.sh"
echo ""
echo "Or use systemd (if available):"
echo "  systemctl --user start sys-inspector-api"
echo "  systemctl --user enable sys-inspector-api"