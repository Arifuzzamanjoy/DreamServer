#!/usr/bin/env bash
# Regression: cover p2p-gpu installer fixes for context floor and model sync.
set -euo pipefail

P2P_GPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGFILE="$(mktemp -t p2p-gpu-regressions.XXXXXX)"
TEST_ROOT="$(mktemp -d -t p2p-gpu-regressions.XXXXXX)"
trap 'rm -f "$LOGFILE"; rm -rf "$TEST_ROOT"' EXIT

# Minimal logging functions expected by sourced helpers.
log() { :; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERR] $*" >&2; }
step() { :; }

# shellcheck source=../lib/environment.sh
source "${P2P_GPU_DIR}/lib/environment.sh"

# Helper: derive model name from GGUF filename.
_derive_llm_model() {
  echo "$1" \
    | sed -E 's/\.(gguf|GGUF)$//' \
    | sed -E 's/-Q[0-9]+([._][A-Za-z0-9]+)*$//' \
    | tr '[:upper:]' '[:lower:]'
}

make_env() {
  local path="$1"
  cat > "$path" << 'EOF'
CTX_SIZE=131072
LLM_MODEL_SIZE_MB=28000
LLAMA_ARG_CACHE_TYPE_K=f16
LLAMA_ARG_CACHE_TYPE_V=f16
EOF
}

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: ${msg}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

test_context_floor() {
  echo "Test 1: Low VRAM (headroom ≤ 0) should enforce MIN_AGENT_CTX floor"
  local env_dir="${TEST_ROOT}/context-floor"
  mkdir -p "$env_dir"
  make_env "${env_dir}/.env"

  export GPU_BACKEND="nvidia"
  export GPU_VRAM=24576
  export GPU_TOTAL_VRAM=24576
  export GPU_COUNT=1
  unset GPU_VRAMS

  # 28 GB model on 24 GB GPU => negative headroom.
  env_set "${env_dir}/.env" "LLM_MODEL_SIZE_MB" "28000"
  _cap_context_for_vram "$env_dir"

  assert_eq "8192" "$(env_get "${env_dir}/.env" "CTX_SIZE")" "CTX_SIZE floor"
  echo "  ✓ CTX_SIZE correctly set to 8192"

  echo "Test 2: Very tight VRAM (~2 GB headroom) should use 8192 minimum"
  local env_dir2="${TEST_ROOT}/context-tight"
  mkdir -p "$env_dir2"
  make_env "${env_dir2}/.env"

  export GPU_VRAM=20480
  export GPU_TOTAL_VRAM=20480
  # 18 GB model on 20 GB GPU => ~1 GB headroom, still below the agent-safe floor.
  env_set "${env_dir2}/.env" "LLM_MODEL_SIZE_MB" "18432"
  _cap_context_for_vram "$env_dir2"

  assert_eq "8192" "$(env_get "${env_dir2}/.env" "CTX_SIZE")" "CTX_SIZE tight VRAM"
  echo "  ✓ CTX_SIZE correctly set to 8192 for very tight VRAM"

  echo "Test 3: Generous VRAM (>16 GB headroom) should allow full context"
  local env_dir3="${TEST_ROOT}/context-large"
  mkdir -p "$env_dir3"
  make_env "${env_dir3}/.env"

  export GPU_VRAM=81920
  export GPU_TOTAL_VRAM=81920
  env_set "${env_dir3}/.env" "LLM_MODEL_SIZE_MB" "28000"
  _cap_context_for_vram "$env_dir3"

  assert_eq "131072" "$(env_get "${env_dir3}/.env" "CTX_SIZE")" "CTX_SIZE generous VRAM"
  echo "  ✓ CTX_SIZE correctly set to 131072 for generous VRAM"
}

test_model_consistency() {
  echo "Test 4: Bootstrap model GGUF_FILE and LLM_MODEL should match"
  local env_dir="${TEST_ROOT}/model-bootstrap"
  mkdir -p "$env_dir"
  cat > "${env_dir}/.env" << 'EOF'
GGUF_FILE=Qwen3-0.6B-Q4_K_M.gguf
LLM_MODEL=qwen3-0.6b
LLM_MODEL_SIZE_MB=400
EOF

  local gguf derived llm_model
  gguf="$(env_get "${env_dir}/.env" "GGUF_FILE")"
  llm_model="$(env_get "${env_dir}/.env" "LLM_MODEL")"
  derived="$(_derive_llm_model "$gguf")"
  assert_eq "$derived" "$llm_model" "bootstrap model derivation"
  echo "  ✓ LLM_MODEL matches derived name: $derived"

  echo "Test 5: After simulated hot-swap, LLM_MODEL should match new GGUF_FILE"
  local env_dir2="${TEST_ROOT}/model-swap"
  mkdir -p "$env_dir2"
  cat > "${env_dir2}/.env" << 'EOF'
GGUF_FILE=Qwen3-0.6B-Q4_K_M.gguf
LLM_MODEL=qwen3-0.6b
LLM_MODEL_SIZE_MB=400
EOF

  local new_gguf="Llama2-7B-GGUF-Q5_K_M.gguf"
  local new_llm_model new_size_mb gguf_after llm_model_after size_after derived_after
  new_llm_model="$(_derive_llm_model "$new_gguf")"
  new_size_mb=4096

  env_set "${env_dir2}/.env" "GGUF_FILE" "$new_gguf"
  env_set "${env_dir2}/.env" "LLM_MODEL" "$new_llm_model"
  env_set "${env_dir2}/.env" "LLM_MODEL_SIZE_MB" "$new_size_mb"

  gguf_after="$(env_get "${env_dir2}/.env" "GGUF_FILE")"
  llm_model_after="$(env_get "${env_dir2}/.env" "LLM_MODEL")"
  size_after="$(env_get "${env_dir2}/.env" "LLM_MODEL_SIZE_MB")"
  derived_after="$(_derive_llm_model "$gguf_after")"

  assert_eq "$new_gguf" "$gguf_after" "GGUF_FILE after swap"
  assert_eq "$new_llm_model" "$llm_model_after" "LLM_MODEL after swap"
  assert_eq "$new_size_mb" "$size_after" "LLM_MODEL_SIZE_MB after swap"
  assert_eq "$derived_after" "$llm_model_after" "derived name after swap"
  echo "  ✓ Hot-swap kept GGUF_FILE, LLM_MODEL, and LLM_MODEL_SIZE_MB in sync"

  echo "Test 6: Various model GGUF filenames should derive correctly"
  local test_case gguf_name expected derived_name
  declare -a test_cases=(
    "Qwen3-30B-A3B-Q4_K_M.gguf:qwen3-30b-a3b"
    "Llama2-70B-Q5_K_M.gguf:llama2-70b"
    "MixtralMoE-8x7B-Q3_K_S.gguf:mixtralmoe-8x7b"
    "phi-2-GGUF.gguf:phi-2-gguf"
  )

  for test_case in "${test_cases[@]}"; do
    gguf_name="${test_case%:*}"
    expected="${test_case#*:}"
    derived_name="$(_derive_llm_model "$gguf_name")"
    assert_eq "$expected" "$derived_name" "$gguf_name derivation"
    echo "  ✓ $gguf_name → $derived_name"
  done
}

test_context_floor
test_model_consistency

echo ""
echo "All p2p-gpu regression tests passed!"
