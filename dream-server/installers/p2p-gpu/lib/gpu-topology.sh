#!/usr/bin/env bash
# ============================================================================
# DreamServer — P2P GPU Topology & Multi-GPU Assignment
# ============================================================================
# Part of: dream-server/installers/p2p-gpu/lib/
# Purpose: Per-GPU enumeration, topology detection (NVLink/PCIe),
#          GPU-to-service assignment delegation, env var writing
#
# Expects: GPU_BACKEND, GPU_COUNT, GPU_VRAM, LOGFILE,
#          log(), warn(), err(), env_set(), env_get()
# Provides: enumerate_gpus(), generate_topology_json(),
#           run_gpu_assignment()
#
# Modder notes:
#   All functions are no-ops when GPU_COUNT < 2. Single-GPU path is untouched.
#   Prefers upstream assign_gpus.py + nvidia-topo.sh when available;
#   built-in fallback handles pre-clone state.
#   GPU_UUIDS, GPU_VRAMS, GPU_NAMES are indexed arrays (not associative).
#
# SPDX-License-Identifier: Apache-2.0
# ============================================================================

set -euo pipefail

# ── Per-GPU enumeration ──────────────────────────────────────────────────────
# Populates: GPU_UUIDS[], GPU_VRAMS[] (MiB each), GPU_NAMES[], GPU_TOTAL_VRAM
enumerate_gpus() {
  [[ "${GPU_COUNT:-0}" -lt 2 ]] && return 0

  GPU_UUIDS=()
  GPU_VRAMS=()
  GPU_NAMES=()
  GPU_TOTAL_VRAM=0

  if [[ "${GPU_BACKEND:-}" == "nvidia" ]]; then
    local query_out
    query_out=$(nvidia-smi --query-gpu=gpu_uuid,memory.total,name \
      --format=csv,noheader,nounits 2>>"$LOGFILE" || echo "")
    if [[ -z "$query_out" ]]; then
      warn "nvidia-smi GPU enumeration returned no data (non-fatal)"
    fi
    while IFS=',' read -r uuid vram name; do
      uuid=$(echo "$uuid" | xargs)
      vram=$(echo "$vram" | xargs)
      name=$(echo "$name" | xargs)
      [[ -z "$uuid" ]] && continue
      local vram_mb=""
      if [[ "$vram" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        vram_mb="${vram%%.*}"
      else
        warn "Missing VRAM for GPU ${uuid} (non-fatal)"
      fi
      [[ -z "$name" ]] && name="NVIDIA GPU"
      GPU_UUIDS+=("$uuid")
      GPU_VRAMS+=("$vram_mb")
      GPU_NAMES+=("$name")
      [[ -n "$vram_mb" ]] && GPU_TOTAL_VRAM=$(( GPU_TOTAL_VRAM + vram_mb ))
    # [NON-FATAL: probe] Topology is best-effort; fallback uses env values.
    done <<< "$query_out"

  elif [[ "${GPU_BACKEND:-}" == "amd" ]]; then
    local idx=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local gpu_name
      gpu_name=$(rocm-smi -d "$idx" --showproductname 2>>"$LOGFILE" \
        | grep -oP 'Card series:\s*\K.*' || echo "AMD GPU $idx")
      local vram_bytes
      vram_bytes=$(rocm-smi -d "$idx" --showmeminfo vram 2>>"$LOGFILE" \
        | grep -oP 'Total Memory \(B\):\s*\K[0-9]+' || echo "0")
      local vram_mb=$(( vram_bytes / 1048576 ))
      [[ $vram_mb -lt 1000 ]] && vram_mb=${GPU_VRAM:-0}  # fallback

      GPU_UUIDS+=("AMD-GPU-${idx}")
      GPU_VRAMS+=("$vram_mb")
      GPU_NAMES+=("$gpu_name")
      GPU_TOTAL_VRAM=$(( GPU_TOTAL_VRAM + vram_mb ))
      idx=$((idx + 1))
    done < <(rocm-smi --showid 2>>"$LOGFILE" | grep 'GPU\[' || echo "")
  fi

  # Sanity: if enumeration failed, fall back to count * per-GPU
  if [[ ${#GPU_UUIDS[@]} -eq 0 ]]; then
    GPU_TOTAL_VRAM=$(( ${GPU_VRAM:-0} * ${GPU_COUNT:-1} ))
    warn "GPU enumeration failed — estimated total VRAM: ${GPU_TOTAL_VRAM} MiB"
  fi
}

# ── Topology JSON generation ─────────────────────────────────────────────────
# Builds JSON matching upstream assign_gpus.py input schema.
# Args: $1 = output file path
generate_topology_json() {
  local output_file="$1"
  [[ "${GPU_COUNT:-0}" -lt 2 ]] && return 0

  # Strategy 1: Use upstream nvidia-topo.sh if cloned
  if [[ -n "${DS_DIR:-}" && -f "${DS_DIR}/installers/lib/nvidia-topo.sh" \
        && "${GPU_BACKEND:-}" == "nvidia" ]]; then
    local upstream_topo
    upstream_topo=$(
      # Source upstream functions in subshell
      warn() { echo "WARN: $*" >&2; }
      err()  { echo "ERR: $*" >&2; }
      source "${DS_DIR}/installers/lib/nvidia-topo.sh" 2>>"$LOGFILE"
      detect_nvidia_topo 2>>"$LOGFILE"
    ) || upstream_topo=""
    if [[ -n "$upstream_topo" && "$upstream_topo" != "{}" ]]; then
      echo "$upstream_topo" > "$output_file"
      log "Topology generated via upstream nvidia-topo.sh"
      return 0
    fi
  fi

  # Strategy 2: Built-in — enumerate GPUs + parse topo matrix
  _generate_builtin_topology "$output_file"
}

_generate_builtin_topology() {
  local output_file="$1"

  # Build gpus array
  local gpus_json="["
  for i in "${!GPU_UUIDS[@]}"; do
    local mem_gb
    local vram_mb="${GPU_VRAMS[$i]:-0}"
    if [[ ! "$vram_mb" =~ ^[0-9]+$ ]]; then
      vram_mb=0
    fi
    mem_gb=$(awk "BEGIN {printf \"%.1f\", ${vram_mb} / 1024}")
    local gpu_name="${GPU_NAMES[$i]:-}"
    [[ -z "$gpu_name" ]] && gpu_name="GPU ${i}"
    [[ $i -gt 0 ]] && gpus_json+=","
    gpus_json+="{\"index\":${i},\"uuid\":\"${GPU_UUIDS[$i]}\",\"name\":\"${gpu_name}\",\"memory_gb\":${mem_gb}}"
  done
  gpus_json+="]"

  # Build links array from nvidia-smi topo -m
  local links_json="[]"
  if [[ "${GPU_BACKEND:-}" == "nvidia" ]]; then
    links_json=$(_parse_nvidia_topo_links)
  fi

  cat > "$output_file" << TOPO_EOF
{
  "vendor": "${GPU_BACKEND:-unknown}",
  "gpu_count": ${#GPU_UUIDS[@]},
  "gpus": ${gpus_json},
  "links": ${links_json}
}
TOPO_EOF

  log "Topology generated (built-in): ${#GPU_UUIDS[@]} GPUs"
}

_parse_nvidia_topo_links() {
  # Parse nvidia-smi topo -m matrix into JSON links array
  local matrix
  matrix=$(nvidia-smi topo -m 2>>"$LOGFILE") || { echo "[]"; return; }

  # Strip ANSI escape codes
  matrix=$(echo "$matrix" | sed 's/\x1b\[[0-9;]*m//g')

  local header_line
  header_line=$(echo "$matrix" | grep -E '^\s+GPU[0-9]' | head -1 || echo "")
  [[ -z "$header_line" ]] && { echo "[]"; return; }

  local -a headers
  read -ra headers <<< "$header_line"

  local links="["
  local first=true

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]] ]] && continue
    [[ -z "$line" ]] && continue
    local row_label
    row_label=$(echo "$line" | awk '{print $1}')
    [[ "$row_label" =~ ^GPU[0-9]+$ ]] || continue
    local gpu_a="${row_label#GPU}"
    local -a cells
    read -ra cells <<< "$line"

    for col_idx in "${!headers[@]}"; do
      local col_header="${headers[$col_idx]}"
      [[ "$col_header" =~ ^GPU[0-9]+$ ]] || continue
      local gpu_b="${col_header#GPU}"
      [[ "$gpu_a" -ge "$gpu_b" ]] && continue  # upper triangle only

      local cell_idx=$(( col_idx + 1 ))  # +1 for row label
      local link_type="${cells[$cell_idx]:-X}"
      [[ "$link_type" == "X" ]] && continue  # self

      local rank
      rank=$(_link_rank "$link_type")
      local label
      label=$(_link_label "$link_type")

      [[ "$first" != "true" ]] && links+=","
      first=false
      links+="{\"gpu_a\":${gpu_a},\"gpu_b\":${gpu_b},\"link_type\":\"${link_type}\",\"link_label\":\"${label}\",\"rank\":${rank}}"
    done
  done <<< "$matrix"

  links+="]"
  echo "$links"
}

# Link rank/label matching upstream nvidia-topo.sh
_link_rank() {
  case "$1" in
    NV4|NV6|NV8|NV12|NV18) echo 100 ;;
    XGMI|XGMI2)            echo 90  ;;
    NV1|NV2|NV3)            echo 80  ;;
    MIG)                    echo 70  ;;
    PIX)                    echo 50  ;;
    PXB)                    echo 40  ;;
    PHB)                    echo 30  ;;
    NODE)                   echo 20  ;;
    SYS|SOC)                echo 10  ;;
    *)                      echo 0   ;;
  esac
}

_link_label() {
  case "$1" in
    NV*)   echo "NVLink" ;;
    XGMI*) echo "InfinityFabric" ;;
    MIG)   echo "MIG-SameDie" ;;
    PIX)   echo "PCIe-SameSwitch" ;;
    PXB)   echo "PCIe-CrossSwitch" ;;
    PHB)   echo "PCIe-HostBridge" ;;
    NODE)  echo "SameNUMA-NoBridge" ;;
    SYS|SOC) echo "CrossNUMA" ;;
    *)     echo "Unknown" ;;
  esac
}

# ── GPU-to-service assignment ─────────────────────────────────────────────────
# Args: $1 = ds_dir, $2 = env_file
run_gpu_assignment() {
  local ds_dir="$1" env_file="$2"
  [[ "${GPU_COUNT:-0}" -lt 2 ]] && return 0

  if [[ "${GPU_UUIDS+set}" != "set" ]]; then
    enumerate_gpus
  elif [[ "${#GPU_UUIDS[@]}" -eq 0 ]]; then
    enumerate_gpus
  fi

  local topo_file="/tmp/ds-gpu-topo-$$.json"
  generate_topology_json "$topo_file"
  [[ ! -f "$topo_file" ]] && { warn "Topology file not generated — skipping assignment"; return 0; }

  local model_size_mb
  model_size_mb=$(env_get "$env_file" "LLM_MODEL_SIZE_MB")
  model_size_mb="${model_size_mb:-${TIER_MODEL_SIZE_MB:-5760}}"

  local assign_script="${ds_dir}/scripts/assign_gpus.py"
  local result=""

  # Strategy 1: Upstream assign_gpus.py
  if [[ -f "$assign_script" ]] && command -v python3 &>/dev/null; then
    result=$(python3 "$assign_script" \
      --topology "$topo_file" \
      --model-size "$model_size_mb" 2>&1) || {
      warn "assign_gpus.py failed: ${result}"
      result=""
    }
  fi

  if [[ -n "$result" ]] && echo "$result" | jq -e '.gpu_assignment' &>/dev/null; then
    _write_assignment_from_json "$result" "$env_file"
    log "GPU assignment via upstream assign_gpus.py"
  else
    # Strategy 2: Built-in fallback — topology-driven llama assignment
    _write_builtin_assignment "$env_file" "$model_size_mb" "$topo_file"
    log "GPU assignment via built-in fallback (topology-driven)"
  fi

  # Save topology for dashboard-api
  mkdir -p "${ds_dir}/config"
  # [NON-FATAL: telemetry] Topology persistence only aids dashboard visibility.
  cp "$topo_file" "${ds_dir}/config/gpu-topology.json" 2>>"$LOGFILE" || warn "failed to persist gpu-topology.json (non-fatal)"
  # [NON-FATAL: telemetry] Topology persistence only aids dashboard visibility.
  chmod 644 "${ds_dir}/config/gpu-topology.json" 2>>"$LOGFILE" || warn "failed to set mode on gpu-topology.json (non-fatal)"

  # Enable P2P transfers when NVLink detected (avoids host RAM round-trip)
  local nvlink_present=false
  if [[ -f "$topo_file" ]] && jq -e '.links[] | select(.link_type | startswith("NV"))' "$topo_file" &>/dev/null; then
    nvlink_present=true
    env_set "$env_file" "GGML_CUDA_P2P" "1"
    log "NVLink detected — enabled GGML_CUDA_P2P for direct GPU-to-GPU transfers"
  else
    env_unset "$env_file" "GGML_CUDA_P2P"
  fi

  # NCCL hints for >2 GPUs with NVLink islands (only when NCCL is available in the image)
  if [[ "$nvlink_present" == "true" && "${GPU_BACKEND:-}" == "nvidia" && "${GPU_COUNT:-0}" -gt 2 ]]; then
    env_set "$env_file" "NCCL_P2P_LEVEL" "NVL"
    env_set "$env_file" "NCCL_P2P_DISABLE" "0"
    log "NVLink islands detected — set NCCL_P2P_LEVEL=NVL for multi-GPU tensor reductions"
  else
    env_unset "$env_file" "NCCL_P2P_LEVEL"
    env_unset "$env_file" "NCCL_P2P_DISABLE"
  fi

  rm -f "$topo_file"
}

_count_csv_items() {
  local csv="$1" count=0
  local -a parts=()
  IFS=',' read -r -a parts <<< "$csv"
  for part in "${parts[@]}"; do
    part=$(echo "$part" | xargs)
    [[ -n "$part" ]] && count=$((count + 1))
  done
  echo "$count"
}

_set_tensor_split_if_valid() {
  local env_file="$1" split="$2" expected="$3" reason="$4"
  if [[ -z "$split" ]]; then
    env_unset "$env_file" "LLAMA_ARG_TENSOR_SPLIT"
    return 0
  fi
  local count
  count=$(_count_csv_items "$split")
  if [[ "$count" -ne "$expected" ]]; then
    warn "Skipping LLAMA_ARG_TENSOR_SPLIT (${reason}): expected ${expected} entries, got ${count}"
    env_unset "$env_file" "LLAMA_ARG_TENSOR_SPLIT"
    return 0
  fi
  env_set "$env_file" "LLAMA_ARG_TENSOR_SPLIT" "$split"
}

_get_nvlink_islands() {
  local topo_file="$1"
  local gpu_count
  gpu_count=$(jq -r '.gpu_count // (.gpus | length) // 0' "$topo_file" 2>>"$LOGFILE" || echo 0)
  [[ "$gpu_count" -lt 2 ]] && return 0

  local -a parent=()
  local i
  for ((i=0; i<gpu_count; i++)); do
    parent[$i]=$i
  done

  local pairs
  pairs=$(jq -r '.links[] | select(.link_type | startswith("NV")) | "\(.gpu_a) \(.gpu_b)"' \
    "$topo_file" 2>>"$LOGFILE" || echo "")

  _nvlink_find_root() {
    local node="$1"
    local root="${parent[$node]}"
    while [[ "$root" != "$node" ]]; do
      node="$root"
      root="${parent[$node]}"
    done
    echo "$root"
  }

  local pair_a pair_b root_a root_b
  while read -r pair_a pair_b; do
    [[ -z "$pair_a" || -z "$pair_b" ]] && continue
    root_a=$(_nvlink_find_root "$pair_a")
    root_b=$(_nvlink_find_root "$pair_b")
    [[ "$root_a" != "$root_b" ]] && parent[$root_b]="$root_a"
  done <<< "$pairs"

  declare -A islands=()
  local root
  for ((i=0; i<gpu_count; i++)); do
    root=$(_nvlink_find_root "$i")
    islands["$root"]="${islands[$root]:-} $i"
  done

  for root in "${!islands[@]}"; do
    local list="${islands[$root]}"
    local count
    count=$(echo "$list" | awk '{print NF}')
    if [[ "$count" -gt 1 ]]; then
      echo "${list# }"
    fi
  done
}

_island_nvlink_rank() {
  local topo_file="$1" island="$2"
  declare -A in_island=()
  local idx
  for idx in $island; do
    in_island["$idx"]=1
  done

  local rank_sum=0
  local links
  links=$(jq -r '.links[] | select(.link_type | startswith("NV")) | "\(.gpu_a) \(.gpu_b) \(.rank)"' \
    "$topo_file" 2>>"$LOGFILE" || echo "")
  local a b rank
  while read -r a b rank; do
    [[ -z "$a" || -z "$b" || -z "$rank" ]] && continue
    if [[ -n "${in_island[$a]:-}" && -n "${in_island[$b]:-}" ]]; then
      [[ "$rank" =~ ^[0-9]+$ ]] && rank_sum=$((rank_sum + rank))
    fi
  done <<< "$links"
  echo "$rank_sum"
}

_select_builtin_llama_gpus() {
  local topo_file="$1" model_size_mb="$2"
  BUILTIN_LLAMA_SPLIT_MODE="layer"
  BUILTIN_LLAMA_INDICES=()

  local gpu_count="${#GPU_UUIDS[@]}"
  local -a all_indices=()
  local i
  for ((i=0; i<gpu_count; i++)); do
    all_indices+=("$i")
  done
  BUILTIN_LLAMA_INDICES=("${all_indices[@]}")

  [[ "$gpu_count" -lt 2 ]] && { BUILTIN_LLAMA_SPLIT_MODE="none"; return 0; }
  [[ "${GPU_BACKEND:-}" != "nvidia" ]] && return 0

  local -a islands=()
  mapfile -t islands < <(_get_nvlink_islands "$topo_file")
  [[ "${#islands[@]}" -eq 0 ]] && return 0

  local best_island="" best_count=0 best_vram=0 best_rank=0 best_homogeneous="false"
  local island
  for island in "${islands[@]}"; do
    local -a idxs=()
    read -r -a idxs <<< "$island"
    local count="${#idxs[@]}"
    local total_vram=0
    local island_rank=0
    local homogeneous="true"
    local ref_name="" ref_vram=""
    local idx
    for idx in "${idxs[@]}"; do
      local name="${GPU_NAMES[$idx]:-unknown}"
      local vram="${GPU_VRAMS[$idx]:-unknown}"
      [[ -z "$ref_name" ]] && ref_name="$name"
      [[ -z "$ref_vram" ]] && ref_vram="$vram"
      [[ "$name" != "$ref_name" ]] && homogeneous="false"
      [[ "$vram" != "$ref_vram" ]] && homogeneous="false"
      [[ "$vram" =~ ^[0-9]+$ ]] && total_vram=$((total_vram + vram))
    done
    island_rank=$(_island_nvlink_rank "$topo_file" "$island")

    if [[ "$homogeneous" == "true" ]]; then
      if [[ "$best_homogeneous" != "true" || "$count" -gt "$best_count" \
        || ( "$count" -eq "$best_count" && "$island_rank" -gt "$best_rank" ) \
        || ( "$count" -eq "$best_count" && "$island_rank" -eq "$best_rank" && "$total_vram" -gt "$best_vram" ) ]]; then
        best_island="$island"
        best_count="$count"
        best_vram="$total_vram"
        best_rank="$island_rank"
        best_homogeneous="true"
      fi
    elif [[ "$best_homogeneous" != "true" ]]; then
      if [[ "$count" -gt "$best_count" || ( "$count" -eq "$best_count" && "$island_rank" -gt "$best_rank" ) \
        || ( "$count" -eq "$best_count" && "$island_rank" -eq "$best_rank" && "$total_vram" -gt "$best_vram" ) ]]; then
        best_island="$island"
        best_count="$count"
        best_vram="$total_vram"
        best_rank="$island_rank"
      fi
    fi
  done

  if [[ -z "$best_island" ]]; then
    BUILTIN_LLAMA_SPLIT_MODE="layer"
    BUILTIN_LLAMA_INDICES=("${all_indices[@]}")
    return 0
  fi

  if [[ "$model_size_mb" =~ ^[0-9]+$ && "$best_vram" -gt 0 && "$best_vram" -lt "$model_size_mb" ]]; then
    BUILTIN_LLAMA_SPLIT_MODE="layer"
    BUILTIN_LLAMA_INDICES=("${all_indices[@]}")
    return 0
  fi

  read -r -a BUILTIN_LLAMA_INDICES <<< "$best_island"
  BUILTIN_LLAMA_SPLIT_MODE="tensor"
}

_map_llama_split_mode() {
  case "${1:-}" in
    ""|none|null) echo "none" ;;
    # PR #19378: split-mode tensor is backend-agnostic; row is deprecated legacy.
    tensor|hybrid) echo "tensor" ;;
    pipeline) echo "layer" ;;
    layer|row) echo "$1" ;;
    *)
      warn "Unknown split mode '${1}' from assign_gpus.py; defaulting to layer"
      echo "layer"
      ;;
  esac
}

_ensure_numeric_main_gpu() {
  local env_file="$1" split_mode="$2"
  local main_gpu
  main_gpu="$(env_get "$env_file" "LLAMA_ARG_MAIN_GPU")"
  if [[ -z "$main_gpu" || ! "$main_gpu" =~ ^[0-9]+$ ]]; then
    if [[ -n "$main_gpu" ]]; then
      warn "Invalid LLAMA_ARG_MAIN_GPU='${main_gpu}' — resetting to 0"
    fi
    if [[ "$split_mode" != "none" ]]; then
      env_set "$env_file" "LLAMA_ARG_MAIN_GPU" "0"
    fi
  fi
}

_write_assignment_from_json() {
  local json="$1" env_file="$2"

  local llama_uuids split_mode tensor_split
  llama_uuids=$(echo "$json" | jq -r '.gpu_assignment.services.llama_server.gpus // [] | join(",")') || llama_uuids=""
  split_mode=$(echo "$json" | jq -r '.gpu_assignment.services.llama_server.parallelism.mode // "none"') || split_mode="none"
  split_mode=$(_map_llama_split_mode "$split_mode")
  tensor_split=$(echo "$json" | jq -r '
    .gpu_assignment.services.llama_server as $svc |
    if $svc.parallelism.tensor_split then ($svc.parallelism.tensor_split | map(tostring) | join(","))
    else "" end') || tensor_split=""

  [[ -n "$llama_uuids" ]] && env_set "$env_file" "LLAMA_SERVER_GPU_UUIDS" "$llama_uuids"
  env_set "$env_file" "LLAMA_ARG_SPLIT_MODE" "$split_mode"
  local llama_uuid_count
  llama_uuid_count=$(_count_csv_items "$llama_uuids")
  if [[ "$llama_uuid_count" -gt 0 ]]; then
    _set_tensor_split_if_valid "$env_file" "$tensor_split" "$llama_uuid_count" "assign_gpus.py"
  else
    env_unset "$env_file" "LLAMA_ARG_TENSOR_SPLIT"
  fi

  local main_gpu
  main_gpu=$(echo "$json" | jq -r '.gpu_assignment.services.llama_server.parallelism.main_gpu_index // empty') || main_gpu=""
  if [[ "$main_gpu" =~ ^[0-9]+$ ]]; then
    env_set "$env_file" "LLAMA_ARG_MAIN_GPU" "$main_gpu"
  fi
  _ensure_numeric_main_gpu "$env_file" "$split_mode"

  # Per-service GPU UUIDs
  local svc uuid
  for svc in whisper comfyui embeddings; do
    uuid=$(echo "$json" | jq -r ".gpu_assignment.services.${svc}.gpus[0]? // empty") || uuid=""
    local env_key
    case "$svc" in
      whisper)    env_key="WHISPER_GPU_UUID" ;;
      comfyui)    env_key="COMFYUI_GPU_UUID" ;;
      embeddings) env_key="EMBEDDINGS_GPU_UUID" ;;
    esac
    [[ -n "$uuid" && "$uuid" != "null" ]] && env_set "$env_file" "$env_key" "$uuid"
  done

  env_set "$env_file" "GPU_COUNT" "${GPU_COUNT}"
  log "Multi-GPU env vars written: llama=[${llama_uuids}] mode=${split_mode}"
}

_write_builtin_assignment() {
  local env_file="$1" model_size_mb="$2" topo_file="$3"

  _select_builtin_llama_gpus "$topo_file" "$model_size_mb"
  local split_mode="${BUILTIN_LLAMA_SPLIT_MODE:-layer}"
  local -a selected_indices=("${BUILTIN_LLAMA_INDICES[@]}")
  if [[ "${#selected_indices[@]}" -gt 0 ]]; then
    mapfile -t selected_indices < <(printf '%s\n' "${selected_indices[@]}" | sort -n)
  fi

  # Selected GPUs → llama-server with topology-driven split mode
  local all_uuids=""
  local split=""
  local missing_vram=false
  local idx
  for idx in "${selected_indices[@]}"; do
    local uuid="${GPU_UUIDS[$idx]:-}"
    [[ -z "$uuid" ]] && continue
    [[ -n "$all_uuids" ]] && all_uuids+=","
    all_uuids+="$uuid"

    local vram="${GPU_VRAMS[$idx]:-}"
    if [[ "$vram" =~ ^[0-9]+$ ]]; then
      [[ -n "$split" ]] && split+=","
      split+="$vram"
    else
      missing_vram=true
    fi
  done

  [[ -n "$all_uuids" ]] && env_set "$env_file" "LLAMA_SERVER_GPU_UUIDS" "$all_uuids"
  env_set "$env_file" "LLAMA_ARG_SPLIT_MODE" "$split_mode"
  if [[ "$missing_vram" == "true" ]]; then
    split=""
  fi
  if [[ "${#selected_indices[@]}" -gt 0 ]]; then
    _set_tensor_split_if_valid "$env_file" "$split" "${#selected_indices[@]}" "builtin fallback"
  else
    env_unset "$env_file" "LLAMA_ARG_TENSOR_SPLIT"
  fi
  env_set "$env_file" "GPU_COUNT" "${GPU_COUNT}"
  _ensure_numeric_main_gpu "$env_file" "$split_mode"

  log "Built-in assignment: ${#selected_indices[@]} GPUs → llama, mode=${split_mode}"
}
