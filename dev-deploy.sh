#!/usr/bin/env bash
# dev-deploy.sh — Deploy from project to production without breaking
# RLM: External observation with safe copy, not symlinks

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "═══════════════════════════════════════════════════════════════"
echo "  DEPLOY FROM PROJECT TO PRODUCTION"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Project: $PROJECT_DIR"
echo ""

# Verify manifest exists in production
if [[ ! -f /usr/local/share/sys-inspector/install-from-project.sh ]]; then
    echo "ERROR: Production installer not found."
    echo "Run: sudo /usr/local/share/sys-inspector/install-from-project.sh $PROJECT_DIR"
    exit 1
fi

# Deploy
sudo /usr/local/share/sys-inspector/install-from-project.sh "$PROJECT_DIR"

echo ""
echo "  To uninstall completely: sudo /usr/local/share/sys-inspector/uninstall.sh"
echo "  Project files remain in: $PROJECT_DIR"
echo ""
