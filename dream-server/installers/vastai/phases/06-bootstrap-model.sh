#!/usr/bin/env bash
# ============================================================================
# Dream Server — Vast.ai Phase 06: Bootstrap Model
# ============================================================================
# Part of: installers/vastai/phases/
# Purpose: Ensure a usable GGUF model file exists so llama-server can start
#
# Expects: DS_DIR, GPU_BACKEND, log(), warn(), env_get(), env_set(),
#          fix_known_uid_requirements(), apply_data_acl()
# Provides: Verified GGUF_FILE in .env pointing to a real model
#
# Fixes covered: #19 (bootstrap model missing), #20 (llama-server hang)
#
# SPDX-License-Identifier: Apache-2.0
# ============================================================================

set -euo pipefail

step "Phase 6/12: Ensuring bootstrap model is available"

env_file="${DS_DIR}/.env"
data_dir="${DS_DIR}/data"
models_dir="${data_dir}/models"
mkdir -p "$models_dir"

gguf_file=""
model_path=""
model_ready=false

gguf_file=$(env_get "$env_file" "GGUF_FILE")

# Check if configured model exists and is valid
if [[ -n "$gguf_file" ]]; then
  model_path="${models_dir}/${gguf_file}"
  if [[ -f "$model_path" ]]; then
    file_size=$(stat -c%s "$model_path" || echo 0)
    if [[ $file_size -gt 100000000 ]]; then
      model_ready=true
      log "Model verified: ${gguf_file} ($(( file_size / 1048576 )) MB)"
    else
      warn "Model file exists but too small (${file_size} bytes) — likely corrupt"
      rm -f "$model_path"
    fi
  else
    warn "GGUF_FILE=${gguf_file} but file not found at ${model_path}"
  fi
fi

# Check for ANY .gguf file as fallback
if [[ "$model_ready" != "true" ]]; then
  any_model=$(find "$models_dir" -name "*.gguf" -size +100M 2>&1 | head -1 || echo "")
  if [[ -n "$any_model" ]]; then
    found_name=$(basename "$any_model")
    env_set "$env_file" "GGUF_FILE" "$found_name"
    model_ready=true
    log "Found existing model: ${found_name} — updated GGUF_FILE"
  fi
fi

# Last resort: download small bootstrap model
if [[ "$model_ready" != "true" ]]; then
  warn "No usable model found — downloading bootstrap model..."
  bootstrap_url="https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf"
  bootstrap_name="Qwen3-0.6B-Q4_K_M.gguf"

  if command -v aria2c &>/dev/null; then
    aria2c -x 8 -s 8 -k 5M --file-allocation=none --console-log-level=notice \
      -d "$models_dir" -o "$bootstrap_name" "$bootstrap_url" 2>&1 | tail -5
  else
    curl -L --progress-bar -o "${models_dir}/${bootstrap_name}" "$bootstrap_url"
  fi

  if [[ -f "${models_dir}/${bootstrap_name}" ]]; then
    env_set "$env_file" "GGUF_FILE" "$bootstrap_name"
    log "Bootstrap model downloaded: ${bootstrap_name}"
  else
    err "Failed to download bootstrap model — llama-server will not start"
    warn "Continuing anyway — other services may still work"
  fi
fi

fix_known_uid_requirements "$data_dir" "$GPU_BACKEND"
apply_data_acl "$models_dir" || warn "ACL on models/ failed (non-fatal)"
