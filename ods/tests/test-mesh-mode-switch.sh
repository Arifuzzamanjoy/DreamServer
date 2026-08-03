#!/usr/bin/env bash
# Contract: mode-switch.sh wires mesh mode to satisfy the ods-doctor mesh
# checks, and does not regress local/cloud.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "[PASS] ${label}"
    else
        echo "[FAIL] ${label}: expected '${expected}', got '${actual}'"
        FAILURES=$((FAILURES + 1))
    fi
}

env_value() {
    grep -m1 "^${1}=" "$2" | cut -d= -f2- | tr -d '"\047\r'
}

# mode-switch.sh resolves paths from its own location, so the fixture has to
# be a real tree rather than a bare .env.
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
mkdir -p "$workdir/scripts" "$workdir/extensions/services/litellm" \
         "$workdir/extensions/services/dreamreason"
cp "$SCRIPT_DIR/scripts/mode-switch.sh" "$workdir/scripts/"
touch "$workdir/extensions/services/litellm/compose.yaml.disabled"
touch "$workdir/extensions/services/dreamreason/compose.yaml.disabled"

cat >"$workdir/.env" <<'ENVEOF'
ODS_MODE=local
GPU_BACKEND=nvidia
LLM_BACKEND=llama-server
LLM_API_URL=http://llama-server:8080
HERMES_LLM_BASE_URL=http://llama-server:8080/v1
ENVEOF

echo "=== mesh mode wiring ==="
bash "$workdir/scripts/mode-switch.sh" mesh >/dev/null

check "ODS_MODE is mesh" "mesh" "$(env_value ODS_MODE "$workdir/.env")"
check "LLM_API_URL routes through LiteLLM" \
      "http://litellm:4000" "$(env_value LLM_API_URL "$workdir/.env")"
check "HERMES_LLM_BASE_URL routes through LiteLLM" \
      "http://litellm:4000/v1" "$(env_value HERMES_LLM_BASE_URL "$workdir/.env")"

if [[ -f "$workdir/extensions/services/dreamreason/compose.yaml" ]]; then
    echo "[PASS] dreamreason coordinator enabled for mesh"
else
    echo "[FAIL] dreamreason coordinator not enabled for mesh"
    FAILURES=$((FAILURES + 1))
fi

if [[ -f "$workdir/extensions/services/litellm/compose.yaml" ]]; then
    echo "[PASS] litellm gateway enabled for mesh"
else
    echo "[FAIL] litellm gateway not enabled for mesh"
    FAILURES=$((FAILURES + 1))
fi

echo "=== local mode is unchanged ==="
bash "$workdir/scripts/mode-switch.sh" local >/dev/null
check "local points back at llama-server" \
      "http://llama-server:8080" "$(env_value LLM_API_URL "$workdir/.env")"
check "local mode recorded" "local" "$(env_value ODS_MODE "$workdir/.env")"

echo "=== cloud mode still uses the gateway ==="
bash "$workdir/scripts/mode-switch.sh" cloud >/dev/null
check "cloud routes through LiteLLM" \
      "http://litellm:4000" "$(env_value LLM_API_URL "$workdir/.env")"

if [[ "$FAILURES" -gt 0 ]]; then
    echo ""
    echo "${FAILURES} check(s) failed"
    exit 1
fi

echo ""
echo "[OK] mesh mode-switch contract holds"
