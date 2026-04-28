#!/usr/bin/env python3
"""
Sys-Inspector API Server
Provides REST endpoints for the dashboard
"""

import json
import sqlite3
import subprocess
import os
import sys
import re
from datetime import datetime
from pathlib import Path
from flask import Flask, jsonify, request

app = Flask(__name__)

# Simple CORS middleware (no flask_cors dependency needed)
@app.after_request
def add_cors_headers(response):
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE, OPTIONS'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type'
    return response

@app.route('/', methods=['OPTIONS'])
@app.route('/<path:path>', methods=['OPTIONS'])
def handle_options(path=None):
    return '', 200

DB_PATH = Path.home() / '.sys-inspector' / 'sys-inspector.db'


def get_db_connection():
    """Get database connection"""
    if DB_PATH.exists():
        conn = sqlite3.connect(str(DB_PATH))
        conn.row_factory = sqlite3.Row
        return conn
    return None


def ensure_db_schema():
    """Create database and tables if they don't exist"""
    os.makedirs(DB_PATH.parent, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    cursor = conn.cursor()
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS boot_times (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            boot_id TEXT UNIQUE,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            kernel_ms REAL,
            initrd_ms REAL,
            userspace_ms REAL,
            total_ms REAL
        )
    """)
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS services (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            name TEXT,
            state TEXT,
            load_time_ms REAL,
            active_state TEXT,
            sub_state TEXT,
            description TEXT
        )
    """)
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS error_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            source TEXT,
            service TEXT,
            message TEXT,
            severity TEXT,
            count INTEGER DEFAULT 1
        )
    """)
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS resource_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            cpu_percent REAL,
            memory_percent REAL,
            disk_used_percent REAL,
            load_avg_1min REAL,
            load_avg_5min REAL,
            load_avg_15min REAL
        )
    """)
    
    conn.commit()
    conn.close()
    return True


@app.route('/api/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok', 'timestamp': datetime.now().isoformat()})


@app.route('/api/services', methods=['GET'])
def get_services():
    """Get list of services"""
    ensure_db_schema()
    conn = get_db_connection()
    
    if not conn:
        # Fallback to systemctl
        try:
            result = subprocess.run(
                ['systemctl', 'list-units', '--type=service', '--all', '--no-legend', '--no-pager'],
                capture_output=True, text=True, timeout=10
            )
            services = []
            for line in result.stdout.strip().split('\n'):
                if not line.strip():
                    continue
                parts = line.split()
                if len(parts) >= 4:
                    services.append({
                        'name': parts[0],
                        'state': parts[3],
                        'load_time_ms': 0
                    })
            return jsonify(services[:200])
        except Exception as e:
            return jsonify({'error': str(e)}), 500
    
    cursor = conn.cursor()
    cursor.execute("""
        SELECT name, state, load_time_ms, active_state, sub_state
        FROM services
        WHERE timestamp = (SELECT MAX(timestamp) FROM services)
        ORDER BY name
        LIMIT 500
    """)
    
    services = [dict(row) for row in cursor.fetchall()]
    conn.close()
    
    if not services:
        # Return sample data
        services = [
            {'name': 'NetworkManager.service', 'state': 'active', 'load_time_ms': 4450},
            {'name': 'sshd.service', 'state': 'active', 'load_time_ms': 1230},
            {'name': 'cron.service', 'state': 'active', 'load_time_ms': 890},
        ]
    
    return jsonify(services)


@app.route('/api/errors', methods=['GET'])
def get_errors():
    """Get current system errors"""
    ensure_db_schema()
    conn = get_db_connection()
    
    if not conn:
        # Fallback to journalctl
        try:
            result = subprocess.run(
                ['journalctl', '-p', '3', '-n', '30', '--no-pager', '-o', 'cat'],
                capture_output=True, text=True, timeout=10
            )
            errors = []
            for line in result.stdout.strip().split('\n'):
                if line.strip():
                    errors.append({
                        'source': 'journald',
                        'message': line[:200],
                        'count': 1
                    })
            return jsonify(errors[:30])
        except Exception as e:
            return jsonify([{'source': 'system', 'message': f'Cannot read journal: {e}', 'count': 1}])
    
    cursor = conn.cursor()
    cursor.execute("""
        SELECT source, message, COUNT(*) as count, MAX(timestamp) as last_seen
        FROM error_log
        WHERE timestamp > datetime('now', '-1 hour')
        GROUP BY source, message
        ORDER BY count DESC
        LIMIT 50
    """)
    
    errors = [dict(row) for row in cursor.fetchall()]
    conn.close()
    
    if not errors:
        errors = [{'source': 'system', 'message': 'No recent errors detected', 'count': 0}]
    
    return jsonify(errors)


@app.route('/api/errors/trend', methods=['GET'])
def get_error_trend():
    """Get error frequency over time"""
    hours = request.args.get('hours', 12, type=int)
    ensure_db_schema()
    conn = get_db_connection()
    
    if not conn:
        # Return mock data
        mock_hours = [f"{i:02d}:00" for i in range(hours)]
        mock_counts = [3, 1, 0, 0, 2, 5, 8, 12, 15, 10, 7, 5][:hours]
        return jsonify({'hours': mock_hours, 'counts': mock_counts})
    
    cursor = conn.cursor()
    cursor.execute("""
        SELECT 
            strftime('%H:00', timestamp) as hour,
            COUNT(*) as count
        FROM error_log
        WHERE timestamp > datetime('now', ?)
        GROUP BY hour
        ORDER BY hour
    """, (f'-{hours} hours',))
    
    rows = cursor.fetchall()
    conn.close()
    
    hours_list = [row['hour'] for row in rows]
    counts_list = [row['count'] for row in rows]
    
    return jsonify({
        'hours': hours_list if hours_list else [f"{i:02d}:00" for i in range(hours)],
        'counts': counts_list if counts_list else [0] * hours
    })


@app.route('/api/boot/timeline', methods=['GET'])
def get_boot_timeline():
    """Get boot time history"""
    limit = request.args.get('limit', 8, type=int)
    ensure_db_schema()
    conn = get_db_connection()
    
    if not conn:
        # Get current boot time
        try:
            result = subprocess.run(
                ['systemd-analyze', 'time'],
                capture_output=True, text=True, timeout=5
            )
            match = re.search(r'=\s*([\d.]+)s', result.stdout)
            total = float(match.group(1)) if match else 0
            return jsonify({'boots': [{
                'boot_id': 'current',
                'total_ms': total * 1000,
                'timestamp': datetime.now().isoformat()
            }]})
        except:
            return jsonify({'boots': []})
    
    cursor = conn.cursor()
    cursor.execute("""
        SELECT boot_id, total_ms, timestamp
        FROM boot_times
        ORDER BY timestamp DESC
        LIMIT ?
    """, (limit,))
    
    boots = [dict(row) for row in cursor.fetchall()]
    conn.close()
    
    if not boots:
        # Add a sample boot record for demo
        boots = [{
            'boot_id': 'sample',
            'total_ms': 15813,
            'timestamp': datetime.now().isoformat()
        }]
    
    return jsonify({'boots': boots})


@app.route('/api/fix', methods=['POST'])
def fix_error():
    """One-click error remediation"""
    data = request.json or {}
    service = data.get('service', '')
    message = data.get('message', '')
    
    # Define safe fixes
    fixes = {
        'NetworkManager': ['sudo', 'systemctl', 'restart', 'NetworkManager'],
        'systemd-journald': ['sudo', 'systemctl', 'restart', 'systemd-journald'],
        'cron': ['sudo', 'systemctl', 'restart', 'cron'],
        'sshd': ['sudo', 'systemctl', 'restart', 'sshd'],
    }
    
    target = None
    for known in fixes:
        if known.lower() in service.lower() or known.lower() in message.lower():
            target = known
            break
    
    if not target:
        return jsonify({
            'success': False,
            'message': f'No auto-fix for {service}',
            'suggestion': f'systemctl status {service}'
        }), 400
    
    try:
        result = subprocess.run(fixes[target], capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            return jsonify({'success': True, 'message': f'Restarted {target}'})
        else:
            return jsonify({'success': False, 'message': f'Failed to restart {target}'}), 500
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@app.route('/api/stats', methods=['GET'])
def get_stats():
    """Get summary statistics"""
    ensure_db_schema()
    conn = get_db_connection()
    
    if not conn:
        return jsonify({'total_services': 0, 'error_count': 0, 'boot_time': 0})
    
    cursor = conn.cursor()
    cursor.execute("SELECT COUNT(*) as count FROM services")
    service_count = cursor.fetchone()['count']
    
    cursor.execute("SELECT COUNT(*) as count FROM error_log WHERE timestamp > datetime('now', '-1 hour')")
    error_count = cursor.fetchone()['count']
    
    cursor.execute("SELECT total_ms FROM boot_times ORDER BY timestamp DESC LIMIT 1")
    boot_row = cursor.fetchone()
    boot_time = boot_row['total_ms'] / 1000 if boot_row else 0
    
    conn.close()
    
    return jsonify({
        'total_services': service_count,
        'error_count': error_count,
        'boot_time': boot_time
    })


if __name__ == '__main__':
    ensure_db_schema()
    print("🚀 Sys-Inspector API Server starting...")
    print(f"📍 Dashboard: http://localhost:8765")
    print(f"📊 API: http://localhost:8765/api/health")
    print(f"🔧 Press Ctrl+C to stop")
    app.run(host='0.0.0.0', port=8765, debug=False, threaded=True)
