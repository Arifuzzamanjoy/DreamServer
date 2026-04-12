#!/usr/bin/env bash
# ============================================================================
# Dream Server — Vast.ai Environment Helpers
# ============================================================================
# Part of: installers/vastai/lib/
# Purpose: .env management, port checks, directory discovery, CPU capping,
#          ownership fixes, HTTP polling, post-install fix orchestrator
#
# Expects: DREAM_USER, DREAM_HOME, LOGFILE, log(), warn(), err()
# Provides: env_set(), env_get(), port_in_use(), find_dream_dir(),
#           cap_cpu_in_yaml(), fix_ownership(), wait_for_http(),
#           apply_post_install_fixes()
#
# Modder notes:
#   env_set is idempotent — safe to call multiple times with same key.
#   find_dream_dir checks both expected DreamServer install paths.
#
# SPDX-License-Identifier: Apache-2.0
# ============================================================================

set -euo pipefail

# Set a key in .env idempotently (no duplicates, preserves inode)
env_set() {
  local file="$1" key="$2" value="$3"
  [[ ! -f "$file" ]] && touch "$file"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

# Read a key from .env
env_get() {
  local file="$1" key="$2"
  grep "^${key}=" "$file" 2>&1 | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || echo ""
}

# Check if a TCP port is in use
port_in_use() {
  local port="$1"
  ss -tlnp 2>&1 | grep -q ":${port} "
}

# Locate the active dream-server working directory
find_dream_dir() {
  local candidate
  for candidate in "${DREAM_HOME}/dream-server" "${DREAM_HOME}/DreamServer/dream-server"; do
    if [[ -f "${candidate}/.env" && -f "${candidate}/docker-compose.base.yml" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  for candidate in "${DREAM_HOME}/dream-server" "${DREAM_HOME}/DreamServer/dream-server"; do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Cap CPU values in YAML files to actual CPU count
cap_cpu_in_yaml() {
  local dir="$1" max_cpu="$2"
  find "$dir" \( -name "*.yml" -o -name "*.yaml" \) -type f | while read -r f; do
    if grep -qE "cpus:\s*['\"]?[0-9]+\.0['\"]?" "$f"; then
      sed -i -E "s/cpus:\s*['\"]?([0-9]+)\.0['\"]?/cpus: '${max_cpu}.0'/g" "$f"
    fi
  done
}

# Fix ownership recursively, only if needed
fix_ownership() {
  local dir="$1" user="$2" group="${3:-$2}"
  [[ ! -d "$dir" ]] && return 0
  local current_owner
  current_owner=$(stat -c '%U' "$dir" || echo "unknown")
  if [[ "$current_owner" != "$user" ]]; then
    chown -R "${user}:${group}" "$dir" || warn "chown failed on ${dir} (non-fatal)"
  fi
}

# Wait for a URL to return HTTP 200
wait_for_http() {
  local url="$1" timeout="${2:-60}" interval="${3:-5}"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  return 1
}

# ── Detect GPU backend from hardware ────────────────────────────────────────
detect_gpu_backend() {
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    echo "nvidia"
  elif command -v rocm-smi &>/dev/null || [[ -e /dev/kfd ]]; then
    echo "amd"
  else
    echo "cpu"
  fi
}

# ── Post-install fix orchestrator ───────────────────────────────────────────
# Called by phases/05, subcommands/fix, subcommands/resume.
# Coordinates all post-install fixes in correct order.
apply_post_install_fixes() {
  local ds_dir="$1"
  local gpu_backend="${2:-auto}"
  local data_dir="${ds_dir}/data"
  local env_file="${ds_dir}/.env"
  local cpu_count
  cpu_count=$(nproc)

  [[ "$gpu_backend" == "auto" ]] && gpu_backend=$(detect_gpu_backend)

  # Docker group membership
  if getent group docker &>/dev/null; then
    usermod -aG docker "$DREAM_USER" || warn "docker group add failed (non-fatal)"
  fi

  # CPU limit fix — cap to (actual - 1) if < 16
  if [[ $cpu_count -lt 16 ]]; then
    local max_cpu=$(( cpu_count > 1 ? cpu_count - 1 : 1 ))
    cap_cpu_in_yaml "$ds_dir" "$max_cpu"
    log "CPU limits capped to ${max_cpu} (instance has ${cpu_count} cores)"
  fi

  _apply_permission_fixes "$ds_dir" "$data_dir" "$gpu_backend"
  _apply_compatibility_fixes "$ds_dir"
  _apply_env_defaults "$ds_dir" "$env_file" "$data_dir"

  log "Post-install fixes applied (including ACL-based permission system)"
}

_apply_permission_fixes() {
  local ds_dir="$1" data_dir="$2" gpu_backend="$3"
  ensure_acl_tools
  precreate_extension_data_dirs "$ds_dir"
  apply_data_acl "$data_dir"
  fix_known_uid_requirements "$data_dir" "$gpu_backend"
  configure_dream_umask
  create_permission_fix_script "$ds_dir"
  apply_data_acl "${ds_dir}/extensions" || warn "ACL on extensions/ failed (non-fatal)"
  if [[ -d "${ds_dir}/user-extensions" ]]; then
    apply_data_acl "${ds_dir}/user-extensions"
  fi
  find "${ds_dir}/scripts" -name "*.sh" -exec chmod +x {} + || warn "chmod scripts failed (non-fatal)"
  mkdir -p "${ds_dir}/logs"
  apply_data_acl "${ds_dir}/logs" || warn "ACL on logs/ failed (non-fatal)"
}

_apply_compatibility_fixes() {
  local ds_dir="$1"
  ensure_whisper_ui_compatibility "$ds_dir"
  patch_openclaw_inject_token_runtime "$ds_dir"
}

_apply_env_defaults() {
  local ds_dir="$1" env_file="$2" data_dir="$3"
  [[ ! -f "$env_file" ]] && return 0

  # WEBUI_SECRET — open-webui crashes without it
  if [[ -z "$(env_get "$env_file" "WEBUI_SECRET")" ]]; then
    env_set "$env_file" "WEBUI_SECRET" "$(openssl rand -hex 32)"
    log "Generated WEBUI_SECRET"
  fi

  # SEARXNG_SECRET
  if [[ -z "$(env_get "$env_file" "SEARXNG_SECRET")" ]]; then
    env_set "$env_file" "SEARXNG_SECRET" "$(openssl rand -hex 32)"
    log "Generated SEARXNG_SECRET"
  fi

  # GGUF_FILE — detect from data/models if not set
  if [[ -z "$(env_get "$env_file" "GGUF_FILE")" ]]; then
    local first_model
    first_model=$(find "${data_dir}/models/" -maxdepth 1 -name "*.gguf" -type f \
      -printf '%s %f\n' 2>&1 | sort -rn | head -1 | cut -d' ' -f2- || echo "")
    if [[ -n "$first_model" ]]; then
      env_set "$env_file" "GGUF_FILE" "$first_model"
      log "Set GGUF_FILE=${first_model}"
    fi
  fi
}
