#!/bin/bash
set -e

echo "============================================================"
echo "Sys‑Inspector Installation Script"
echo "============================================================"

# 1. Install system dependencies
echo "--- Installing dependencies ---"
sudo dnf install -y python3-flask sysstat jq nodejs npm chromium

# 2. Install Puppeteer globally (for headless verification)
echo "--- Installing Puppeteer ---"
sudo npm install -g puppeteer

# 3. Create directories
echo "--- Creating directories ---"
sudo mkdir -p /usr/local/share/sys-inspector/{dashboard,src/api,src/collectors}
sudo mkdir -p /var/lib/sys-inspector
sudo mkdir -p /var/log/sys-inspector

# 4. Copy files from repository to system locations
echo "--- Copying files ---"
sudo cp dashboard/dashboard.html /usr/local/share/sys-inspector/dashboard/
sudo cp src/api/api-server.py /usr/local/share/sys-inspector/src/api/
sudo cp scripts/verify.sh /usr/local/share/sys-inspector/scripts/ 2>/dev/null || true

# 5. Set up systemd service
echo "--- Setting up systemd service ---"
sudo cp sys-inspector-api.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable sys-inspector-api.service
sudo systemctl restart sys-inspector-api.service

# 6. Open firewall (if firewalld is active)
if systemctl is-active --quiet firewalld; then
    echo "--- Configuring firewall ---"
    sudo firewall-cmd --add-port=8765/tcp --permanent
    sudo firewall-cmd --reload
fi

# 7. Create initial database and populate collectors
echo "--- Initializing database ---"
DB="/var/lib/sys-inspector/sys-inspector.db"
sudo sqlite3 "$DB" << 'SQL'
CREATE TABLE IF NOT EXISTS listening_ports (id INTEGER PRIMARY KEY, protocol TEXT, port INTEGER);
CREATE TABLE IF NOT EXISTS network_connections (id INTEGER PRIMARY KEY, local_addr TEXT, remote_addr TEXT, state TEXT);
CREATE TABLE IF NOT EXISTS processes (id INTEGER PRIMARY KEY, pid INTEGER, name TEXT, cpu_percent REAL, mem_percent REAL, command TEXT, state TEXT);
CREATE TABLE IF NOT EXISTS resources (id INTEGER PRIMARY KEY, cpu_pct REAL, mem_used_mb REAL, iowait_pct REAL, recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS services (id INTEGER PRIMARY KEY, unit_name TEXT UNIQUE, state TEXT, rationale TEXT);
CREATE TABLE IF NOT EXISTS errors (id INTEGER PRIMARY KEY, source TEXT, message TEXT, count INTEGER);
CREATE TABLE IF NOT EXISTS boot_history (id INTEGER PRIMARY KEY, boot_id TEXT UNIQUE, boot_start_epoch INTEGER, boot_end_epoch INTEGER, total_seconds INTEGER);
CREATE TABLE IF NOT EXISTS slow_services (id INTEGER PRIMARY KEY, boot_id TEXT, service_name TEXT, duration_seconds REAL);
SQL

echo "--- Running initial data collectors ---"
sudo ss -tuln | tail -n +2 | while read line; do
    proto=$(echo "$line" | awk '{print $1}')
    addr=$(echo "$line" | awk '{print $5}')
    port=$(echo "$addr" | awk -F':' '{print $NF}' | grep -oE '[0-9]+')
    [ -n "$port" ] && sudo sqlite3 "$DB" "INSERT OR IGNORE INTO listening_ports (protocol, port) VALUES ('$proto', $port);"
done

sudo systemctl restart sys-inspector-api.service

echo "============================================================"
echo "✅ Installation complete!"
echo "Dashboard URL: http://$(hostname -I | awk '{print $1}'):8765"
echo "Logs: /var/log/sys-inspector/"
echo "============================================================"
