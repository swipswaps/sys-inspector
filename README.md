# Sys-Inspector — Self-Healing Linux Transparency Suite

Sys-Inspector monitors your Linux desktop: it tracks every boot, alerts on resource exhaustion, captures shutdown forensics, and provides both a TUI and a web dashboard — all backed by a lightweight SQLite database.

## Quick Start

```bash
git clone https://github.com/swipsaps/sys-inspector.git
cd sys-inspector
sudo bash scripts/install.sh
```

After installation:

- Boot metrics are automatically captured every boot.
- Resource alerts run every 5 minutes.
- Shutdown snapshots are taken just before the system halts.
- The TUI is available via `sys-inspector-tui`.
- The API server can be started with `python3 /usr/local/share/sys-inspector/src/api/api-server.py`.
- Open `http://localhost:8765/dashboard.html` in a browser to see the web dashboard.

## Dependencies

| Package | Required? | Used By | Notes |
|---------|-----------|---------|-------|
| `sqlite3` | Required | All collectors, TUI, API | Database engine |
| `python3` | Required | API server | Flask or built-in http.server |
| `systemd` | Required | Boot/shutdown hooks, timer | Already on Fedora |
| `dialog` | Optional | TUI dashboard | Falls back to plain text mode |
| `jq` | Optional | Boot health, shutdown | Falls back to empty JSON arrays |
| `sysstat` | Optional | Contention alerter | Provides `mpstat` and `iostat`; falls back to `/proc` parsing |
| `libnotify` | Optional | Contention alerter | Desktop notifications; falls back to journal only |
| `Flask` | Optional | API server | `pip3 install -r src/api/requirements.txt`; falls back to Python http.server |

Install all optional dependencies for full functionality:
```bash
sudo dnf install dialog jq sysstat libnotify
pip3 install -r src/api/requirements.txt
```

## Component Overview and How They Work

### 1. Boot Health Reporter (`src/collectors/boot-health.sh`)

Trigger: systemd service at `multi-user.target` (after login screen appears)
What it does:

- Runs `systemd-analyze` to measure kernel, initrd, and userspace boot times.
- Finds the slowest unit.
- Captures all journal warnings from the current boot.
- Compares total boot time against a baseline using Welford's online algorithm (one-pass mean and variance). If the current boot deviates by more than 2σ, it logs an anomaly.
- Inserts a new row into the `boot_health` table.
- Cleans up old records (default 90 days) to keep the database small.
- Self-healing: If the database is missing, it initialises it automatically.

### 2. Resource Contention Alerter (`src/collectors/contention-alert.sh`)

Trigger: systemd timer every 5 minutes
How it works:

- CPU usage: prefers `mpstat`, falls back to `/proc/loadavg` and `nproc`.
- Memory usage: from `free -m`.
- I/O wait: from `iostat`, falls back to 0 if unavailable.
- Zombie processes: counted via `ps`.
- Compares each metric against thresholds defined in `config/sys-inspector.conf`.
- If any threshold is breached, it logs a warning to the system journal and (if available) sends a desktop notification.
- Always writes a sample to the `resource_samples` table, including an `alert_triggered` flag.

### 3. Shutdown Capture (`src/collectors/shutdown-capture.sh`)

Trigger: systemd service that runs just before `shutdown.target`
How it works:

- Snapshot of the 20 most memory-hungry processes.
- List of mounted filesystems (excluding pseudo-filesystems).
- Number of open files.
- Checks for failed systemd units to flag an unclean shutdown.
- Saves everything into the `shutdown_capture` table. If the DB isn't available, it logs a summary to the journal.

### 4. Service Manifest Generator (`src/collectors/service-manifest.sh`)

Trigger: manual (or weekly via timer)
How it works:

- Lists every systemd unit file and its state (enabled/disabled/masked).
- Maps most units to a human-readable rationale using an internal dictionary.
- Regenerates the entire `service_manifest` table each time it runs, so it's always a current snapshot.

### 5. TUI Dashboard (`src/tui/sys-inspector-tui.sh`)

How to use: Run `sys-inspector-tui` in a terminal.
Handling:

- Auto-detects whether `dialog`, `whiptail`, or plain text mode is available.
- Provides a menu to view current resource usage, recent boot history, service audit summary, active errors, and database statistics.
- All data comes directly from the SQLite database.

### 6. API Server (`src/api/api-server.py`)

How to run: `python3 src/api/api-server.py`
Default port: 8765
Provides:

- `/api/boot` – last 20 boot records
- `/api/resources` – last hour of resource samples
- `/api/services` – current service manifest
- `/api/errors` – active unresolved errors
- `/api/health` – server and DB status
- Serves `dashboard.html` from the `dashboard/` folder.

### 7. Web Dashboard (`dashboard/dashboard.html`)

How to access: Open `http://localhost:8765/dashboard.html` after starting the API server.
Features:

- Boot Timeline: Horizontal bar chart showing total boot time over the last 10 boots.
- Resource Gauges: CPU, memory, and I/O wait gauges updated every 30 seconds.
- Service Audit: Table of masked/enabled services with rationales.
- Error Log: Sorted list of unresolved warnings.
- All visualisations are built with d3.js v7, loaded from CDN — no build step required.

## Configuration

All thresholds and paths are in `config/sys-inspector.conf`. Copy it to `/etc/sys-inspector/sys-inspector.conf` to override the defaults.

## Troubleshooting

- Database not found: Run `sudo bash src/db/db-init.sh` to create it.
- Missing dialog: Install with `sudo dnf install dialog`.
- API server won't start: Install Flask (`pip3 install flask`) or use the built-in fallback.
- Dashboard blank: Make sure the API server is running and you are accessing the correct port.

## Uninstall

```bash
sudo bash scripts/uninstall.sh
```

This removes systemd units and symlinks, but preserves the database (prompts for confirmation).

## License

MIT
