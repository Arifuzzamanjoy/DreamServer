#!/bin/bash
# ============================================================================
# Dream Server Windows report command tests
# ============================================================================
# Static checks for the Windows dream.ps1 "report" command wiring.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DREAM_PS1="$ROOT_DIR/installers/windows/dream.ps1"
REPORT_LIB="$ROOT_DIR/installers/windows/lib/install-report.ps1"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Windows report command tests ==="
echo ""

[[ -f "$DREAM_PS1" ]] && pass "dream.ps1 exists" || fail "dream.ps1 missing"
[[ -f "$REPORT_LIB" ]] && pass "install-report.ps1 exists" || fail "install-report.ps1 missing"

grep -q "install-report.ps1" "$DREAM_PS1" && pass "dream.ps1 sources report library" || fail "dream.ps1 missing report library source"
grep -q "function Invoke-Report" "$DREAM_PS1" && pass "Invoke-Report function exists" || fail "Invoke-Report function missing"
grep -q '"report"  { Invoke-Report }' "$DREAM_PS1" && pass "report command dispatch exists" || fail "report command dispatch missing"
grep -q "Generate Windows diagnostics bundle" "$DREAM_PS1" && pass "help text includes report command" || fail "help text missing report command"

grep -q "function Write-DreamInstallReport" "$REPORT_LIB" && pass "report writer function exists" || fail "report writer function missing"
grep -q "windows-report" "$REPORT_LIB" && pass "report output path is defined" || fail "report output path missing"

echo ""
echo "Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
