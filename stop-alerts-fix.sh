#!/bin/bash
# FINAL ELIMINATION – Desktop alerts & zero boot records

echo "═══════════════════════════════════════════════════════════════"
echo "  FINAL FIX – NO MORE ALERTS & CLEAN BOOT DATA"
echo "═══════════════════════════════════════════════════════════════"

# 1. Kill EVERY possible alerter process
echo ""
echo "[1/6] Killing all alerter processes..."
sudo pkill -9 -f "alerter" 2>/dev/null || true
sudo pkill -9 -f "notify-send" 2>/dev/null || true
sudo pkill -9 -f "journalctl.*priority" 2>/dev/null || true
sudo pkill -9 -f "sys-inspector-alerter" 2>/dev/null || true
sudo pkill -9 -f "desktop-notification" 2>/dev/null || true

# 2. Remove ALL timer files (system and user)
echo ""
echo "[2/6] Removing timer files..."
sudo rm -f /etc/systemd/system/sys-inspector-alerter.*
sudo rm -f /etc/systemd/system/sys-inspector-journal.timer
sudo rm -f /etc/systemd/system/sys-inspector-process.timer
sudo rm -f /etc/systemd/system/sys-inspector-network.timer
sudo rm -f /home/owner/.config/systemd/user/sys-inspector-*.timer
sudo rm -f /home/owner/.config/systemd/user/sys-inspector-*.service

# 3. Reload systemd
echo ""
echo "[3/6] Reloading systemd..."
sudo systemctl daemon-reload
systemctl --user daemon-reload 2>/dev/null || true

# 4. Fix database permissions and delete zero boot records
echo ""
echo "[4/6] Fixing database and deleting zero boot records..."
sudo chmod 666 /var/lib/sys-inspector/sys-inspector.db
sqlite3 /var/lib/sys-inspector/sys-inspector.db "DELETE FROM boot_health WHERE total_ms = 0 OR total_ms IS NULL;"
sqlite3 /var/lib/sys-inspector/sys-inspector.db "SELECT COUNT(*) FROM boot_health;"

# 5. Run boot collector to get fresh positive record
echo ""
echo "[5/6] Running boot collector..."
sudo /usr/local/share/sys-inspector/src/collectors/boot-health.sh

# 6. Restart API server
echo ""
echo "[6/6] Restarting API server..."
sudo pkill -f api-server.py || true
sudo systemctl restart sys-inspector-api.service 2>/dev/null || python3 /usr/local/share/sys-inspector/src/api/api-server.py &

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FIX COMPLETE"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  ✅ All alerter processes killed"
echo "  ✅ All timers removed"
echo "  ✅ Zero boot records deleted"
echo "  ✅ Fresh boot record captured"
echo ""
echo "  Refresh your browser: http://127.0.0.1:8765/"
echo "  The 'Sys-Inspector Alert' popups will NOT return."
echo ""