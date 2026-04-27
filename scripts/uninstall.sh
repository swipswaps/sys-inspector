#!/usr/bin/env bash
# uninstall.sh — Clean removal of sys-inspector (manifest-driven)
#
# WHAT: Reads the install manifest to determine what was installed,
#       then removes all components. Preserves database by default.
#
# WHY: Install/uninstall symmetry ensures no orphaned files remain.
#      Using the manifest guarantees that uninstall matches the actual
#      installation paths.
#
# HOW: 1. Verify running as root
#      2. Source install manifest for paths
#      3. Stop and disable all sys-inspector systemd units
#      4. Remove unit files from /etc/systemd/system/
#      5. Remove TUI symlink
#      6. Remove install directory
#      7. Optionally remove database (user must confirm)
#
# ASSUMES: Install manifest exists at /var/lib/sys-inspector/install-manifest.txt
#
# VERIFIES WITH: Each removed component prints confirmation
#
# FAILURE MODE: If manifest is missing, falls back to hardcoded defaults
#               but warns that cleanup may be incomplete.

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
pass_msg() { echo -e "${GREEN}[PASS]${NC} $*"; }
warn_msg() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail_msg() { echo -e "${RED}[FAIL]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "[FAIL] Run as root (sudo ./uninstall.sh)"
  exit 1
fi

MANIFEST_FILE="/var/lib/sys-inspector/install-manifest.txt"

if [[ -f "$MANIFEST_FILE" ]]; then
  pass_msg "Reading install manifest"
  source "$MANIFEST_FILE"
else
  warn_msg "Manifest not found – using default paths"
  INSTALL_DIR="/usr/local/share/sys-inspector"
  DB_DIR="/var/lib/sys-inspector"
  TUI_SYMLINK="/usr/local/bin/sys-inspector-tui"
fi

echo ""
echo "Disabling systemd units..."
for base in boot contention shutdown manifest; do
  for ext in service timer; do
    unit="sys-inspector-${base}.${ext}"
    if systemctl is-enabled "$unit" &>/dev/null 2>&1; then
      systemctl disable --now "$unit" 2>/dev/null && \
        pass_msg "Disabled $unit" || \
        warn_msg "Could not disable $unit"
    fi
  done
done

echo ""
echo "Removing unit files..."
rm -f /etc/systemd/system/sys-inspector-*.{service,timer} 2>/dev/null || true
systemctl daemon-reload
pass_msg "Unit files removed"

echo ""
if [[ -L "$TUI_SYMLINK" ]]; then
  rm -f "$TUI_SYMLINK"
  pass_msg "Removed symlink: $TUI_SYMLINK"
fi

echo ""
if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
  pass_msg "Removed install directory"
fi

rm -f "$MANIFEST_FILE" 2>/dev/null || true

echo ""
read -p "Remove database at $DB_DIR? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  rm -rf "$DB_DIR"
  pass_msg "Database removed"
else
  pass_msg "Database preserved"
fi

echo ""
pass_msg "Sys-inspector uninstalled."
