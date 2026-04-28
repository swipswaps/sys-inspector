README.md << 'README_EOF'
# Sys‑Inspector – System Health & Boot Analysis Dashboard

Sys‑Inspector collects real‑time system data (listening ports, active network connections, top processes, systemd service states, resource usage, boot timeline, and journal errors) and presents it in a clean, self‑refreshing web dashboard. It is designed for **full transparency, deterministic debugging, and zero evasion** – every command is logged, every error is shown, and the dashboard verifies itself with a headless browser.

---

## 🚀 Quick Start (Clone & Run)

```bash
git clone https://github.com/your-username/sys-inspector.git
cd sys-inspector
sudo bash install.sh

After installation, open your browser to http://<server-ip>:8765.
📋 Features

    Listening Ports – UDP/TCP ports from ss -tuln

    Network Connections – ESTABLISHED connections (local/remote)

    Top Processes – sorted by CPU usage (ps aux --sort=-%cpu)

    Service States – systemd units with state and description

    Resource Gauges – CPU %, memory used (MB), I/O wait %

    Boot Timeline – Current uptime as a color‑coded bar (green = fast, yellow = moderate, red = >30s)

    Slowest Boot Services – from systemd-analyze blame

    Active Errors – aggregated from journalctl -p 3

All data is stored in a SQLite database (/var/lib/sys-inspector/sys-inspector.db) and served via a Flask API.
🛠️ Installation (Manual)

If you prefer not to use the install script:
bash

# Install dependencies
sudo dnf install -y python3-flask sysstat jq nodejs npm chromium

# Install Puppeteer globally (for headless verification)
sudo npm install -g puppeteer

# Clone the repository
git clone https://github.com/your-username/sys-inspector.git
cd sys-inspector

# Copy files to system locations
sudo mkdir -p /usr/local/share/sys-inspector/{dashboard,src/api}
sudo cp dashboard/dashboard.html /usr/local/share/sys-inspector/dashboard/
sudo cp src/api/api-server.py /usr/local/share/sys-inspector/src/api/

# Set up systemd service (optional)
sudo cp sys-inspector-api.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sys-inspector-api.service

# Open firewall (if needed)
sudo firewall-cmd --add-port=8765/tcp --permanent
sudo firewall-cmd --reload

🔍 Troubleshooting
Dashboard shows “Loading…” forever

    Check that the API is running:
    bash

    curl http://localhost:8765/api/ports

    Should return a JSON array of ports. If it returns 404, the API server is not running or the endpoints are missing.

    Restart the API with full logging:
    bash

    sudo systemctl restart sys-inspector-api.service
    journalctl -u sys-inspector-api -n 50 --no-pager

    Ensure the dashboard HTML is correct:
    bash

    grep -q '<script>' /usr/local/share/sys-inspector/dashboard/dashboard.html && echo "OK" || echo "MALFORMED"

    If malformed, re‑copy the dashboard from the repository.

    Verify the database is populated:
    bash

    sqlite3 /var/lib/sys-inspector/sys-inspector.db "SELECT COUNT(*) FROM listening_ports;"

    Return value should be >0. If zero, run the collector manually:
    bash

    sudo /usr/local/share/sys-inspector/src/collectors/collect-all.sh

Address already in use (port 8765)

Kill the old process:
bash

sudo lsof -ti :8765 | xargs kill -9
sudo systemctl restart sys-inspector-api.service

Puppeteer fails with “Cannot find module 'puppeteer'”

Set NODE_PATH:
bash

export NODE_PATH=$(npm root -g)
node /path/to/your/script.js

Headless browser test times out

Use domcontentloaded instead of networkidle2:
javascript

await page.goto(url, { waitUntil: 'domcontentloaded' });

Self‑healing timer overwrites your changes

Disable it permanently:
bash

sudo systemctl stop sys-inspector-selfheal.timer
sudo systemctl disable sys-inspector-selfheal.timer
sudo systemctl mask sys-inspector-selfheal.timer

📊 API Endpoints
Endpoint	Description
/	Dashboard HTML
/api/ports	List of listening ports
/api/connections	ESTABLISHED network connections
/api/processes	Top 50 processes by CPU
/api/services	Systemd service states
/api/resources	Latest CPU, memory, I/O wait
/api/boot/current	Current boot uptime in seconds
/api/boot/slow-services	Slowest boot services (systemd-analyze)
/api/errors	Aggregated error groups from journal
/health	Health check (returns “OK”)
🧪 Running the Self‑Verification

The repository includes a verification script that uses Puppeteer to ensure the dashboard loads and shows real data:
bash

sudo bash -x scripts/verify.sh

It will:

    Kill any existing API process

    Start a fresh API server

    Run curl tests on all endpoints

    Launch a headless Chromium and wait for the connections panel to contain ESTAB

    Exit with 0 on success, 1 on failure

🧬 RLM Compliance

Sys‑Inspector follows RLM (Recursive Language Model) rules v6.12 – every command is logged with set -x, no output is hidden to /dev/null, and all fixes are idempotent. The ruleset is stored in ../.augment-rules-v6.12.json (outside the repo). Key principles:

    Full logging – exec > >(tee -a $LOG_FILE) 2>&1; set -x

    No curl -s -o /dev/null – always save and inspect the response body

    No irrelevant endpoints – only test what the dashboard actually uses

    Headless browser verification – wait for DOM content, not just HTTP 200

    Idempotent operations – ALTER TABLE ADD COLUMN with error ignoring, INSERT OR REPLACE

    Kill old processes – lsof -ti :8765 | xargs kill -9

    Disable self‑healing timers – systemctl mask to prevent auto‑restore

📝 License

MIT – use freely, but keep the logging principle: never hide errors, always show the full output.
🤝 Contributing

Pull requests must include a compliance audit in the description, showing that:

    All commands were run with set -x and logged

    No -o /dev/null or 2>/dev/null was used

    A headless browser test was performed

    The change is idempotent

📬 Support

Open an issue on GitHub. Please include the full log file from /var/log/sys-inspector/ – messy logs are welcome, clean logs are suspicious.
README_EOF
2. Stage and commit the updated README

git add README.md
git commit -m "docs: add comprehensive user guide with troubleshooting and RLM compliance notes"
3. Push to remote (assumes origin/main)

git push origin main