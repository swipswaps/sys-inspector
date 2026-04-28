#!/usr/bin/env bash
# check-deps.sh — RLM-hardened dependency verification with FULL TRANSPARENCY
#
# RLM METHODS IMPLEMENTED:
# - External environment observation: checks binaries, versions, system state
# - Recursive validation: categorizes deps as required vs optional
# - Symbolic decomposition: each dependency check is atomic and verifiable
#
# TRANSPARENCY PRINCIPLE (User Request):
#   ALL event, error, system and application messages are logged and displayed
#   verbatim. Nothing hidden with 2>/dev/null. STDERR is tee'd to both console
#   and log file for complete auditability.
#
# EXIT CODES:
#   0 - All required dependencies satisfied
#   1 - Missing required dependency

# Set up logging with FULL transparency - capture EVERYTHING
LOG_FILE="/tmp/sys-inspector-deps-check-$(date +%Y%m%d-%H%M%S).log"
exec 2> >(tee -a "$LOG_FILE" >&2)
exec 1> >(tee -a "$LOG_FILE")

# Colors for output (safe for non-interactive)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# Counters for failures
REQUIRED_FAILED=0
OPTIONAL_MISSING=0

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  SYS-INSPECTOR DEPENDENCY CHECK (RLM Recursive Validation)"
echo "  Log file: $LOG_FILE"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ============================================================
# System environment validation (Layer 0)
# ============================================================
echo -e "${BLUE}[Layer 0]${NC} System Environment"

# Check OS type - with full stderr visibility
OS_TYPE="unknown"
if [[ -f /etc/os-release ]]; then
    echo "  Reading /etc/os-release..."
    cat /etc/os-release | head -5
    source /etc/os-release
    OS_TYPE="${ID:-unknown}"
    echo -e "  OS: ${PRETTY_NAME:-$ID}"
else
    echo -e "  ${YELLOW}⚠${NC} Cannot determine OS type - /etc/os-release not found"
fi

# Check kernel
KERNEL_VERSION=$(uname -r)
echo -e "  Kernel: $KERNEL_VERSION"

# Check architecture
ARCH=$(uname -m)
echo -e "  Architecture: $ARCH"

# Check systemd - show FULL command output
echo "  Checking systemd:"
if command -v systemctl; then
    echo "    systemctl found at: $(which systemctl)"
    SYSTEMD_VERSION=$(systemctl --version | head -1)
    echo "    systemctl --version output: $SYSTEMD_VERSION"
    SYSTEMD_VERSION_NUM=$(echo "$SYSTEMD_VERSION" | awk '{print $2}')
    echo -e "  ${GREEN}✓${NC} systemd version $SYSTEMD_VERSION_NUM"
else
    echo -e "  ${RED}✗${NC} systemctl command not found in PATH"
    echo "    PATH=$PATH"
    REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
fi

echo ""

# ============================================================
# Required binary dependencies (Layer 1)
# ============================================================
echo -e "${BLUE}[Layer 1]${NC} Required Binaries"

# sqlite3 check - show full command output
echo "  Checking sqlite3:"
if command -v sqlite3; then
    echo "    sqlite3 found at: $(which sqlite3)"
    SQLITE_VERSION=$(sqlite3 --version)
    echo "    sqlite3 --version output: $SQLITE_VERSION"
    SQLITE_VERSION_NUM=$(echo "$SQLITE_VERSION" | awk '{print $1}')
    echo -e "  ${GREEN}✓${NC} SQLite3: $SQLITE_VERSION_NUM"
else
    echo -e "  ${RED}✗${NC} sqlite3 command not found in PATH"
    echo "    PATH=$PATH"
    REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
fi

# systemctl check
echo "  Checking systemctl:"
if command -v systemctl; then
    echo "    systemctl found at: $(which systemctl)"
    echo -e "  ${GREEN}✓${NC} systemd: systemctl"
else
    echo -e "  ${RED}✗${NC} systemctl command not found"
    REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
fi

# systemd-analyze check
echo "  Checking systemd-analyze:"
if command -v systemd-analyze; then
    echo "    systemd-analyze found at: $(which systemd-analyze)"
    echo -e "  ${GREEN}✓${NC} systemd: systemd-analyze"
else
    echo -e "  ${RED}✗${NC} systemd-analyze command not found"
    REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
fi

# Python check
echo "  Checking Python:"
if command -v python3; then
    echo "    python3 found at: $(which python3)"
    PYTHON_VERSION=$(python3 --version 2>&1)
    echo "    python3 --version output: $PYTHON_VERSION"
    echo -e "  ${GREEN}✓${NC} Python: $PYTHON_VERSION"
elif command -v python; then
    echo "    python found at: $(which python)"
    PYTHON_VERSION=$(python --version 2>&1)
    echo "    python --version output: $PYTHON_VERSION"
    echo -e "  ${GREEN}✓${NC} Python: $PYTHON_VERSION"
else
    echo -e "  ${RED}✗${NC} python3 (or python) command not found in PATH"
    echo "    PATH=$PATH"
    REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
fi

echo ""

# ============================================================
# Optional binary dependencies (Layer 2)
# ============================================================
echo -e "${BLUE}[Layer 2]${NC} Optional Binaries (enhance functionality)"

# dialog check
echo "  Checking dialog:"
if command -v dialog; then
    echo "    dialog found at: $(which dialog)"
    DIALOG_VERSION=$(dialog --version 2>&1 | head -1)
    echo "    dialog --version output: $DIALOG_VERSION"
    echo -e "  ${GREEN}✓${NC} dialog (TUI interface)"
else
    echo "    dialog not found in PATH"
    echo -e "  ${YELLOW}⚠${NC} dialog - TUI interface (optional, will use fallback)"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
fi

# whiptail check
echo "  Checking whiptail:"
if command -v whiptail; then
    echo "    whiptail found at: $(which whiptail)"
    echo -e "  ${GREEN}✓${NC} whiptail (TUI fallback)"
else
    echo "    whiptail not found in PATH"
    echo -e "  ${YELLOW}⚠${NC} whiptail - TUI fallback (optional)"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
fi

# jq check
echo "  Checking jq:"
if command -v jq; then
    echo "    jq found at: $(which jq)"
    JQ_VERSION=$(jq --version 2>&1)
    echo "    jq --version output: $JQ_VERSION"
    echo -e "  ${GREEN}✓${NC} jq (JSON processing)"
else
    echo "    jq not found in PATH"
    echo -e "  ${YELLOW}⚠${NC} jq - JSON processing (optional, will use fallback)"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
fi

# mpstat check (sysstat)
echo "  Checking mpstat:"
if command -v mpstat; then
    echo "    mpstat found at: $(which mpstat)"
    echo -e "  ${GREEN}✓${NC} mpstat (CPU statistics)"
else
    echo "    mpstat not found in PATH"
    echo -e "  ${YELLOW}⚠${NC} mpstat - CPU statistics (optional, install sysstat)"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
fi

# iostat check (sysstat)
echo "  Checking iostat:"
if command -v iostat; then
    echo "    iostat found at: $(which iostat)"
    echo -e "  ${GREEN}✓${NC} iostat (IO statistics)"
else
    echo "    iostat not found in PATH"
    echo -e "  ${YELLOW}⚠${NC} iostat - IO statistics (optional, install sysstat)"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
fi

# notify-send check
echo "  Checking notify-send:"
if command -v notify-send; then
    echo "    notify-send found at: $(which notify-send)"
    echo -e "  ${GREEN}✓${NC} notify-send (Desktop alerts)"
else
    echo "    notify-send not found in PATH"
    echo -e "  ${YELLOW}⚠${NC} notify-send - Desktop alerts (optional)"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
fi

# fuser check
echo "  Checking fuser:"
if command -v fuser; then
    echo "    fuser found at: $(which fuser)"
    echo -e "  ${GREEN}✓${NC} fuser (Process file locks)"
else
    echo "    fuser not found in PATH"
    echo -e "  ${YELLOW}⚠${NC} fuser - Process file locks (optional, install psmisc)"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
fi

echo ""

# ============================================================
# Directory permissions validation (Layer 3)
# ============================================================
echo -e "${BLUE}[Layer 3]${NC} Directory & Permission Validation"

# Check /var/lib/sys-inspector
echo "  Checking /var/lib/sys-inspector:"
if [[ -d "/var/lib/sys-inspector" ]]; then
    ls -la /var/lib/sys-inspector 2>&1 | head -5
    if [[ -w "/var/lib/sys-inspector" ]]; then
        echo -e "  ${GREEN}✓${NC} /var/lib/sys-inspector writable"
    else
        echo -e "  ${YELLOW}⚠${NC} /var/lib/sys-inspector exists but not writable (sudo required)"
        echo "    Current user: $(whoami), EUID=$EUID"
    fi
else
    echo -e "  ${YELLOW}⚠${NC} /var/lib/sys-inspector does not exist (will be created during install)"
fi

# Check /var/log/sys-inspector
echo "  Checking /var/log/sys-inspector:"
if [[ -d "/var/log/sys-inspector" ]]; then
    ls -la /var/log/sys-inspector 2>&1 | head -5
    if [[ -w "/var/log/sys-inspector" ]]; then
        echo -e "  ${GREEN}✓${NC} /var/log/sys-inspector writable"
    else
        echo -e "  ${YELLOW}⚠${NC} /var/log/sys-inspector exists but not writable (sudo required)"
    fi
else
    echo -e "  ${YELLOW}⚠${NC} /var/log/sys-inspector does not exist (will be created during install)"
fi

# Check current user privileges
echo "  Checking user privileges:"
echo "    EUID=$EUID, USER=$(whoami), GROUPS=$(groups 2>&1)"
if [[ $EUID -eq 0 ]]; then
    echo -e "  ${GREEN}✓${NC} Running as root (full privileges)"
elif groups 2>&1 | grep -q wheel || groups 2>&1 | grep -q sudo; then
    echo -e "  ${GREEN}✓${NC} User has sudo access (will prompt when needed)"
else
    echo -e "  ${YELLOW}⚠${NC} User may not have sudo access - install will fail"
fi

echo ""

# ============================================================
# Package manager detection (Layer 4) - FULL TRANSPARENCY
# ============================================================
echo -e "${BLUE}[Layer 4]${NC} Package Manager"

PM_FOUND=0

# Check for dnf
echo "  Checking for dnf:"
if command -v dnf; then
    echo "    dnf found at: $(which dnf)"
    echo "    Running: dnf --version"
    DNF_OUTPUT=$(dnf --version 2>&1)
    echo "    dnf --version output:"
    echo "$DNF_OUTPUT" | head -10
    DNF_INFO=$(echo "$DNF_OUTPUT" | head -1)
    echo -e "  ${GREEN}✓${NC} DNF package manager (Fedora/RHEL) - $DNF_INFO"
    PM_FOUND=1
else
    echo "    dnf not found in PATH"
fi

# Check for apt-get if dnf not found
if [[ $PM_FOUND -eq 0 ]]; then
    echo "  Checking for apt-get:"
    if command -v apt-get; then
        echo "    apt-get found at: $(which apt-get)"
        echo "    Running: apt-get --version"
        APT_OUTPUT=$(apt-get --version 2>&1)
        echo "    apt-get --version output:"
        echo "$APT_OUTPUT" | head -5
        APT_INFO=$(echo "$APT_OUTPUT" | head -1)
        echo -e "  ${GREEN}✓${NC} APT package manager (Debian/Ubuntu) - $APT_INFO"
        PM_FOUND=1
    else
        echo "    apt-get not found in PATH"
    fi
fi

# Check for yum if others not found
if [[ $PM_FOUND -eq 0 ]]; then
    echo "  Checking for yum:"
    if command -v yum; then
        echo "    yum found at: $(which yum)"
        echo "    Running: yum --version"
        YUM_OUTPUT=$(yum --version 2>&1)
        echo "    yum --version output:"
        echo "$YUM_OUTPUT" | head -5
        YUM_INFO=$(echo "$YUM_OUTPUT" | head -1)
        echo -e "  ${GREEN}✓${NC} YUM package manager (RHEL/CentOS) - $YUM_INFO"
        PM_FOUND=1
    else
        echo "    yum not found in PATH"
    fi
fi

# Check for zypper if others not found
if [[ $PM_FOUND -eq 0 ]]; then
    echo "  Checking for zypper:"
    if command -v zypper; then
        echo "    zypper found at: $(which zypper)"
        echo "    Running: zypper --version"
        ZYPPER_OUTPUT=$(zypper --version 2>&1)
        echo "    zypper --version output:"
        echo "$ZYPPER_OUTPUT" | head -5
        ZYPPER_INFO=$(echo "$ZYPPER_OUTPUT" | head -1)
        echo -e "  ${GREEN}✓${NC} Zypper package manager (openSUSE) - $ZYPPER_INFO"
        PM_FOUND=1
    else
        echo "    zypper not found in PATH"
    fi
fi

# Check for pacman if others not found
if [[ $PM_FOUND -eq 0 ]]; then
    echo "  Checking for pacman:"
    if command -v pacman; then
        echo "    pacman found at: $(which pacman)"
        echo "    Running: pacman --version"
        PACMAN_OUTPUT=$(pacman --version 2>&1)
        echo "    pacman --version output:"
        echo "$PACMAN_OUTPUT" | head -5
        PACMAN_INFO=$(echo "$PACMAN_OUTPUT" | head -1)
        echo -e "  ${GREEN}✓${NC} Pacman package manager (Arch) - $PACMAN_INFO"
        PM_FOUND=1
    else
        echo "    pacman not found in PATH"
    fi
fi

if [[ $PM_FOUND -eq 0 ]]; then
    echo -e "  ${YELLOW}⚠${NC} No supported package manager found - will attempt manual dependency check"
fi

echo ""

# ============================================================
# Database compatibility (Layer 5)
# ============================================================
echo -e "${BLUE}[Layer 5]${NC} Database Compatibility"

echo "  Checking SQLite functionality:"
if command -v sqlite3; then
    SQLITE_VERSION=$(sqlite3 --version 2>&1 | awk '{print $1}')
    echo "    SQLite version: $SQLITE_VERSION"
    
    # Test basic SQLite functionality - show full output
    echo "    Testing: echo 'SELECT 1;' | sqlite3 :memory:"
    SQLITE_TEST_OUTPUT=$(echo "SELECT 1;" | sqlite3 :memory: 2>&1)
    SQLITE_TEST_EXIT=$?
    echo "    Exit code: $SQLITE_TEST_EXIT"
    echo "    Output: $SQLITE_TEST_OUTPUT"
    
    if [[ $SQLITE_TEST_EXIT -eq 0 ]] && [[ "$SQLITE_TEST_OUTPUT" == "1" ]]; then
        echo -e "  ${GREEN}✓${NC} SQLite $SQLITE_VERSION functional test passed"
    else
        echo -e "  ${RED}✗${NC} SQLite functional test failed (exit code: $SQLITE_TEST_EXIT)"
        REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗${NC} SQLite not available"
    REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
fi

echo ""

# ============================================================
# Collector-specific checks (Layer 6)
# ============================================================
echo -e "${BLUE}[Layer 6]${NC} Collector-Specific Checks"

# Check systemd-analyze (for boot-health collector)
echo "  Checking boot-health collector prerequisites:"
if command -v systemd-analyze; then
    echo "    Running: systemd-analyze time"
    SYSTEMD_ANALYZE_OUTPUT=$(systemd-analyze time 2>&1)
    SYSTEMD_ANALYZE_EXIT=$?
    echo "    Exit code: $SYSTEMD_ANALYZE_EXIT"
    echo "    Output: $SYSTEMD_ANALYZE_OUTPUT"
    
    if [[ $SYSTEMD_ANALYZE_EXIT -eq 0 ]]; then
        BOOT_TIME=$(echo "$SYSTEMD_ANALYZE_OUTPUT" | grep -oE '[0-9]+[.][0-9]+s' | head -1)
        echo -e "  ${GREEN}✓${NC} boot-health collector: systemd-analyze works (boot: ${BOOT_TIME:-unknown})"
    else
        echo -e "  ${YELLOW}⚠${NC} boot-health collector: systemd-analyze returned exit code $SYSTEMD_ANALYZE_EXIT"
    fi
else
    echo -e "  ${RED}✗${NC} boot-health collector: systemd-analyze missing"
    REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
fi

# Check systemctl for service-manifest collector
echo "  Checking service-manifest collector prerequisites:"
if command -v systemctl; then
    echo "    Running: systemctl list-unit-files --no-legend (first 5 lines)"
    SYSTEMCTL_OUTPUT=$(systemctl list-unit-files --no-legend 2>&1 | head -5)
    SYSTEMCTL_EXIT=$?
    echo "    Exit code: $SYSTEMCTL_EXIT"
    echo "    First lines of output:"
    echo "$SYSTEMCTL_OUTPUT" | while read line; do echo "      $line"; done
    
    if [[ $SYSTEMCTL_EXIT -eq 0 ]]; then
        SERVICE_COUNT=$(systemctl list-unit-files --no-legend 2>&1 | wc -l)
        echo -e "  ${GREEN}✓${NC} service-manifest collector: systemctl works ($SERVICE_COUNT units)"
    else
        echo -e "  ${YELLOW}⚠${NC} service-manifest collector: systemctl list-unit-files failed"
    fi
fi

echo ""

# ============================================================
# Summary (RLM Layer 7 - Recursive Validation Result)
# ============================================================
echo "═══════════════════════════════════════════════════════════════"
echo "  DEPENDENCY CHECK SUMMARY"
echo "═══════════════════════════════════════════════════════════════"

if [[ $REQUIRED_FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}✓ All required dependencies satisfied${NC}"
else
    echo -e "  ${RED}✗ $REQUIRED_FAILED required dependency(s) missing${NC}"
fi

if [[ $OPTIONAL_MISSING -gt 0 ]]; then
    echo -e "  ${YELLOW}⚠ $OPTIONAL_MISSING optional dependency(s) missing (fallbacks available)${NC}"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Show the log file location
echo "Full verbose log saved to: $LOG_FILE"
echo ""

# Return appropriate exit code
if [[ $REQUIRED_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ Dependency check passed${NC}"
    exit 0
else
    echo -e "${RED}✗ Dependency check failed - install cannot proceed${NC}"
    echo "  Check $LOG_FILE for complete details"
    exit 1
fi