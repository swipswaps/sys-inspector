#!/usr/bin/env python3
"""
api-server.py — Lightweight REST API with static dashboard server.
Uses Flask if available; otherwise falls back to Python's http.server
and serves dashboard.html from the dashboard/ directory.

Endpoints:
  GET /api/boot       — last 20 boot health records
  GET /api/resources  — last hour of resource samples
  GET /api/services   — current service manifest
  GET /api/errors     — active unresolved errors
  GET /api/health     — server and database status
  GET /dashboard.html — static web dashboard (d3.js)

Citation: Flask Documentation — 'Flask is a lightweight WSGI web application
  framework' [Tier 2: palletsprojects.com]
"""
import os, sys, sqlite3, json, socketserver
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration — override via environment variables
# ---------------------------------------------------------------------------
DB_PATH = os.environ.get("SYSTEM_INSPECTOR_DB", "/var/lib/sys-inspector/sys-inspector.db")
API_PORT = int(os.environ.get("API_PORT", "8765"))
BASE_DIR = Path(__file__).resolve().parent.parent.parent   # sys-inspector repo root

# ---------------------------------------------------------------------------
# Database helper — returns a read-only connection with Row factory
# ---------------------------------------------------------------------------
def get_db():
    """Return a read-only SQLite connection, or None if DB unavailable."""
    try:
        conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        return conn
    except Exception:
        return None

# ---------------------------------------------------------------------------
# JSON response helper — always adds CORS headers for dashboard access
# ---------------------------------------------------------------------------
def json_response(data, status=200):
    """Encode data as JSON with CORS headers."""
    body = json.dumps(data, default=str)
    return body, status, {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"}

# ===========================================================================
# FLASK IMPLEMENTATION (preferred)
# ===========================================================================
try:
    from flask import Flask, send_from_directory

    app = Flask(__name__, static_folder=str(BASE_DIR / "dashboard"))

    # --- Static dashboard routes ---
    @app.route("/")
    def index():
        return send_from_directory(app.static_folder, "dashboard.html")

    @app.route("/dashboard.html")
    def dashboard():
        return send_from_directory(app.static_folder, "dashboard.html")

    # --- API endpoints ---
    @app.route("/api/boot")
    def api_boot():
        db = get_db()
        if db:
            rows = db.execute(
                "SELECT * FROM boot_health ORDER BY id DESC LIMIT 20"
            ).fetchall()
            return json_response([dict(r) for r in rows])
        return json_response({"error": "DB not available"}, 503)

    @app.route("/api/resources")
    def api_resources():
        db = get_db()
        if db:
            rows = db.execute(
                "SELECT * FROM resource_samples "
                "WHERE sample_ts > datetime('now','-1 hour') "
                "ORDER BY id DESC LIMIT 120"
            ).fetchall()
            return json_response([dict(r) for r in rows])
        return json_response({"error": "DB not available"}, 503)

    @app.route("/api/services")
    def api_services():
        db = get_db()
        if db:
            rows = db.execute(
                "SELECT * FROM service_manifest ORDER BY unit_name"
            ).fetchall()
            return json_response([dict(r) for r in rows])
        return json_response({"error": "DB not available"}, 503)

    @app.route("/api/errors")
    def api_errors():
        db = get_db()
        if db:
            rows = db.execute(
                "SELECT * FROM error_log WHERE resolved=0 ORDER BY count DESC"
            ).fetchall()
            return json_response([dict(r) for r in rows])
        return json_response({"error": "DB not available"}, 503)

    @app.route("/api/health")
    def api_health():
        db_exists = os.path.exists(DB_PATH)
        return json_response({
            "status": "ok",
            "timestamp": datetime.now().isoformat(),
            "db_exists": db_exists
        })

    print(f"[api-server] Flask mode on http://127.0.0.1:{API_PORT}")
    sys.stdout.flush()
    app.run(host="127.0.0.1", port=API_PORT, debug=False)

# ===========================================================================
# FALLBACK: Pure Python http.server (no Flask dependency)
# ===========================================================================
except ImportError:
    import http.server

    DASHBOARD_DIR = BASE_DIR / "dashboard"

    class Handler(http.server.SimpleHTTPRequestHandler):
        """Custom handler: /api/* routes return JSON; everything else is static."""

        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(DASHBOARD_DIR), **kwargs)

        def do_GET(self):
            if self.path.startswith("/api/"):
                self._handle_api()
            else:
                super().do_GET()

        def _handle_api(self):
            endpoint = self.path[5:]  # strip "/api/" prefix
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            try:
                db = get_db()
                if not db:
                    raise Exception("Database unavailable")
                if endpoint == "boot":
                    rows = db.execute(
                        "SELECT * FROM boot_health ORDER BY id DESC LIMIT 20"
                    ).fetchall()
                elif endpoint == "resources":
                    rows = db.execute(
                        "SELECT * FROM resource_samples "
                        "WHERE sample_ts > datetime('now','-1 hour') "
                        "ORDER BY id DESC LIMIT 120"
                    ).fetchall()
                elif endpoint == "services":
                    rows = db.execute(
                        "SELECT * FROM service_manifest ORDER BY unit_name"
                    ).fetchall()
                elif endpoint == "errors":
                    rows = db.execute(
                        "SELECT * FROM error_log WHERE resolved=0 ORDER BY count DESC"
                    ).fetchall()
                elif endpoint == "health":
                    self.wfile.write(json.dumps({
                        "status": "ok",
                        "db_exists": os.path.exists(DB_PATH)
                    }).encode())
                    return
                else:
                    self.wfile.write(json.dumps({"error": "Unknown endpoint"}).encode())
                    return
                self.wfile.write(json.dumps([dict(r) for r in rows], default=str).encode())
            except Exception as e:
                self.wfile.write(json.dumps({"error": str(e)}).encode())

    print(f"[api-server] Fallback mode on http://127.0.0.1:{API_PORT}")
    sys.stdout.flush()
    with socketserver.TCPServer(("127.0.0.1", API_PORT), Handler) as httpd:
        httpd.serve_forever()
