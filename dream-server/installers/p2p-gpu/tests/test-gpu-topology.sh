#!/usr/bin/env bash
# Regression: multi-GPU topology fallback uses safe nvidia-smi probes + correct split mode.
set -euo pipefail

if ! command -v jq &>/dev/null; then
  echo "jq is required for the topology regression test" >&2
  exit 1
fi

P2P_GPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB_DIR="$(mktemp -d -t p2p-gpu-stub.XXXXXX)"
trap 'rm -rf "$STUB_DIR"' EXIT

log() { :; }
warn() { :; }
err() { :; }
step() { :; }

# shellcheck source=../lib/environment.sh
source "${P2P_GPU_DIR}/lib/environment.sh"
# shellcheck source=../lib/gpu-topology.sh
source "${P2P_GPU_DIR}/lib/gpu-topology.sh"

_pin_nvidia_packages() { :; }

cat > "${STUB_DIR}/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario="${TEST_SCENARIO:-}"

if [[ "$*" == *"--query-gpu=name"* ]]; then
  case "$scenario" in
    four_nvlink)
      for _ in 0 1 2 3; do echo "NVIDIA A100"; done
      ;;
    eight_islands)
      for _ in 0 1 2 3; do echo "NVIDIA H100"; done
      for _ in 4 5 6 7; do echo "NVIDIA L40S"; done
      ;;
    eight_pcie_missing_vram)
      for _ in 0 1 2 3 4 5 6 7; do echo "NVIDIA A100"; done
      ;;
  esac
  exit 0
fi

if [[ "$*" == *"--query-gpu=memory.total"* ]]; then
  case "$scenario" in
    four_nvlink)
      for _ in 0 1 2 3; do echo "40000"; done
      ;;
    eight_islands)
      for _ in 0 1 2 3; do echo "40000"; done
      for _ in 4 5 6 7; do echo "24000"; done
      ;;
    eight_pcie_missing_vram)
      echo "40000"
      echo "40000"
      echo ""
      echo "40000"
      echo "40000"
      echo "40000"
      echo "40000"
      echo "40000"
      ;;
  esac
  exit 0
fi

if [[ "$*" == *"--query-gpu=gpu_uuid,memory.total,name"* ]]; then
  case "$scenario" in
    four_nvlink)
      for i in 0 1 2 3; do echo "GPU-$i, 40000, NVIDIA A100"; done
      ;;
    eight_islands)
      for i in 0 1 2 3; do echo "GPU-$i, 40000, NVIDIA H100"; done
      for i in 4 5 6 7; do echo "GPU-$i, 24000, NVIDIA L40S"; done
      ;;
    eight_pcie_missing_vram)
      echo "GPU-0, 40000, NVIDIA A100"
      echo "GPU-1, 40000, NVIDIA A100"
      echo "GPU-2, , NVIDIA A100"
      echo "GPU-3, 40000, NVIDIA A100"
      echo "GPU-4, 40000, NVIDIA A100"
      echo "GPU-5, 40000, NVIDIA A100"
      echo "GPU-6, 40000, NVIDIA A100"
      echo "GPU-7, 40000, NVIDIA A100"
      ;;
  esac
  exit 0
fi

if [[ "$1" == "topo" && "${2:-}" == "-m" ]]; then
  case "$scenario" in
    four_nvlink)
      cat <<'TOPO'
        GPU0 GPU1 GPU2 GPU3
GPU0     X   NV4  NV4  NV4
GPU1    NV4   X   NV4  NV4
GPU2    NV4  NV4   X   NV4
GPU3    NV4  NV4  NV4   X
TOPO
      ;;
    eight_islands)
      cat <<'TOPO'
        GPU0 GPU1 GPU2 GPU3 GPU4 GPU5 GPU6 GPU7
GPU0     X   NV4  NV4  NV4  PHB  PHB  PHB  PHB
GPU1    NV4   X   NV4  NV4  PHB  PHB  PHB  PHB
GPU2    NV4  NV4   X   NV4  PHB  PHB  PHB  PHB
GPU3    NV4  NV4  NV4   X   PHB  PHB  PHB  PHB
GPU4    PHB  PHB  PHB  PHB   X   NV4  NV4  NV4
GPU5    PHB  PHB  PHB  PHB  NV4   X   NV4  NV4
GPU6    PHB  PHB  PHB  PHB  NV4  NV4   X   NV4
GPU7    PHB  PHB  PHB  PHB  NV4  NV4  NV4   X
TOPO
      ;;
    eight_pcie_missing_vram)
      cat <<'TOPO'
        GPU0 GPU1 GPU2 GPU3 GPU4 GPU5 GPU6 GPU7
GPU0     X   PHB  PHB  PHB  PHB  PHB  PHB  PHB
GPU1    PHB   X   PHB  PHB  PHB  PHB  PHB  PHB
GPU2    PHB  PHB   X   PHB  PHB  PHB  PHB  PHB
GPU3    PHB  PHB  PHB   X   PHB  PHB  PHB  PHB
GPU4    PHB  PHB  PHB  PHB   X   PHB  PHB  PHB
GPU5    PHB  PHB  PHB  PHB  PHB   X   PHB  PHB
GPU6    PHB  PHB  PHB  PHB  PHB  PHB   X   PHB
GPU7    PHB  PHB  PHB  PHB  PHB  PHB  PHB   X
TOPO
      ;;
  esac
  exit 0
fi

exit 0
EOF

chmod +x "${STUB_DIR}/nvidia-smi"
export PATH="${STUB_DIR}:${PATH}"

count_csv() {
  local csv="$1" count=0
  local -a parts=()
  IFS=',' read -r -a parts <<< "$csv"
  for part in "${parts[@]}"; do
    part=$(echo "$part" | xargs)
    [[ -n "$part" ]] && count=$((count + 1))
  done
  echo "$count"
}

assert_eq() {
  local expected="$1" actual="$2" context="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "Expected ${context}=${expected}, got ${actual}" >&2
    exit 1
  fi
}

run_scenario() {
  local scenario="$1" model_size="$2" expected_gpu_count="$3" expected_split_mode="$4"
  local expected_llama_gpu_count="$5" expected_tensor_split_count="$6"

  export TEST_SCENARIO="$scenario"
  LOGFILE="$(mktemp -t p2p-gpu-topo.XXXXXX)"
  local env_file ds_dir
  env_file="$(mktemp -t p2p-gpu-env.XXXXXX)"
  ds_dir="$(mktemp -d -t p2p-gpu-ds.XXXXXX)"

  env_set "$env_file" "LLM_MODEL_SIZE_MB" "$model_size"

  unset GPU_UUIDS GPU_VRAMS GPU_NAMES
  detect_gpu
  assert_eq "$expected_gpu_count" "$GPU_COUNT" "${scenario} GPU_COUNT"
  enumerate_gpus

  run_gpu_assignment "$ds_dir" "$env_file"

  local split_mode
  split_mode="$(env_get "$env_file" "LLAMA_ARG_SPLIT_MODE")"
  assert_eq "$expected_split_mode" "$split_mode" "${scenario} split mode"

  local uuid_csv
  uuid_csv="$(env_get "$env_file" "LLAMA_SERVER_GPU_UUIDS")"
  assert_eq "$expected_llama_gpu_count" "$(count_csv "$uuid_csv")" "${scenario} llama gpu count"

  local tensor_split
  tensor_split="$(env_get "$env_file" "LLAMA_ARG_TENSOR_SPLIT")"
  if [[ "$expected_tensor_split_count" -eq 0 ]]; then
    if [[ -n "$tensor_split" ]]; then
      echo "Expected no tensor_split for ${scenario}, got '${tensor_split}'" >&2
      exit 1
    fi
  else
    assert_eq "$expected_tensor_split_count" "$(count_csv "$tensor_split")" "${scenario} tensor_split count"
  fi

  rm -f "$LOGFILE" "$env_file"
  rm -rf "$ds_dir"
}

run_scenario "four_nvlink" 64000 4 "tensor" 4 4
run_scenario "eight_islands" 120000 8 "tensor" 4 4
run_scenario "eight_pcie_missing_vram" 64000 8 "layer" 8 0
