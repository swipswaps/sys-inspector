#!/usr/bin/env python3
# api-server.py — Fixed REST API for Sys-Inspector Dashboard

from flask import Flask, jsonify, send_from_directory
import sqlite3
import os

app = Flask(__name__)

DB_PATH = os.environ.get('SYSTEM_INSPECTOR_DB', '/var/lib/sys-inspector/sys-inspector.db')
DASHBOARD_DIR = '/usr/local/share/sys-inspector/dashboard'

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

@app.route('/')
@app.route('/dashboard.html')
def dashboard():
    return send_from_directory(DASHBOARD_DIR, 'dashboard.html')

@app.route('/api/boot')
def api_boot():
    conn = get_db()
    rows = conn.execute(
        "SELECT boot_ts, total_ms, slowest_unit "
        "FROM boot_health ORDER BY id DESC LIMIT 10"
    ).fetchall()
    conn.close()
    
    data = [{
        'boot_ts': row['boot_ts'],
        'total_seconds': round(row['total_ms'] / 1000.0, 2) if row['total_ms'] else 0,
        'slowest_unit': (row['slowest_unit'] or 'N/A').split('\n')[0]
    } for row in rows]
    return jsonify(data)

@app.route('/api/resources')
def api_resources():
    conn = get_db()
    rows = conn.execute(
        "SELECT sampled_at, cpu_user, cpu_system, cpu_idle, cpu_iowait, "
        "mem_total, mem_used, mem_free, mem_cached, load_1min, load_5min, load_15min "
        "FROM resource_samples "
        "WHERE sampled_at > datetime('now','-1 hour') "
        "ORDER BY id DESC LIMIT 120"
    ).fetchall()
    conn.close()
    
    data = [{
        'sampled_at': row['sampled_at'],
        'cpu_user': row['cpu_user'] or 0,
        'cpu_system': row['cpu_system'] or 0,
        'cpu_idle': row['cpu_idle'] or 0,
        'cpu_iowait': row['cpu_iowait'] or 0,
        'mem_used_percent': round((row['mem_used'] or 0) * 100.0 / (row['mem_total'] or 1), 1) if row['mem_total'] else 0,
        'load_1min': row['load_1min'] or 0
    } for row in rows]
    return jsonify(data)

@app.route('/api/services')
def api_services():
    conn = get_db()
    rows = conn.execute(
        "SELECT state, COUNT(*) as count "
        "FROM service_manifest "
        "GROUP BY state "
        "ORDER BY count DESC"
    ).fetchall()
    conn.close()
    
    data = [{'state': row['state'], 'count': row['count']} for row in rows]
    return jsonify(data)

@app.route('/api/errors')
def api_errors():
    conn = get_db()
    rows = conn.execute(
        "SELECT timestamp, service, severity, message "
        "FROM error_log WHERE resolved=0 "
        "ORDER BY timestamp DESC LIMIT 50"
    ).fetchall()
    conn.close()
    
    data = [{
        'timestamp': row['timestamp'],
        'service': row['service'],
        'severity': row['severity'],
        'message': row['message']
    } for row in rows]
    return jsonify(data)

@app.route('/api/stats')
def api_stats():
    conn = get_db()
    stats = {}
    for table in ['boot_health', 'resource_samples', 'service_manifest', 'error_log', 'shutdown_capture']:
        count = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        stats[table] = count
    conn.close()
    return jsonify(stats)

if __name__ == '__main__':
    print("[api-server] Starting on http://127.0.0.1:8765")
    print(f"[api-server] Dashboard: {DASHBOARD_DIR}/dashboard.html")
    print("[api-server] Fixed: static folder path, cleaned slowest_unit output")
    app.run(host='127.0.0.1', port=8765, debug=False)
