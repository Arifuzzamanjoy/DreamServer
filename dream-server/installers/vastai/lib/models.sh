#!/usr/bin/env bash
# ============================================================================
# Dream Server — Vast.ai Model Management
# ============================================================================
# Part of: installers/vastai/lib/
# Purpose: Model URL resolution, aria2c-optimized downloads, model swap
#          watcher for background upgrades
#
# Expects: LOGFILE, log(), warn(), env_get(), env_set()
# Provides: resolve_model_url(), optimize_model_download(),
#           create_model_swap_watcher()
#
# Modder notes:
#   resolve_model_url tries 4 strategies in priority order:
#     1. model-upgrade log  2. upstream tier-map.sh
#     3. backend JSON configs  4. HuggingFace org probing
#   create_model_swap_watcher generates a self-contained script that polls
#   for aria2c completion and hot-swaps the active model.
#
# SPDX-License-Identifier: Apache-2.0
# ============================================================================

set -euo pipefail

# Resolve download URL for a model filename
resolve_model_url() {
  local ds_dir="$1" model_name="$2"

  # Strategy 1: model-upgrade log
  local url
  url=$(_resolve_from_log "$ds_dir" "$model_name") && [[ -n "$url" ]] && { echo "$url"; return 0; }

  # Strategy 2: upstream tier-map.sh
  url=$(_resolve_from_tiermap "$ds_dir" "$model_name") && [[ -n "$url" ]] && { echo "$url"; return 0; }

  # Strategy 3: backend JSON configs
  url=$(_resolve_from_backends "$ds_dir" "$model_name") && [[ -n "$url" ]] && { echo "$url"; return 0; }

  # Strategy 4: probe common HuggingFace orgs
  url=$(_resolve_from_hf_probe "$model_name") && [[ -n "$url" ]] && { echo "$url"; return 0; }

  return 1
}

_resolve_from_log() {
  local ds_dir="$1" model_name="$2"
  local upgrade_log="${ds_dir}/logs/model-upgrade.log"
  [[ ! -f "$upgrade_log" ]] && return 1
  grep -oP 'https://huggingface\.co/[^\s"]+'"${model_name}" "$upgrade_log" | tail -1 || return 1
}

_resolve_from_tiermap() {
  local ds_dir="$1" model_name="$2"
  local tier_map="${ds_dir}/installers/lib/tier-map.sh"
  [[ ! -f "$tier_map" ]] && return 1
  grep -oP 'https://huggingface\.co/[^\s"'"'"']+'"${model_name}" "$tier_map" | head -1 || return 1
}

_resolve_from_backends() {
  local ds_dir="$1" model_name="$2"
  local backend_dir="${ds_dir}/config/backends"
  [[ ! -d "$backend_dir" ]] && return 1
  grep -rhoP 'https://huggingface\.co/[^\s"]+'"${model_name}" "$backend_dir" | head -1 || return 1
}

_resolve_from_hf_probe() {
  local model_name="$1"
  local base_name
  base_name=$(echo "$model_name" | sed -E 's/-[QqFf][0-9_]+[A-Za-z]*\.gguf$//')
  [[ -z "$base_name" ]] && return 1

  local org
  for org in "unsloth" "bartowski" "lmstudio-community"; do
    local test_url="https://huggingface.co/${org}/${base_name}-GGUF/resolve/main/${model_name}"
    if curl -sfI --max-time 10 "$test_url" | grep -qi "200\|302\|301"; then
      echo "$test_url"
      return 0
    fi
  done
  return 1
}

# Resume/restart incomplete model downloads with aria2c
optimize_model_download() {
  local ds_dir="$1"
  local data_dir="${ds_dir}/data"

  local part_files
  part_files=$(find "${data_dir}/models/" -name "*.gguf.part" -type f 2>&1 || echo "")

  if [[ -z "$part_files" ]]; then
    if pgrep -f "aria2c.*gguf" > /dev/null 2>&1; then
      log "aria2c download already running"
      return 0
    fi
    log "No incomplete model downloads found — models are ready"
    return 0
  fi

  local part_file part_name part_size_mb gguf_url
  part_file=$(echo "$part_files" | head -1)
  part_name=$(basename "$part_file" .part)
  part_size_mb=$(( $(stat -c%s "$part_file" || echo 0) / 1048576 ))

  warn "Incomplete download: ${part_name} (${part_size_mb} MB so far)"
  pkill -f "curl.*${part_name}" || warn "no curl to kill for ${part_name} (non-fatal)"
  pkill -f "wget.*${part_name}" || warn "no wget to kill for ${part_name} (non-fatal)"
  sleep 2

  gguf_url=$(resolve_model_url "$ds_dir" "$part_name") || {
    warn "Could not resolve download URL for ${part_name} — leaving original download"
    return 0
  }

  log "Restarting download with aria2c (8 threads)..."
  rm -f "$part_file"
  mkdir -p "${ds_dir}/logs"

  nohup aria2c \
    -x 8 -s 8 -k 10M \
    --continue=true \
    --max-tries=0 \
    --retry-wait=5 \
    --timeout=60 \
    --connect-timeout=30 \
    --file-allocation=none \
    --auto-file-renaming=false \
    --console-log-level=warn \
    --summary-interval=30 \
    --check-integrity=true \
    -d "${data_dir}/models" \
    -o "${part_name}" \
    "${gguf_url}" \
    >> "${ds_dir}/logs/aria2c-download.log" 2>&1 &

  local aria_pid=$!
  log "aria2c started (PID: ${aria_pid})"
  create_model_swap_watcher "$ds_dir" "$part_name"
}

# Generate and start a model swap watcher script
create_model_swap_watcher() {
  local ds_dir="$1" model_name="$2"
  local watcher_script="${ds_dir}/scripts/model-swap-on-complete.sh"
  mkdir -p "${ds_dir}/scripts"

  cat > "$watcher_script" << 'WATCHER_EOF'
#!/usr/bin/env bash
set -euo pipefail
# Auto-swap model when aria2c download completes

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="${SCRIPT_DIR}/data/models"
ENV_FILE="${SCRIPT_DIR}/.env"
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }

swap_model() {
  local new_model="$1"
  local old_model
  old_model=$(grep '^GGUF_FILE=' "$ENV_FILE" | cut -d= -f2 | tr -d '"' || echo "")
  [[ "$new_model" == "$old_model" ]] && return 0
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Swapping: ${old_model} -> ${new_model}"
  local tmp_env
  tmp_env=$(mktemp)
  sed "s|^GGUF_FILE=.*|GGUF_FILE=${new_model}|" "$ENV_FILE" > "$tmp_env"
  cat "$tmp_env" > "$ENV_FILE"
  rm -f "$tmp_env"
  docker restart dream-llama-server || warn "llama-server restart failed (non-fatal)"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Swapped to ${new_model}"
}

while true; do
  if ! pgrep -f "aria2c.*gguf" > /dev/null 2>&1; then
    local_model=$(ls -S "${MODEL_DIR}"/*.gguf 2>&1 | head -1 | xargs -r basename || echo "")
    if [[ -n "${local_model:-}" ]]; then
      swap_model "$local_model"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Watcher exiting — download complete"
    exit 0
  fi
  sleep 30
done
WATCHER_EOF

  chmod +x "$watcher_script"
  nohup "$watcher_script" >> "${ds_dir}/logs/model-swap.log" 2>&1 &
  log "Model swap watcher started (PID: $!)"
}
