#!/usr/bin/env bash
# verify-complete.sh — Complete RLM validation suite with Layer 3.5 value sanity
# Fixes Issue 2 from video: Boot times showing 0.0s

set -euo pipefail

DB_PATH="${SYSTEM_INSPECTOR_DB:-/var/lib/sys-inspector/sys-inspector.db}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  SYS-INSPECTOR RLM VALIDATION SUITE (Layers 0-3.5)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

PASS=0
FAIL=0
WARN=0

verify_layer_0() {
    echo -e "${BLUE}[Layer 0]${NC} Directory structure"
    local ok=0
    if [[ -d "/var/lib/sys-inspector" ]]; then
        echo -e "  ${GREEN}✓${NC} DB directory exists"
        ((ok++))
    else
        echo -e "  ${RED}✗${NC} DB directory missing"
    fi
    
    if [[ -d "/var/log/sys-inspector" ]]; then
        echo -e "  ${GREEN}✓${NC} Log directory exists"
        ((ok++))
    else
        echo -e "  ${RED}✗${NC} Log directory missing"
    fi
    
    if [[ $ok -eq 2 ]]; then
        ((PASS++))
        return 0
    else
        ((FAIL++))
        return 1
    fi
}

verify_layer_1() {
    echo -e "${BLUE}[Layer 1]${NC} Database file"
    if [[ -f "$DB_PATH" ]]; then
        local size=$(du -h "$DB_PATH" | cut -f1)
        echo -e "  ${GREEN}✓${NC} Database file exists (size: $size)"
        ((PASS++))
        return 0
    else
        echo -e "  ${RED}✗${NC} Database file missing at $DB_PATH"
        ((FAIL++))
        return 1
    fi
}

verify_layer_2() {
    echo -e "${BLUE}[Layer 2]${NC} Required tables"
    local tables=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null)
    local ok=0
    
    for table in boot_health resource_samples service_manifest error_log shutdown_capture; do
        if echo "$tables" | grep -q "^$table$"; then
            echo -e "  ${GREEN}✓${NC} $table"
            ((ok++))
        else
            echo -e "  ${RED}✗${NC} $table MISSING"
        fi
    done
    
    if [[ $ok -eq 5 ]]; then
        ((PASS++))
        return 0
    else
        ((FAIL++))
        return 1
    fi
}

verify_layer_3() {
    echo -e "${BLUE}[Layer 3]${NC} Schema correctness"
    local columns=$(sqlite3 "$DB_PATH" "PRAGMA table_info(resource_samples);" 2>/dev/null | wc -l)
    
    if [[ $columns -ge 10 ]]; then
        echo -e "  ${GREEN}✓${NC} resource_samples has $columns columns"
        ((PASS++))
        return 0
    else
        echo -e "  ${RED}✗${NC} resource_samples incomplete ($columns columns, expected >=10)"
        ((FAIL++))
        return 1
    fi
}

# RLM Layer 3.5: Data validity (Fixes Issue 2 from video)
verify_layer_3_5() {
    echo -e "${BLUE}[Layer 3.5]${NC} Data validity (value sanity)"
    local issues=0
    
    # Check boot health has non-zero times
    local total_boots=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM boot_health;" 2>/dev/null || echo "0")
    if [[ "$total_boots" -gt 0 ]]; then
        local zero_boots=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM boot_health WHERE total_ms IS NULL OR total_ms = 0;" 2>/dev/null || echo "0")
        local positive_boots=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM boot_health WHERE total_ms > 0;" 2>/dev/null || echo "0")
        
        if [[ "$zero_boots" -eq "$total_boots" ]]; then
            echo -e "  ${YELLOW}⚠${NC} WARNING: All $total_boots boot records show 0ms - collector may be broken"
            echo -e "     ACTION: Check 'systemd-analyze time' output format"
            ((issues++))
            ((WARN++))
        elif [[ "$zero_boots" -gt 0 ]]; then
            echo -e "  ${YELLOW}⚠${NC} $zero_boots of $total_boots boot records show 0ms ($positive_boots valid)"
            ((issues++))
            ((WARN++))
        else
            echo -e "  ${GREEN}✓${NC} Boot times have valid data ($total_boots records, all >0ms)"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} No boot records found - run boot-health collector"
        ((WARN++))
    fi
    
    # Check manifest freshness
    local last_manifest=$(sqlite3 "$DB_PATH" "SELECT MAX(collected_at) FROM service_manifest;" 2>/dev/null)
    if [[ -n "$last_manifest" && "$last_manifest" != "null" && "$last_manifest" != "" ]]; then
        local last_epoch=$(date -d "$last_manifest" +%s 2>/dev/null || echo 0)
        local now_epoch=$(date +%s)
        local hours_ago=$(( (now_epoch - last_epoch) / 3600 ))
        if [[ $hours_ago -gt 24 ]]; then
            echo -e "  ${YELLOW}⚠${NC} Manifest data is $hours_ago hours old - consider running collector"
            ((WARN++))
        elif [[ $hours_ago -gt 1 ]]; then
            echo -e "  ${GREEN}✓${NC} Manifest data is $hours_ago hours old"
        else
            echo -e "  ${GREEN}✓${NC} Manifest data is fresh (<1 hour old)"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} No manifest data found - run service-manifest collector"
        ((WARN++))
    fi
    
    # Check resource_samples
    local samples=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM resource_samples;" 2>/dev/null || echo "0")
    if [[ "$samples" -eq 0 ]]; then
        echo -e "  ${YELLOW}⚠${NC} No resource samples found - run contention-alert collector"
        ((WARN++))
    else
        echo -e "  ${GREEN}✓${NC} $samples resource samples available"
    fi
    
    if [[ $issues -eq 0 ]]; then
        ((PASS++))
        return 0
    else
        return 1
    fi
}

# Summary
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  VALIDATION SUMMARY"
echo "═══════════════════════════════════════════════════════════════"
echo ""

verify_layer_0
verify_layer_1
verify_layer_2
verify_layer_3
verify_layer_3_5

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo -e "  RESULTS: ${GREEN}$PASS passed${NC} | ${RED}$FAIL failed${NC} | ${YELLOW}$WARN warnings${NC}"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}✓ All RLM validation layers passed${NC}"
    exit 0
else
    echo -e "${RED}✗ Some validation layers failed - see above${NC}"
    exit 1
fi