#!/usr/bin/env bash
#=============================================================================
# DreamServer — Vast.ai One-Shot Setup Script (v4.0)
#
# Target:  Vast.ai GPU instance (NVIDIA, any SKU)
# OS:      Ubuntu 22.04 / 24.04 (Vast.ai default images)
# License: Apache-2.0 (same as DreamServer)
#
# Usage:
#   bash dreamserver-vastai-setup.sh              # Full install
#   bash dreamserver-vastai-setup.sh --teardown   # Clean shutdown (stops billing)
#   bash dreamserver-vastai-setup.sh --status     # Health check
#   bash dreamserver-vastai-setup.sh --resume     # Resume after SSH reconnect
#
# Design principles (aligned with DreamServer CLAUDE.md):
#   - Let It Crash > KISS > Pure Functions > SOLID
#   - set -euo pipefail everywhere; errors kill the process
#   - Narrow catches at I/O boundaries only, with logging
#   - Idempotent: safe to run multiple times
#   - No hardcoded model names/URLs — reads from DreamServer's own tier-map
#   - Uses DreamServer's resolve-compose-stack.sh instead of manual compose layering
#
# What this script fixes (discovered through live Vast.ai debugging):
#   01. Root user rejection      — DreamServer installer refuses root
#   02. Docker socket denied     — dream user needs docker group membership
#   03. /tmp broken              — some Vast.ai images ship with wrong /tmp perms
#   04. CPU limit overflow       — compose hardcodes cpus: '16.0', Vast instances < 16
#   05. n8n uid mismatch         — n8n container requires uid 1000
#   06. dashboard-api write fail — /data directory needs world-write
#   07. comfyui models write     — /models directory needs write access
#   08. WEBUI_SECRET missing     — open-webui crashes without it
#   09. Dual directory confusion — installer creates ~/dream-server AND ~/DreamServer/dream-server
#   10. Dashboard stuck Created  — frontend container doesn't auto-start
#   11. HuggingFace Xet throttle — single-stream curl dies at ~70%, replaced with aria2c
#   12. NVIDIA toolkit missing   — some Vast.ai images lack nvidia-container-toolkit config
#   13. Disk space insufficient  — Vast.ai disk is static, can't resize after creation
#   14. Docker Compose v1 syntax — some images have old docker-compose, need v2 plugin
#   15. .env duplicate entries   — repeated runs appended duplicate keys
#   16. Port conflicts           — other processes may occupy DreamServer ports
#   17. DNS resolution failure   — some Vast.ai instances have broken resolv.conf
#   18. Shared memory too small  — /dev/shm defaults can starve GPU containers
#   19. Bootstrap model missing  — GGUF_FILE points to non-existent file, llama-server crash-loops
#   20. llama-server infinite hang— installer Phase 6 polls forever; diagnosed + auto-fixed at 45s
#   21. No systemd on Vast.ai   — host agent install fails; started manually in background
#   22. OpenCode crash-loop      — disabled automatically if crash-looping (non-essential)
#   23. CUDA OOM on large models — auto-detects OOM, swaps to smallest model as fallback
#   24. /dev/shm too small       — attempts remount to 4GB for CUDA IPC
#   25. ComfyUI infinite hang    — downloads 6-12GB on first boot; let run in background, don't block
#   26. Installer timeout        — 10min cap prevents infinite hangs at any phase
#   27. AMD GPU support          — auto-detects AMD via rocm-smi, uses docker-compose.amd.yml
#   28. CPU-only fallback        — runs without GPU if none detected
#=============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Script metadata ─────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="6.0.0"
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly LOCKFILE="/tmp/dreamserver-vastai-setup.lock"
readonly LOGFILE="/var/log/dreamserver-vastai-setup.log"

# ── DreamServer defaults ────────────────────────────────────────────────────
readonly DREAM_USER="dream"
readonly DREAM_HOME="/home/${DREAM_USER}"
readonly REPO_URL="https://github.com/Light-Heart-Labs/DreamServer.git"
readonly REPO_BRANCH="main"
readonly MIN_DISK_GB=40
readonly MIN_VRAM_MB=8000

# ── Colors ──────────────────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# ── Logging ─────────────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log()  {
  local msg
  msg="$(_ts) [INFO]  $*"
  echo -e "${GREEN}[✓]${NC} $*"
  echo "$msg" >> "$LOGFILE" 2>/dev/null || true
}

warn() {
  local msg
  msg="$(_ts) [WARN]  $*"
  echo -e "${YELLOW}[!]${NC} $*"
  echo "$msg" >> "$LOGFILE" 2>/dev/null || true
}

err() {
  local msg
  msg="$(_ts) [ERROR] $*"
  echo -e "${RED}[✗]${NC} $*" >&2
  echo "$msg" >> "$LOGFILE" 2>/dev/null || true
}

step() {
  local msg
  msg="$(_ts) [STEP]  $*"
  echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}\n"
  echo "$msg" >> "$LOGFILE" 2>/dev/null || true
}

# ── Signal handling ─────────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  rm -f "$LOCKFILE" 2>/dev/null || true
  if [[ $exit_code -ne 0 ]]; then
    err "Script failed at line ${BASH_LINENO[0]:-unknown} (exit code: ${exit_code})"
    err "Full log: ${LOGFILE}"
    err "Last 10 lines:"
    tail -10 "$LOGFILE" 2>/dev/null | sed 's/^/  /' || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'err "Interrupted by signal"; exit 130' INT TERM HUP

# ── Lockfile (idempotency guard) ────────────────────────────────────────────
acquire_lock() {
  if [[ -f "$LOCKFILE" ]]; then
    local lock_pid
    lock_pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      err "Another instance is running (PID: ${lock_pid}). If stale: rm ${LOCKFILE}"
      exit 1
    fi
    warn "Stale lockfile found — removing"
    rm -f "$LOCKFILE"
  fi
  echo $$ > "$LOCKFILE"
}

# ── Pure helper functions ───────────────────────────────────────────────────

# ── Manifest-driven service discovery ───────────────────────────────────────
# Reads extension manifests to auto-discover services, ports, categories,
# proxy modes, and startup behavior. Eliminates hardcoded service lists.
#
# Requires: python3 with PyYAML (installed in Phase 1 as a system dep).
# Fallback: if python3/PyYAML unavailable, returns empty — callers must
# handle gracefully and fall back to defaults.

# Read a field from a manifest.yaml under the service: block.
# Usage: read_manifest_field <manifest_path> <field_name>
# Returns: the field value (string), or empty if not found.
read_manifest_field() {
  local manifest="$1" field="$2"
  python3 -c "
import yaml, sys
try:
    data = yaml.safe_load(open(sys.argv[1]))
    svc = data.get('service') or {}
    val = svc.get(sys.argv[2], '')
    if isinstance(val, list):
        print(' '.join(str(v) for v in val))
    else:
        print(val)
except Exception:
    pass
" "$manifest" "$field" 2>/dev/null || true
}

# Discover all enabled services from extension manifests.
# Outputs lines of: ID|PORT_ENV|PORT_DEFAULT|NAME|CATEGORY|PROXY_MODE|STARTUP_BEHAVIOR|CONTAINER_NAME
# Callers pipe through 'while IFS="|" read ...' to destructure.
discover_all_services() {
  local ds_dir="$1"
  local ext_dirs=("${ds_dir}/extensions/services" "${ds_dir}/user-extensions")

  for ext_root in "${ext_dirs[@]}"; do
    [[ ! -d "$ext_root" ]] && continue
    for manifest in "${ext_root}"/*/manifest.yaml; do
      [[ ! -f "$manifest" ]] && continue
      python3 -c "
import yaml, sys
try:
    data = yaml.safe_load(open(sys.argv[1]))
    svc = data.get('service') or {}
    sid      = svc.get('id', '')
    port_env = svc.get('external_port_env', '')
    port_def = svc.get('external_port_default', '')
    name     = svc.get('name', sid)
    cat      = svc.get('category', 'optional')
    proxy    = svc.get('proxy_mode', 'simple')
    startup  = svc.get('startup_behavior', 'normal')
    cname    = svc.get('container_name', '')
    htimeout = svc.get('health_timeout', 0)
    # Heuristic: if no startup_behavior but health_timeout > 20, treat as heavy
    if startup == 'normal' and isinstance(htimeout, (int, float)) and htimeout > 20:
        startup = 'heavy'
    if sid:
        print(f'{sid}|{port_env}|{port_def}|{name}|{cat}|{proxy}|{startup}|{cname}')
except Exception:
    pass
" "$manifest" 2>/dev/null || true
    done
  done
}

# Extract the numeric UID from a compose.yaml's user: directive.
# Returns: UID number (e.g., "1000"), or empty if no user: directive.
extract_compose_uid() {
  local compose_file="$1"
  [[ ! -f "$compose_file" ]] && return 0
  python3 -c "
import yaml, re, sys
try:
    data = yaml.safe_load(open(sys.argv[1]))
    services = data.get('services') or {}
    for sname, sdef in services.items():
        user = sdef.get('user', '')
        if not user:
            continue
        user = str(user)
        # Extract UID from formats: '1000:1000', '\${UID:-1000}:\${GID:-1000}', '0:0'
        # Resolve \${VAR:-DEFAULT} to DEFAULT
        resolved = re.sub(r'\\\$\{[A-Za-z_]+:-(\d+)\}', r'\1', user)
        uid = resolved.split(':')[0].strip()
        if uid.isdigit():
            print(uid)
            break
except Exception:
    pass
" "$compose_file" 2>/dev/null || true
}

# Set a key in an .env file idempotently (no duplicates, preserves order)
env_set() {
  local file="$1" key="$2" value="$3"
  [[ ! -f "$file" ]] && touch "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    # Replace in-place — preserves inode (important for DreamServer, per yasinBursali's fix)
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

# Read a key from an .env file
env_get() {
  local file="$1" key="$2"
  grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true
}

# Check if a port is in use
port_in_use() {
  local port="$1"
  ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
  return 1
}

# Wait for a URL to return HTTP 200 (with timeout)
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

# Get the active dream-server working directory
find_dream_dir() {
  local candidate
  for candidate in "${DREAM_HOME}/dream-server" "${DREAM_HOME}/DreamServer/dream-server"; do
    if [[ -f "${candidate}/.env" && -f "${candidate}/docker-compose.base.yml" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  # Fallback: any directory with docker-compose.base.yml
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
  find "$dir" \( -name "*.yml" -o -name "*.yaml" \) -type f 2>/dev/null | while read -r f; do
    # Match patterns like cpus: '16.0' or cpus: "16.0" or cpus: 16.0
    if grep -qE "cpus:\s*['\"]?[0-9]+\.0['\"]?" "$f" 2>/dev/null; then
      sed -i -E "s/cpus:\s*['\"]?([0-9]+)\.0['\"]?/cpus: '${max_cpu}.0'/g" "$f"
    fi
  done
}

# Fix ownership recursively, only if needed
fix_ownership() {
  local dir="$1" user="$2" group="${3:-$2}"
  if [[ -d "$dir" ]]; then
    local current_owner
    current_owner=$(stat -c '%U' "$dir" 2>/dev/null || echo "unknown")
    if [[ "$current_owner" != "$user" ]]; then
      chown -R "${user}:${group}" "$dir"
    fi
  fi
}

# ── [T2] Dynamic port discovery ─────────────────────────────────────────────
# Reads all *_PORT variables from .env to build service→port mapping.
# Labels are auto-discovered from extension manifests (no hardcoded list).
# Falls back to .env.example or .env.schema.json for defaults.
# Returns lines of "SERVICE_KEY PORT_NUMBER LABEL" (e.g., "WEBUI_PORT 3000 Open WebUI").
discover_service_ports() {
  local ds_dir="$1"
  local env_file="${ds_dir}/.env"
  local env_example="${ds_dir}/.env.example"

  # Build port labels dynamically from manifests
  declare -A PORT_LABELS
  while IFS='|' read -r _id port_env _port_def svc_name _cat _proxy _startup _cname; do
    [[ -z "$port_env" ]] && continue
    PORT_LABELS["$port_env"]="$svc_name"
  done < <(discover_all_services "$ds_dir")

  # Collect ports from .env (active config), fall back to .env.example
  local source_file="$env_file"
  [[ ! -f "$source_file" ]] && source_file="$env_example"
  [[ ! -f "$source_file" ]] && return 0

  grep -E '^[A-Z_]+_PORT=' "$source_file" 2>/dev/null | while IFS='=' read -r key value; do
    value=$(echo "$value" | tr -d '"' | tr -d "'")
    [[ -z "$value" ]] && continue
    local label="${PORT_LABELS[$key]:-$key}"
    echo "${key}|${value}|${label}"
  done
}

# ── [T10] Pre-pull Docker images in parallel ────────────────────────────────
# Extracts unique image refs from compose files and pulls them concurrently.
# Gracefully skips on failure — compose up will pull missing images anyway.
prepull_docker_images() {
  local ds_dir="$1"
  local max_parallel="${2:-4}"

  local images
  images=$(grep -rh 'image:' "${ds_dir}"/docker-compose*.yml "${ds_dir}"/extensions/services/*/compose*.y*ml 2>/dev/null \
    | sed -E 's/.*image:\s*//' | tr -d '"' | tr -d "'" | sort -u | grep -v '^\$' || true)

  if [[ -z "$images" ]]; then
    log "No Docker images found to pre-pull"
    return 0
  fi

  local count
  count=$(echo "$images" | wc -l)
  log "Pre-pulling ${count} Docker images (${max_parallel} parallel)..."

  # Pull in parallel, suppress output, don't fail the script
  echo "$images" | xargs -P "$max_parallel" -I {} sh -c \
    'docker pull {} >/dev/null 2>&1 && echo "  pulled: {}" || echo "  skip:   {} (will retry at compose up)"' \
    2>/dev/null || true

  log "Docker image pre-pull complete"
}

# ── [T4] TTS API readiness gate ─────────────────────────────────────────────
# Wait for Kokoro TTS to load at least one voice model, with progress.
ensure_tts_model_ready() {
  local ds_dir="$1"
  local env_file="${ds_dir}/.env"
  local tts_port

  tts_port="$(env_get "$env_file" "TTS_PORT")"
  tts_port="${tts_port:-8880}"

  # Only if TTS container exists and is running
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'dream-tts'; then
    return 0
  fi

  if ! wait_for_http "http://127.0.0.1:${tts_port}/health" 90 4; then
    warn "Kokoro TTS health not reachable on port ${tts_port} — skipping readiness check"
    return 0
  fi

  # Check if voices/models are available
  local voice_count
  voice_count=$(curl -sf --max-time 10 "http://127.0.0.1:${tts_port}/v1/audio/voices" 2>/dev/null \
    | jq -r 'if type == "array" then length elif .voices then (.voices | length) else 0 end' 2>/dev/null || echo 0)

  if [[ "$voice_count" =~ ^[0-9]+$ ]] && [[ "$voice_count" -gt 0 ]]; then
    log "Kokoro TTS ready (${voice_count} voice(s) available)"
    return 0
  fi

  # Wait up to 90s for model loading
  warn "Kokoro TTS starting — waiting for voice model to load..."
  local waited=0
  while [[ $waited -lt 90 ]]; do
    voice_count=$(curl -sf --max-time 10 "http://127.0.0.1:${tts_port}/v1/models" 2>/dev/null \
      | jq -r '.data | length' 2>/dev/null || echo 0)
    if [[ "$voice_count" =~ ^[0-9]+$ ]] && [[ "$voice_count" -gt 0 ]]; then
      log "Kokoro TTS model loaded (${voice_count} model(s) available)"
      return 0
    fi
    sleep 6
    waited=$((waited + 6))
  done

  warn "Kokoro TTS model still loading — will be available shortly"
}

# ── [T3] ComfyUI model preload ──────────────────────────────────────────────
# Downloads user-specified ComfyUI models from COMFYUI_EXTRA_MODELS env var.
# Format: newline-separated "URL|SUBDIR/FILENAME" pairs, e.g.:
#   https://huggingface.co/.../model.safetensors|checkpoints/mymodel.safetensors
#   https://civitai.com/api/download/models/12345|loras/my-lora.safetensors
comfyui_preload_models() {
  local ds_dir="$1"
  local env_file="${ds_dir}/.env"
  local data_dir="${ds_dir}/data"
  local gpu_backend="${2:-nvidia}"

  local extra_models
  extra_models="$(env_get "$env_file" "COMFYUI_EXTRA_MODELS")"
  [[ -z "$extra_models" ]] && return 0

  # Determine ComfyUI models root based on GPU backend
  local models_root
  if [[ "$gpu_backend" == "amd" ]]; then
    models_root="${data_dir}/comfyui/ComfyUI/models"
  else
    models_root="${data_dir}/comfyui/models"
  fi
  mkdir -p "$models_root"

  log "Processing ComfyUI extra models..."

  echo "$extra_models" | tr ';' '\n' | while IFS='|' read -r url target; do
    url=$(echo "$url" | xargs)    # trim whitespace
    target=$(echo "$target" | xargs)
    [[ -z "$url" || -z "$target" ]] && continue

    local dest="${models_root}/${target}"
    local dest_dir
    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir"

    if [[ -f "$dest" ]]; then
      log "  Already exists: ${target}"
      continue
    fi

    log "  Downloading: ${target}..."
    if command -v aria2c &>/dev/null; then
      aria2c -x 4 -s 4 -k 5M --file-allocation=none --console-log-level=warn \
        -d "$dest_dir" -o "$(basename "$dest")" "$url" 2>&1 | tail -3 || \
        warn "  Failed to download ${target} — skipping"
    else
      curl -L --progress-bar -o "$dest" "$url" 2>&1 || \
        warn "  Failed to download ${target} — skipping"
    fi
  done

  # Fix permissions on downloaded models
  apply_data_acl "$models_root" 2>/dev/null || true
  log "ComfyUI model preload complete"
}

# ── [T5] AMD-aware ComfyUI permission fix ───────────────────────────────────
# AMD ROCm and NVIDIA use different bind mount layouts for ComfyUI.
fix_comfyui_permissions() {
  local data_dir="$1"
  local gpu_backend="${2:-nvidia}"

  if [[ "$gpu_backend" == "amd" ]]; then
    # AMD: unified mount at data/comfyui/ComfyUI/
    for d in "${data_dir}/comfyui/ComfyUI/models" \
             "${data_dir}/comfyui/ComfyUI/output" \
             "${data_dir}/comfyui/ComfyUI/input" \
             "${data_dir}/comfyui/ComfyUI/custom_nodes"; do
      if [[ -d "$d" ]]; then
        chmod -R a+rwX "$d" 2>/dev/null || true
      fi
    done
  else
    # NVIDIA: separate mounts per directory
    for d in "${data_dir}/comfyui/models" \
             "${data_dir}/comfyui/output" \
             "${data_dir}/comfyui/input" \
             "${data_dir}/comfyui/workflows"; do
      if [[ -d "$d" ]]; then
        chmod -R a+rwX "$d" 2>/dev/null || true
      fi
    done
  fi
}

# ── [T1] Reverse proxy setup ────────────────────────────────────────────────
# Deploys Caddy as a single-port reverse proxy so all DreamServer services
# are accessible through ONE port. Eliminates the 14-line SSH tunnel.
#
# This is the #1 UX improvement: Vast.ai typically exposes only 1-2 ports.
# With Caddy, users access all services via path-based routing:
#   http://<vast-ip>:<port>/            → Open WebUI
#   http://<vast-ip>:<port>/dashboard/  → Dashboard
#   http://<vast-ip>:<port>/n8n/        → n8n
#   etc.
#
# Failure safety: if Caddy fails to start, the script falls back to
# the traditional SSH tunnel approach — nothing breaks.
setup_reverse_proxy() {
  local ds_dir="$1"
  local proxy_port="${2:-8080}"
  local env_file="${ds_dir}/.env"

  # Install Caddy if not present
  if ! command -v caddy &>/dev/null; then
    log "Installing Caddy reverse proxy..."
    if apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https > /dev/null 2>&1 \
      && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null \
      && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null \
      && apt-get update -qq > /dev/null 2>&1 \
      && apt-get install -y -qq caddy > /dev/null 2>&1; then
      log "Caddy installed successfully"
    else
      warn "Caddy install failed — falling back to SSH tunnel mode"
      return 1
    fi
  fi

  # Generate Caddyfile
  local caddy_dir="${ds_dir}/config/caddy"
  mkdir -p "$caddy_dir"

  # --- Auto-generate Caddy routes from manifests ---
  # Root-mode services (SPAs) need explicit multi-path handling;
  # simple services get a single handle_path /<id>/* block.
  local webui_port
  webui_port="$(env_get "$env_file" "WEBUI_PORT")"; webui_port="${webui_port:-3000}"

  # Begin Caddyfile header
  cat > "${caddy_dir}/Caddyfile" << CADDYEOF
# DreamServer reverse proxy — auto-generated by vastai setup script
# Routes are discovered from extension manifests at install time.
{
  auto_https off
  admin off
}

:${proxy_port} {
  # ── Root: Open WebUI (default landing page) ──
  # Explicit multi-path handling required for SPA asset routing.
  handle / {
    reverse_proxy 127.0.0.1:${webui_port}
  }
  handle /static/* {
    reverse_proxy 127.0.0.1:${webui_port}
  }
  handle /api/* {
    reverse_proxy 127.0.0.1:${webui_port}
  }
  handle /ws/* {
    reverse_proxy 127.0.0.1:${webui_port}
  }
  handle /oauth/* {
    reverse_proxy 127.0.0.1:${webui_port}
  }
  handle /assets/* {
    reverse_proxy 127.0.0.1:${webui_port}
  }

  # ── [T9] Health dashboard ──
  handle_path /health {
    root * ${caddy_dir}
    file_server
    try_files /health.html
  }

CADDYEOF

  # Append auto-discovered service routes
  while IFS='|' read -r sid port_env port_def _name _cat proxy_mode _startup _cname; do
    [[ -z "$port_env" ]] && continue
    # Skip open-webui — handled explicitly as root above
    [[ "$sid" == "open-webui" ]] && continue

    local svc_port
    svc_port="$(env_get "$env_file" "$port_env")"; svc_port="${svc_port:-$port_def}"
    [[ -z "$svc_port" ]] && continue

    if [[ "$proxy_mode" == "root" ]]; then
      # Root-mode SPAs: use handle (not handle_path) to preserve URL structure
      cat >> "${caddy_dir}/Caddyfile" << ROUTEEOF
  # ${sid} (SPA — root mode)
  handle /${sid}/* {
    reverse_proxy 127.0.0.1:${svc_port}
  }

ROUTEEOF
    else
      # Simple API services: handle_path strips the prefix
      cat >> "${caddy_dir}/Caddyfile" << ROUTEEOF
  # ${sid}
  handle_path /${sid}/* {
    reverse_proxy 127.0.0.1:${svc_port}
  }

ROUTEEOF
    fi
  done < <(discover_all_services "$ds_dir")

  # Also add base-compose services that lack manifests (ollama)
  local ollama_port
  ollama_port="$(env_get "$env_file" "OLLAMA_PORT")"; ollama_port="${ollama_port:-8080}"
  cat >> "${caddy_dir}/Caddyfile" << CADDYTAIL
  # ollama (base service — no manifest)
  handle_path /ollama/* {
    reverse_proxy 127.0.0.1:${ollama_port}
  }

  # ── Direct port access (API-compatible) ──
  handle_path /v1/* {
    reverse_proxy 127.0.0.1:${ollama_port}
  }
}
CADDYTAIL

  # Generate health dashboard HTML [T9]
  generate_health_page "${caddy_dir}/health.html" "$ds_dir"

  # Stop any existing Caddy and start fresh
  # Use process check instead of systemctl (Vast.ai has no systemd)
  if pgrep -x caddy > /dev/null 2>&1; then
    local caddy_pid
    caddy_pid=$(pgrep -x caddy | head -1)
    kill "$caddy_pid" 2>/dev/null || true
    sleep 1
  fi

  # Start Caddy in background
  nohup caddy run --config "${caddy_dir}/Caddyfile" --adapter caddyfile \
    >> "${ds_dir}/logs/caddy-proxy.log" 2>&1 &
  local caddy_pid=$!
  sleep 2

  if kill -0 "$caddy_pid" 2>/dev/null; then
    log "Caddy reverse proxy running on port ${proxy_port} (PID: ${caddy_pid})"
    env_set "${env_file}" "REVERSE_PROXY_PORT" "$proxy_port"
    return 0
  else
    warn "Caddy failed to start — check ${ds_dir}/logs/caddy-proxy.log"
    return 1
  fi
}

# ── [T9] Health dashboard page ──────────────────────────────────────────────
# Generates a static HTML page that uses JS to poll container health.
generate_health_page() {
  local output_file="$1"
  local ds_dir="$2"

  cat > "$output_file" << 'HEALTHEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>DreamServer — Health</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           background: #0f1117; color: #e0e0e0; padding: 2rem; }
    h1 { color: #7dd3fc; margin-bottom: 1.5rem; font-size: 1.5rem; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 1rem; }
    .card { background: #1a1d27; border-radius: 12px; padding: 1rem; border: 1px solid #2a2d37; }
    .card h3 { font-size: 0.95rem; margin-bottom: 0.5rem; }
    .status { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 8px; }
    .healthy { background: #22c55e; }
    .running { background: #eab308; }
    .stopped { background: #6b7280; }
    .error   { background: #ef4444; }
    .port { color: #7dd3fc; font-size: 0.85rem; }
    .ts { color: #6b7280; font-size: 0.8rem; margin-top: 1rem; }
    a { color: #7dd3fc; text-decoration: none; }
  </style>
</head>
<body>
  <h1>🌙 DreamServer Health</h1>
  <div class="grid" id="services">
    <div class="card"><p>Loading...</p></div>
  </div>
  <p class="ts">Auto-refreshes every 15s · <span id="updated"></span></p>
  <script>
    async function refresh() {
      try {
        const r = await fetch('/dashboard-api/api/v1/status');
        const data = await r.json();
        const grid = document.getElementById('services');
        grid.innerHTML = '';
        (data.services || []).forEach(s => {
          const cls = s.healthy ? 'healthy' : (s.status === 'running' ? 'running' : 'stopped');
          grid.innerHTML += `<div class="card">
            <h3><span class="status ${cls}"></span>${s.name}</h3>
            <span class="port">:${s.port || '—'}</span>
          </div>`;
        });
      } catch(e) {
        document.getElementById('services').innerHTML =
          '<div class="card"><p>Dashboard API not available. Use <code>--status</code> via SSH.</p></div>';
      }
      document.getElementById('updated').textContent = new Date().toLocaleTimeString();
    }
    refresh();
    setInterval(refresh, 15000);
  </script>
</body>
</html>
HEALTHEOF

  log "Generated health dashboard at ${output_file}"
}

# ── [T12] Optional Cloudflare Tunnel ────────────────────────────────────────
# If CLOUDFLARE_TUNNEL_TOKEN is set, start cloudflared for HTTPS access.
setup_cloudflare_tunnel() {
  local ds_dir="$1"
  local env_file="${ds_dir}/.env"
  local cf_token

  cf_token="$(env_get "$env_file" "CLOUDFLARE_TUNNEL_TOKEN")"
  [[ -z "$cf_token" ]] && return 0

  log "Cloudflare Tunnel token detected — setting up tunnel"

  # Install cloudflared if missing
  if ! command -v cloudflared &>/dev/null; then
    curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /usr/local/bin/cloudflared 2>/dev/null || { warn "cloudflared download failed"; return 0; }
    chmod +x /usr/local/bin/cloudflared
  fi

  # Determine proxy target (Caddy port or direct webui)
  local proxy_port
  proxy_port="$(env_get "$env_file" "REVERSE_PROXY_PORT")"
  proxy_port="${proxy_port:-3000}"

  mkdir -p "${ds_dir}/logs"
  nohup cloudflared tunnel --no-autoupdate run --token "$cf_token" \
    >> "${ds_dir}/logs/cloudflared.log" 2>&1 &

  log "Cloudflare Tunnel started (PID: $!) — HTTPS access active"
}

# ── [T8] Connection-resilient SSH tunnel script ─────────────────────────────
# Generates a persistent SSH tunnel script on the user's behalf.
generate_ssh_tunnel_script() {
  local ds_dir="$1"
  local env_file="${ds_dir}/.env"
  local host_ip ssh_port

  host_ip="${PUBLIC_IPADDR:-$(curl -sf --max-time 5 ifconfig.me 2>/dev/null || echo '<your-vast-ip>')}"
  ssh_port="${VAST_TCP_PORT_22:-22}"

  local script_path="${ds_dir}/connect-tunnel.sh"

  {
    echo '#!/usr/bin/env bash'
    echo '# DreamServer — auto-reconnecting SSH tunnel'
    echo '# Generated by vastai setup script. Run this on YOUR LOCAL machine.'
    echo '# Usage: bash connect-tunnel.sh'
    echo ''
    echo "HOST=\"${host_ip}\""
    echo "SSH_PORT=\"${ssh_port}\""
    echo ''
    echo '# Build port forwards dynamically from known services'
    echo 'FORWARDS="'

    # Enumerate all ports
    discover_service_ports "$ds_dir" | while IFS='|' read -r _key port _label; do
      echo "  -L ${port}:127.0.0.1:${port} \\"
    done

    echo '"'
    echo ''
    echo 'echo "Connecting to DreamServer at ${HOST}:${SSH_PORT}..."'
    echo 'echo "Press Ctrl+C to disconnect."'
    echo 'echo ""'
    echo ''
    echo '# Auto-reconnect loop with exponential backoff'
    echo 'DELAY=5'
    echo 'while true; do'
    echo '  ssh -N -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \\'
    echo '      -o ExitOnForwardFailure=yes \\'
    echo '      -p "$SSH_PORT" $FORWARDS root@"$HOST"'
    echo '  echo ""'
    echo '  echo "[!] Connection lost. Reconnecting in ${DELAY}s..."'
    echo '  sleep "$DELAY"'
    echo '  DELAY=$(( DELAY < 60 ? DELAY * 2 : 60 ))'
    echo 'done'
  } > "$script_path"

  chmod +x "$script_path"
  log "Generated auto-reconnecting tunnel script: ${script_path}"
}

# ── Subcommands ─────────────────────────────────────────────────────────────

cmd_teardown() {
  step "Teardown — stopping all services to halt billing"
  local ds_dir
  ds_dir=$(find_dream_dir) || { err "DreamServer directory not found"; exit 1; }

  cd "$ds_dir"

  # Stop all containers
  if [[ -f "docker-compose.base.yml" ]]; then
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    $compose_cmd down --remove-orphans 2>&1 || warn "Compose down had warnings"
  fi

  # Kill background processes
  pkill -f "aria2c.*gguf" 2>/dev/null || true
  pkill -f "model-swap-on-complete" 2>/dev/null || true

  log "All services stopped. Instance is no longer serving but storage billing continues."
  log "To fully stop billing: delete the instance from Vast.ai console."
  echo ""
  echo -e "${BOLD}Data preserved at:${NC} ${ds_dir}/data/"
  echo -e "${BOLD}To resume:${NC} bash ${SCRIPT_NAME} --resume"
}

cmd_status() {
  local ds_dir
  ds_dir=$(find_dream_dir) || { err "DreamServer directory not found"; exit 1; }

  echo -e "\n${BOLD}DreamServer Status${NC}\n"

  # GPU
  nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu \
    --format=csv,noheader 2>/dev/null | while IFS=',' read -r name mem_total mem_used util; do
    echo -e "  GPU: ${CYAN}${name}${NC} | VRAM: ${mem_used} /${mem_total} | Util: ${util}"
  done

  echo ""

  # Containers
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | head -20

  echo ""
  local healthy running total
  healthy=$(docker ps --filter "health=healthy" --format '{{.Names}}' 2>/dev/null | wc -l)
  running=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
  total=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -c '^dream-' || echo 0)
  echo -e "  Containers: ${GREEN}${healthy}${NC} healthy / ${running} running / ${total} total"

  # Background downloads
  if pgrep -f "aria2c.*gguf" > /dev/null 2>&1; then
    echo -e "  Model download: ${YELLOW}in progress${NC}"
    local dl_log="${ds_dir}/logs/aria2c-download.log"
    [[ -f "$dl_log" ]] && tail -1 "$dl_log" 2>/dev/null | sed 's/^/    /'
  fi
  echo ""
}

cmd_resume() {
  step "Resuming DreamServer"
  local ds_dir
  ds_dir=$(find_dream_dir) || { err "DreamServer directory not found"; exit 1; }

  cd "$ds_dir"

  # Detect GPU backend for resume context
  local gpu_backend="nvidia"
  if command -v rocm-smi &>/dev/null; then
    gpu_backend="amd"
  fi

  # Re-apply runtime fixes (CPU cap, permissions) in case instance was migrated
  apply_post_install_fixes "$ds_dir" "$gpu_backend"

  # Start services
  start_services "$ds_dir"

  print_access_info "$ds_dir"
}

# ── Detect compose command ──────────────────────────────────────────────────
get_compose_cmd() {
  if docker compose version &>/dev/null; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    err "Neither 'docker compose' nor 'docker-compose' found"
    exit 1
  fi
}

# ── Permission system ───────────────────────────────────────────────────────
#
# DreamServer runs 17+ services as Docker containers, each with a different
# internal UID. When containers write to bind-mounted volumes under data/,
# the resulting files are owned by that container's UID on the host. Other
# containers (different UID) and the dream host user then get "permission
# denied" trying to read or write those files.
#
# The fix is three-layered:
#   1. POSIX ACLs with default entries on data/ — new files and dirs created
#      by ANY UID automatically inherit group rwx for the dream group
#   2. Setgid bit (2775) on all directories — new files inherit the dream
#      group regardless of the creating process's primary group
#   3. Known UID overrides — some containers (n8n, qdrant, searxng) hard-
#      require specific ownership that cannot be solved by ACLs alone
#
# This means `dream enable <new-extension>` will work without any permission
# fixes, because the new extension's data/ subdirectory inherits the ACL
# from its parent.
#
# Known container UIDs in DreamServer (as of v2.3):
#   0    — llama-server, open-webui, comfyui, livekit, litellm (run as root)
#   1000 — n8n (hardcoded), qdrant (hardcoded), host-agent (dream user)
#   977  — searxng (some image versions)
#   65534— nobody (some minimal images)
#
#──────────────────────────────────────────────────────────────────────────────

# Install ACL tools if missing (needed for setfacl/getfacl)
ensure_acl_tools() {
  if ! command -v setfacl &>/dev/null; then
    apt-get install -y -qq acl > /dev/null 2>&1 || warn "Could not install acl package"
  fi
}

# Apply POSIX ACLs + setgid on a directory tree so every UID can coexist.
# This is the core of the permission system.
#
# Args: $1 = directory path
#
# Result:
#   - Directory mode 2775 (rwxrwsr-x) — setgid ensures new files inherit group
#   - File mode 0664 (rw-rw-r--)
#   - Default ACL: user::rwx, group::rwx, other::r-x, mask::rwx
#   - Any new file/dir created by ANY UID is readable+writable by group dream
apply_data_acl() {
  local dir="$1"
  [[ ! -d "$dir" ]] && return 0

  # Set ownership: dream:dream (preserves host-agent access)
  chown -R "${DREAM_USER}:${DREAM_USER}" "$dir" 2>/dev/null || true

  # Set directory permissions: 2775 (setgid + rwx for user/group, rx for other)
  find "$dir" -type d -exec chmod 2775 {} + 2>/dev/null || true

  # Set file permissions: 0664 (rw for user/group, r for other)
  find "$dir" -type f -exec chmod 0664 {} + 2>/dev/null || true

  # Apply POSIX default ACLs so future files/dirs inherit group rwx
  if command -v setfacl &>/dev/null; then
    # Default ACL on directories: new files get group rw, new dirs get group rwx
    setfacl -R -d -m "u::rwx,g::rwx,o::rx" "$dir" 2>/dev/null || true
    # Current ACL: ensure group has rwx on everything
    setfacl -R -m "g::rwx" "$dir" 2>/dev/null || true
    log "Applied POSIX ACLs on ${dir}"
  else
    # Fallback: chmod 777 recursively (less secure but functional)
    chmod -R a+rwX "$dir" 2>/dev/null || true
    warn "setfacl unavailable — used chmod fallback on ${dir}"
  fi
}

# Fix known UID-specific ownership requirements that ACLs alone don't solve.
# Some containers check ownership at startup and refuse to run if wrong.
fix_known_uid_requirements() {
  local data_dir="$1"
  local gpu_backend="${2:-nvidia}"
  local ds_dir
  ds_dir=$(dirname "$data_dir")  # data_dir is <ds_dir>/data

  # ── Dynamic UID fix: parse compose.yaml user: directives ──────────────
  # For each extension with a compose.yaml that declares user: UID:GID,
  # chown its data directory to that UID.
  local ext_dirs=("${ds_dir}/extensions/services" "${ds_dir}/user-extensions")
  for ext_root in "${ext_dirs[@]}"; do
    [[ ! -d "$ext_root" ]] && continue
    for ext_path in "${ext_root}"/*/; do
      [[ ! -d "$ext_path" ]] && continue
      local ext_name
      ext_name=$(basename "$ext_path")
      local ext_data="${data_dir}/${ext_name}"

      # Try compose.yaml, compose.yml, then compose.*.yaml
      local compose_file=""
      for candidate in "${ext_path}compose.yaml" "${ext_path}compose.yml"; do
        [[ -f "$candidate" ]] && compose_file="$candidate" && break
      done
      [[ -z "$compose_file" ]] && continue

      local uid
      uid=$(extract_compose_uid "$compose_file")
      if [[ -n "$uid" && "$uid" != "0" ]]; then
        # Non-root UID declared — ensure data dir is owned by that UID
        mkdir -p "$ext_data"
        chown -R "${uid}:${uid}" "$ext_data" 2>/dev/null || true
      fi
    done
  done

  # ── Exceptions that require special handling ──────────────────────────
  # These services have quirks that can't be expressed via compose user: alone.

  # qdrant: runs as uid 1000 but does NOT declare user: in compose.yaml
  if [[ -d "${data_dir}/qdrant" ]]; then
    chown -R 1000:1000 "${data_dir}/qdrant" 2>/dev/null || true
  fi

  # searxng: uid varies by image version (977 or 1000) — world-writable fallback
  if [[ -d "${data_dir}/searxng" ]]; then
    chmod -R a+rwX "${data_dir}/searxng" 2>/dev/null || true
  fi

  # comfyui: AMD and NVIDIA use different bind mount layouts
  fix_comfyui_permissions "$data_dir" "$gpu_backend"

  # open-webui: runs as root, but dream user needs access for backup/export
  if [[ -d "${data_dir}/open-webui" ]]; then
    chmod -R a+rwX "${data_dir}/open-webui" 2>/dev/null || true
  fi

  # whisper: uid 1000 + HuggingFace cache needs wide permissions
  if [[ -d "${data_dir}/whisper" ]]; then
    chown -R 1000:1000 "${data_dir}/whisper" 2>/dev/null || true
    chmod -R a+rwX "${data_dir}/whisper" 2>/dev/null || true
  fi

  # models (shared): llama-server, comfyui, aria2c all write here
  if [[ -d "${data_dir}/models" ]]; then
    chmod -R a+rwX "${data_dir}/models" 2>/dev/null || true
  fi

  log "Fixed UID-specific ownership for services (dynamic + exceptions)"
}

# Pre-create data directories for all known extensions so ACLs are inherited
# from the start. When `dream enable <ext>` runs, the dir already exists
# with correct permissions.
precreate_extension_data_dirs() {
  local ds_dir="$1"
  local data_dir="${ds_dir}/data"

  # Discover all extensions from manifest files
  local ext_dirs=("${ds_dir}/extensions/services" "${ds_dir}/user-extensions")

  for ext_root in "${ext_dirs[@]}"; do
    [[ ! -d "$ext_root" ]] && continue
    for manifest in "${ext_root}"/*/manifest.yaml; do
      [[ ! -f "$manifest" ]] && continue
      local ext_name
      ext_name=$(basename "$(dirname "$manifest")")

      # Create data dir if extension might need one
      local ext_data="${data_dir}/${ext_name}"
      if [[ ! -d "$ext_data" ]]; then
        mkdir -p "$ext_data"
      fi
    done
  done

  # Also ensure user-extensions root exists (for future custom extensions)
  mkdir -p "${ds_dir}/user-extensions" 2>/dev/null || true

  log "Pre-created data directories for all known extensions"
}

# Set the dream user's umask so files created on the host (by dream-cli,
# host-agent, scripts) are group-writable by default.
configure_dream_umask() {
  local bashrc="${DREAM_HOME}/.bashrc"
  local profile="${DREAM_HOME}/.profile"

  for f in "$bashrc" "$profile"; do
    if [[ -f "$f" ]] && ! grep -q 'umask 0002' "$f" 2>/dev/null; then
      echo "" >> "$f"
      echo "# DreamServer: group-writable files by default" >> "$f"
      echo "umask 0002" >> "$f"
    fi
  done
}

# Generate a standalone permission-fix script that can be called by dream-cli
# or cron. This survives across sessions and can be invoked manually.
create_permission_fix_script() {
  local ds_dir="$1"

  # Generate dynamic UID fix commands from compose.yaml user: directives
  local uid_fix_lines=""
  local ext_dirs=("${ds_dir}/extensions/services" "${ds_dir}/user-extensions")
  for ext_root in "${ext_dirs[@]}"; do
    [[ ! -d "$ext_root" ]] && continue
    for ext_path in "${ext_root}"/*/; do
      [[ ! -d "$ext_path" ]] && continue
      local ext_name
      ext_name=$(basename "$ext_path")
      for candidate in "${ext_path}compose.yaml" "${ext_path}compose.yml"; do
        [[ ! -f "$candidate" ]] && continue
        local uid
        uid=$(extract_compose_uid "$candidate")
        if [[ -n "$uid" && "$uid" != "0" ]]; then
          uid_fix_lines+="[[ -d \"\${DATA_DIR}/${ext_name}\" ]] && chown -R ${uid}:${uid} \"\${DATA_DIR}/${ext_name}\" 2>/dev/null || true"$'\n'
        fi
        break
      done
    done
  done

  cat > "${ds_dir}/scripts/fix-permissions.sh" << PERMFIX_EOF
#!/usr/bin/env bash
set -euo pipefail
# DreamServer permission fixer — auto-generated, safe to run anytime.
# Fixes ownership and ACLs across all data directories.
# Usage: bash scripts/fix-permissions.sh

SCRIPT_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
DATA_DIR="\${SCRIPT_DIR}/data"

echo "[*] Fixing permissions on \${DATA_DIR}..."

# 1. Base ACLs on entire data tree
if command -v setfacl &>/dev/null; then
  find "\$DATA_DIR" -type d -exec chmod 2775 {} + 2>/dev/null || true
  find "\$DATA_DIR" -type f -exec chmod 0664 {} + 2>/dev/null || true
  setfacl -R -d -m "u::rwx,g::rwx,o::rx" "\$DATA_DIR" 2>/dev/null || true
  setfacl -R -m "g::rwx" "\$DATA_DIR" 2>/dev/null || true
else
  chmod -R a+rwX "\$DATA_DIR" 2>/dev/null || true
fi

# 2. UID-specific overrides (auto-generated from compose.yaml user: directives)
${uid_fix_lines}
# Exceptions: services with quirks not expressible in compose user:
[[ -d "\${DATA_DIR}/qdrant" ]] && chown -R 1000:1000 "\${DATA_DIR}/qdrant" 2>/dev/null || true
[[ -d "\${DATA_DIR}/searxng" ]] && chmod -R a+rwX "\${DATA_DIR}/searxng" 2>/dev/null || true
[[ -d "\${DATA_DIR}/models" ]] && chmod -R a+rwX "\${DATA_DIR}/models" 2>/dev/null || true

for d in "\${DATA_DIR}/comfyui/models" "\${DATA_DIR}/comfyui/output" "\${DATA_DIR}/comfyui/input"; do
  [[ -d "\$d" ]] && chmod -R a+rwX "\$d" 2>/dev/null || true
done

# 3. Scripts must be executable
find "\${SCRIPT_DIR}/scripts" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

echo "[✓] Permissions fixed"
PERMFIX_EOF

  chmod +x "${ds_dir}/scripts/fix-permissions.sh"
  log "Created reusable permission fixer: ${ds_dir}/scripts/fix-permissions.sh"
}

# Ensure Whisper UI can call its own API internally and that entrypoint remains executable.
# Without LOOPBACK_HOST_URL, Speaches Gradio may resolve to localhost:<host-port>
# inside the container and fail with "openai.APIConnectionError: Connection error.".
ensure_whisper_ui_compatibility() {
  local ds_dir="$1"
  local whisper_compose="${ds_dir}/extensions/services/whisper/compose.yaml"
  local whisper_entrypoint="${ds_dir}/extensions/services/whisper/docker-entrypoint.sh"

  # The whisper container waits for an executable bind-mounted entrypoint.
  # ACL normalization can drop owner execute bit, causing an infinite wait loop.
  if [[ -f "$whisper_entrypoint" ]]; then
    chmod 755 "$whisper_entrypoint" 2>/dev/null || true
  fi

  [[ ! -f "$whisper_compose" ]] && return 0

  if ! grep -q 'LOOPBACK_HOST_URL=' "$whisper_compose" 2>/dev/null; then
    if grep -q 'WHISPER__TTL=' "$whisper_compose" 2>/dev/null; then
      sed -i '/WHISPER__TTL=/a\      - LOOPBACK_HOST_URL=http://127.0.0.1:8000\n      - CHAT_COMPLETION_BASE_URL=http://llama-server:8080/v1\n      - CHAT_COMPLETION_API_KEY=cant-be-empty' "$whisper_compose"
      log "Injected Whisper UI loopback compatibility env"
    else
      warn "Whisper compose env block not found — skipped loopback injection"
    fi
  fi
}

# Map friendly WHISPER_MODEL values to Speaches-compatible model IDs.
map_whisper_model_id() {
  local raw="$1"
  case "${raw,,}" in
    tiny|tiny.en) echo "Systran/faster-whisper-tiny" ;;
    base|base.en|"" ) echo "Systran/faster-whisper-base" ;;
    small|small.en) echo "Systran/faster-whisper-small" ;;
    medium|medium.en) echo "Systran/faster-whisper-medium" ;;
    large|large-v2|large-v3) echo "Systran/faster-whisper-large-v3" ;;
    turbo|large-v3-turbo) echo "deepdml/faster-whisper-large-v3-turbo-ct2" ;;
    */*) echo "$raw" ;;
    *) echo "Systran/faster-whisper-base" ;;
  esac
}

# Ensure at least one ASR model is available so Speaches STT UI dropdown works.
ensure_whisper_asr_model() {
  local ds_dir="$1"
  local env_file="${ds_dir}/.env"
  local whisper_port whisper_cfg model_id encoded_model

  whisper_port="$(env_get "$env_file" "WHISPER_PORT")"
  whisper_port="${whisper_port:-9000}"

  if ! wait_for_http "http://127.0.0.1:${whisper_port}/health" 120 4; then
    warn "Whisper health endpoint not reachable on port ${whisper_port} — skipping ASR bootstrap"
    return 0
  fi

  local asr_count
  asr_count=$(curl -sf --max-time 12 "http://127.0.0.1:${whisper_port}/v1/models?task=automatic-speech-recognition" 2>/dev/null | jq -r '.data | length' 2>/dev/null || echo 0)
  if [[ "$asr_count" =~ ^[0-9]+$ ]] && [[ "$asr_count" -gt 0 ]]; then
    log "Whisper ASR models already available (${asr_count})"
    return 0
  fi

  whisper_cfg="$(env_get "$env_file" "WHISPER_MODEL")"
  model_id="$(map_whisper_model_id "$whisper_cfg")"
  encoded_model="${model_id//\//%2F}"

  warn "No ASR models available in Whisper — bootstrapping ${model_id}"
  if ! curl -sf -X POST --max-time 30 "http://127.0.0.1:${whisper_port}/v1/models/${encoded_model}" > /dev/null 2>&1; then
    warn "Could not trigger Whisper model download for ${model_id}"
    return 0
  fi

  local waited=0
  while [[ $waited -lt 180 ]]; do
    asr_count=$(curl -sf --max-time 12 "http://127.0.0.1:${whisper_port}/v1/models?task=automatic-speech-recognition" 2>/dev/null | jq -r '.data | length' 2>/dev/null || echo 0)
    if [[ "$asr_count" =~ ^[0-9]+$ ]] && [[ "$asr_count" -gt 0 ]]; then
      log "Whisper ASR model bootstrap complete (${asr_count} model(s) available)"
      return 0
    fi
    sleep 6
    waited=$((waited + 6))
  done

  warn "Whisper model download started but not ready yet — UI model list may appear after a few minutes"
}

# Patch OpenClaw's inject-token.js at runtime so local installs get the
# compatibility fixes without committing changes to the upstream repository.
patch_openclaw_inject_token_runtime() {
  local ds_dir="$1"
  local target="${ds_dir}/config/openclaw/inject-token.js"

  if [[ ! -f "$target" ]]; then
    warn "OpenClaw injector not found at ${target} — skipping runtime patch"
    return 0
  fi

  if ! command -v perl &>/dev/null; then
    warn "perl is missing — cannot patch ${target} automatically"
    return 0
  fi

  # Already patched? Keep this idempotent and quiet.
  if grep -q "const providerMap = config.models?.providers || config.providers || null;" "$target" \
    && grep -q "firstModel.name = LLM_MODEL;" "$target" \
    && grep -q "updated legacy agent model refs ->" "$target"; then
    log "OpenClaw injector patch already present: ${target}"
    return 0
  fi

  local before_hash after_hash subs
  before_hash=$(sha256sum "$target" 2>/dev/null | awk '{print $1}' || echo "")

  subs=$(perl -0777 -i - "$target" <<'PERL'
my $replacement = <<'JS';
  // Fix model references to match what llama-server actually serves
  if (LLM_MODEL) {
    // Find provider map across schema variants (models.providers or providers)
    const providerMap = config.models?.providers || config.providers || null;
    const providerName = providerMap ? Object.keys(providerMap)[0] : null;

    if (providerName && providerMap[providerName]) {
      const provider = providerMap[providerName];

      // Route through LiteLLM when OLLAMA_URL points to it, and pass credentials
      const ollamaUrl = process.env.OLLAMA_URL || '';
      const litellmKey = process.env.LITELLM_KEY || '';
      if (ollamaUrl) {
        const newBase = ollamaUrl.replace(/\/$/, '') + '/v1';
        if (provider.baseUrl !== newBase) {
          console.log(`[inject-token] updated provider baseUrl: ${provider.baseUrl} -> ${newBase}`);
          provider.baseUrl = newBase;
        }
        if (litellmKey && provider.apiKey !== litellmKey) {
          provider.apiKey = litellmKey;
          console.log(`[inject-token] updated provider apiKey from env`);
        }
      }

      // Update model list — support either `name` or `id` model key
      if (Array.isArray(provider.models) && provider.models.length > 0) {
        const firstModel = provider.models[0];
        if (firstModel && typeof firstModel === 'object') {
          const oldValue = firstModel.name || firstModel.id || '<unset>';
          if (firstModel.name !== LLM_MODEL || firstModel.id !== LLM_MODEL) {
            firstModel.name = LLM_MODEL;
            firstModel.id = LLM_MODEL;
            console.log(`[inject-token] updated provider model: ${oldValue} -> ${LLM_MODEL}`);
          }
        }
      }
    }

    // Update agents.defaults model references
    if (config.agents?.defaults) {
      const d = config.agents.defaults;
      const fullOld = d.model?.primary || '';
      if (fullOld && providerName) {
        const fullNew = `${providerName}/${LLM_MODEL}`;
        if (fullOld !== fullNew) {
          d.model = { primary: fullNew };
          // Rebuild models map
          d.models = { [fullNew]: {} };
          // Fix subagent model
          if (d.subagents) d.subagents.model = fullNew;
          console.log(`[inject-token] updated agent model refs: ${fullOld} -> ${fullNew}`);
        }
      }
    }

    // Update legacy schema references, if present
    if (config.agent && providerName) {
      const fullNew = `${providerName}/${LLM_MODEL}`;
      if (config.agent.model !== fullNew) {
        config.agent.model = fullNew;
        if (config.subagent) config.subagent.model = fullNew;
        console.log(`[inject-token] updated legacy agent model refs -> ${fullNew}`);
      }
    }
  }

  // Override LLM baseUrl for Token Spy monitoring (if OPENCLAW_LLM_URL is set)
JS

my $n = s{
\Q  // Fix model references to match what llama-server actually serves
  if (LLM_MODEL) {\E
.*?
\Q  }

  // Override LLM baseUrl for Token Spy monitoring (if OPENCLAW_LLM_URL is set)\E
}{$replacement}sx;

print $n;
PERL
)

  # If upstream formatting drifts, avoid hard-failing setup.
  if [[ "${subs:-0}" -eq 0 ]]; then
    if grep -q "const providerMap = config.models?.providers || config.providers || null;" "$target" \
      && grep -q "firstModel.name = LLM_MODEL;" "$target" \
      && grep -q "updated legacy agent model refs ->" "$target"; then
      log "OpenClaw injector patch already present: ${target}"
    else
      warn "OpenClaw injector patch pattern not found in ${target} — leaving file unchanged"
    fi
    return 0
  fi

  if grep -q "const providerMap = config.models?.providers || config.providers || null;" "$target" \
    && grep -q "firstModel.name = LLM_MODEL;" "$target" \
    && grep -q "updated legacy agent model refs ->" "$target"; then
    after_hash=$(sha256sum "$target" 2>/dev/null | awk '{print $1}' || echo "")
    if [[ -n "$before_hash" && "$before_hash" != "$after_hash" ]]; then
      log "Patched OpenClaw injector at runtime: ${target}"
    else
      log "OpenClaw injector patch already present: ${target}"
    fi
  else
    warn "OpenClaw injector patch could not be verified: ${target}"
  fi
}

# ── Apply all post-install fixes ────────────────────────────────────────────
apply_post_install_fixes() {
  local ds_dir="$1"
  local gpu_backend="${2:-auto}"
  local data_dir="${ds_dir}/data"
  local env_file="${ds_dir}/.env"
  local cpu_count
  cpu_count=$(nproc)

  # Auto-detect GPU backend if not passed
  if [[ "$gpu_backend" == "auto" ]]; then
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
      gpu_backend="nvidia"
    elif command -v rocm-smi &>/dev/null || [[ -e /dev/kfd ]]; then
      gpu_backend="amd"
    else
      gpu_backend="cpu"
    fi
  fi

  # Docker group
  if getent group docker &>/dev/null; then
    usermod -aG docker "$DREAM_USER" 2>/dev/null || true
  fi

  # CPU limit fix — cap to (actual - 1) if < 16
  if [[ $cpu_count -lt 16 ]]; then
    local max_cpu=$(( cpu_count > 1 ? cpu_count - 1 : 1 ))
    cap_cpu_in_yaml "$ds_dir" "$max_cpu"
    log "CPU limits capped to ${max_cpu} (instance has ${cpu_count} cores)"
  fi

  # ── Permission system (replaces ad-hoc chmod 777) ────────────────────────
  ensure_acl_tools
  precreate_extension_data_dirs "$ds_dir"
  apply_data_acl "$data_dir"
  fix_known_uid_requirements "$data_dir" "$gpu_backend"
  configure_dream_umask
  create_permission_fix_script "$ds_dir"

  # Also apply ACLs to extension directories and user-extensions
  apply_data_acl "${ds_dir}/extensions" 2>/dev/null || true
  if [[ -d "${ds_dir}/user-extensions" ]]; then
    apply_data_acl "${ds_dir}/user-extensions"
  fi

  # Voice stack compatibility (Speaches UI loopback + executable entrypoint)
  ensure_whisper_ui_compatibility "$ds_dir"

  # Apply runtime-only OpenClaw injector compatibility patch.
  patch_openclaw_inject_token_runtime "$ds_dir"

  # Scripts must be executable
  find "${ds_dir}/scripts" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

  # Logs directory — dream user + containers both write here
  mkdir -p "${ds_dir}/logs"
  apply_data_acl "${ds_dir}/logs" 2>/dev/null || true

  # ── Environment variables ────────────────────────────────────────────────
  if [[ -f "$env_file" ]]; then
    # WEBUI_SECRET — open-webui crashes without it
    local existing_secret
    existing_secret=$(env_get "$env_file" "WEBUI_SECRET")
    if [[ -z "$existing_secret" ]]; then
      env_set "$env_file" "WEBUI_SECRET" "$(openssl rand -hex 32)"
      log "Generated WEBUI_SECRET"
    fi

    # SEARXNG_SECRET — searxng needs this too
    local existing_searxng
    existing_searxng=$(env_get "$env_file" "SEARXNG_SECRET")
    if [[ -z "$existing_searxng" ]]; then
      env_set "$env_file" "SEARXNG_SECRET" "$(openssl rand -hex 32)"
      log "Generated SEARXNG_SECRET"
    fi

    # GGUF_FILE — detect from data/models if not set
    local existing_gguf
    existing_gguf=$(env_get "$env_file" "GGUF_FILE")
    if [[ -z "$existing_gguf" ]]; then
      local first_model
      first_model=$(find "${data_dir}/models/" -maxdepth 1 -name "*.gguf" -type f -printf '%s %f\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
      if [[ -n "$first_model" ]]; then
        env_set "$env_file" "GGUF_FILE" "$first_model"
        log "Set GGUF_FILE=${first_model}"
      fi
    fi
  fi

  log "Post-install fixes applied (including ACL-based permission system)"
}

# ── Start services ──────────────────────────────────────────────────────────
start_services() {
  local ds_dir="$1"
  local gpu_backend="${2:-auto}"  # auto-detect if not passed
  local compose_cmd
  compose_cmd=$(get_compose_cmd)

  cd "$ds_dir"

  # Auto-detect GPU backend
  if [[ "$gpu_backend" == "auto" ]]; then
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
      gpu_backend="nvidia"
    elif command -v rocm-smi &>/dev/null || [[ -e /dev/kfd ]]; then
      gpu_backend="amd"
    else
      gpu_backend="cpu"
    fi
  fi

  # Determine the GPU overlay file
  local gpu_overlay="docker-compose.${gpu_backend}.yml"
  if [[ ! -f "$gpu_overlay" && "$gpu_backend" != "cpu" ]]; then
    warn "GPU overlay ${gpu_overlay} not found — falling back to nvidia"
    gpu_overlay="docker-compose.nvidia.yml"
  fi

  # Build compose flags
  local compose_flags="-f docker-compose.base.yml"
  if [[ "$gpu_backend" != "cpu" && -f "$gpu_overlay" ]]; then
    compose_flags="${compose_flags} -f ${gpu_overlay}"
  fi

  # Use DreamServer's own compose stack resolver if available
  if [[ -x "${ds_dir}/scripts/resolve-compose-stack.sh" ]]; then
    log "Using DreamServer's resolve-compose-stack.sh"
    local resolved_flags
    resolved_flags=$(su - "$DREAM_USER" -c "cd ${ds_dir} && ./scripts/resolve-compose-stack.sh 2>/dev/null" || true)
    if [[ -n "$resolved_flags" ]]; then
      compose_flags="$resolved_flags"
    fi
  fi

  # DreamServer declares an external network; create it if missing.
  if ! docker network inspect dream-network >/dev/null 2>&1; then
    if docker network create dream-network >/dev/null 2>&1; then
      log "Created missing external Docker network: dream-network"
    else
      warn "Could not pre-create dream-network; compose may create it during fallback"
    fi
  fi

  su - "$DREAM_USER" -c "cd ${ds_dir} && ${compose_cmd} ${compose_flags} up -d" 2>&1 || {
    warn "Full compose failed — trying core services only"
    su - "$DREAM_USER" -c "cd ${ds_dir} && ${compose_cmd} ${compose_flags} up -d llama-server dashboard-api open-webui dashboard" 2>&1 || true
  }

  # Nudge dashboard if stuck in Created state (known Vast.ai issue)
  if docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q 'dream-dashboard Created'; then
    docker start dream-dashboard 2>/dev/null || true
    log "Kicked dashboard out of Created state"
  fi
}

# ── Optimize model download ────────────────────────────────────────────────
optimize_model_download() {
  local ds_dir="$1"
  local data_dir="${ds_dir}/data"
  local env_file="${ds_dir}/.env"

  # Find incomplete .part downloads
  local part_files
  part_files=$(find "${data_dir}/models/" -name "*.gguf.part" -type f 2>/dev/null || true)

  if [[ -z "$part_files" ]]; then
    # Check if aria2c is already handling it
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
  part_size_mb=$(( $(stat -c%s "$part_file" 2>/dev/null || echo 0) / 1048576 ))

  warn "Incomplete download: ${part_name} (${part_size_mb} MB so far)"

  # Kill slow single-stream downloaders
  pkill -f "curl.*${part_name}" 2>/dev/null || true
  pkill -f "wget.*${part_name}" 2>/dev/null || true
  sleep 2

  # Resolve download URL dynamically from DreamServer's own tier-map or .env
  gguf_url=$(resolve_model_url "$ds_dir" "$part_name")

  if [[ -z "$gguf_url" ]]; then
    warn "Could not resolve download URL for ${part_name} — leaving original download"
    return 0
  fi

  log "Restarting download with aria2c (8 threads)..."

  # Remove .part file — aria2c manages its own resume state via .aria2 control files
  rm -f "$part_file"

  mkdir -p "${ds_dir}/logs"

  # aria2c: 8 connections, 10M chunks, infinite retries, exponential backoff
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

  # Create model-swap watcher
  create_model_swap_watcher "$ds_dir" "$part_name"
}

# ── Resolve model URL from DreamServer's tier-map / .env ────────────────────
resolve_model_url() {
  local ds_dir="$1" model_name="$2"
  local url=""

  # Strategy 1: Check the model-upgrade log for the original URL
  local upgrade_log="${ds_dir}/logs/model-upgrade.log"
  if [[ -f "$upgrade_log" ]]; then
    url=$(grep -oP 'https://huggingface\.co/[^\s"]+'"${model_name}" "$upgrade_log" 2>/dev/null | tail -1 || true)
    if [[ -n "$url" ]]; then
      echo "$url"
      return 0
    fi
  fi

  # Strategy 2: Parse the tier-map config for model URLs
  local tier_map="${ds_dir}/installers/lib/tier-map.sh"
  if [[ -f "$tier_map" ]]; then
    url=$(grep -oP 'https://huggingface\.co/[^\s"'"'"']+'"${model_name}" "$tier_map" 2>/dev/null | head -1 || true)
    if [[ -n "$url" ]]; then
      echo "$url"
      return 0
    fi
  fi

  # Strategy 3: Search all config/backend JSON files
  local backend_dir="${ds_dir}/config/backends"
  if [[ -d "$backend_dir" ]]; then
    url=$(grep -rhoP 'https://huggingface\.co/[^\s"]+'"${model_name}" "$backend_dir" 2>/dev/null | head -1 || true)
    if [[ -n "$url" ]]; then
      echo "$url"
      return 0
    fi
  fi

  # Strategy 4: Construct URL from model name convention
  # Pattern: <org>/<model>-GGUF -> https://huggingface.co/<org>/<model>-GGUF/resolve/main/<filename>
  # Common DreamServer orgs: unsloth, bartowski, lmstudio-community
  local base_name
  # Extract model family from filename: e.g., "Qwen3-30B-A3B-Q4_K_M.gguf" -> "Qwen3-30B-A3B"
  base_name=$(echo "$model_name" | sed -E 's/-[QqFf][0-9_]+[A-Za-z]*\.gguf$//')

  if [[ -n "$base_name" ]]; then
    # Try common HuggingFace orgs used by DreamServer
    local org
    for org in "unsloth" "bartowski" "lmstudio-community"; do
      local test_url="https://huggingface.co/${org}/${base_name}-GGUF/resolve/main/${model_name}"
      if curl -sfI --max-time 10 "$test_url" 2>/dev/null | grep -qi "200\|302\|301"; then
        echo "$test_url"
        return 0
      fi
    done
  fi

  # Could not resolve
  return 1
}

# ── Model swap watcher ──────────────────────────────────────────────────────
create_model_swap_watcher() {
  local ds_dir="$1" model_name="$2"
  local watcher_script="${ds_dir}/scripts/model-swap-on-complete.sh"

  mkdir -p "${ds_dir}/scripts"

  cat > "$watcher_script" << 'WATCHER_EOF'
#!/usr/bin/env bash
set -euo pipefail
# Auto-swap model when aria2c download completes
# Generated by dreamserver-vastai-setup.sh

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="${SCRIPT_DIR}/data/models"
ENV_FILE="${SCRIPT_DIR}/.env"

swap_model() {
  local new_model="$1"
  local old_model
  old_model=$(grep '^GGUF_FILE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)

  if [[ "$new_model" == "$old_model" ]]; then
    return 0
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Swapping model: ${old_model} -> ${new_model}"

  # Preserve .env inode (cat > instead of mv, per DreamServer convention)
  local tmp_env
  tmp_env=$(mktemp)
  sed "s|^GGUF_FILE=.*|GGUF_FILE=${new_model}|" "$ENV_FILE" > "$tmp_env"
  cat "$tmp_env" > "$ENV_FILE"
  rm -f "$tmp_env"

  # Restart llama-server for hot-swap
  docker restart dream-llama-server 2>/dev/null || true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Swapped to ${new_model} — llama-server restarting"
}

# Poll until aria2c finishes
while true; do
  if ! pgrep -f "aria2c.*gguf" > /dev/null 2>&1; then
    # Find largest completed .gguf file (the newly downloaded one)
    local_model=$(ls -S "${MODEL_DIR}"/*.gguf 2>/dev/null | head -1 | xargs -r basename)
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

# ── Print access info ───────────────────────────────────────────────────────
print_access_info() {
  local ds_dir="$1"
  local env_file="${ds_dir}/.env"

  # Detect Vast.ai environment variables
  local host_ip ssh_port
  host_ip="${PUBLIC_IPADDR:-$(curl -sf --max-time 5 ifconfig.me 2>/dev/null || echo '<your-vast-ip>')}"
  ssh_port="${VAST_TCP_PORT_22:-22}"

  # Check if reverse proxy is active [T1]
  local proxy_port
  proxy_port="$(env_get "$env_file" "REVERSE_PROXY_PORT")"

  echo ""
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}${BOLD}  DreamServer is ready on Vast.ai!${NC}"
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "${BOLD}Working directory:${NC} ${ds_dir}"
  echo -e "${BOLD}Setup log:${NC}         ${LOGFILE}"
  echo ""

  # ── [T1] Reverse proxy access (preferred) ──────────────────────────────
  if [[ -n "$proxy_port" ]] && pgrep -x caddy > /dev/null 2>&1; then
    echo -e "${GREEN}${BOLD}▸ Reverse Proxy Active (single-port access!)${NC}"
    echo ""
    echo -e "  All services via ONE port: ${BOLD}http://${host_ip}:${proxy_port}/${NC}"
    echo ""
    echo -e "  ${BOLD}Quick Access:${NC}"
    echo "    Open WebUI:     http://${host_ip}:${proxy_port}/"
    echo "    Dashboard:      http://${host_ip}:${proxy_port}/dashboard/"
    echo "    ComfyUI:        http://${host_ip}:${proxy_port}/comfyui/"
    echo "    n8n Workflows:  http://${host_ip}:${proxy_port}/n8n/"
    echo "    Whisper STT:    http://${host_ip}:${proxy_port}/whisper/"
    echo "    Kokoro TTS:     http://${host_ip}:${proxy_port}/tts/"
    echo "    Health Status:  http://${host_ip}:${proxy_port}/health"
    echo "    LLM API (v1):   http://${host_ip}:${proxy_port}/v1/"
    echo ""
    echo -e "  ${DIM}No SSH tunnels needed! Access from any browser, phone, or iPad.${NC}"
    echo ""
  fi

  # ── [T2/T8] SSH tunnel (dynamic ports + auto-reconnect) ────────────────
  echo -e "${BOLD}SSH Tunnel (alternative — use if reverse proxy is unavailable):${NC}"
  echo ""

  # Build tunnel command dynamically from .env [T2]
  echo -n -e "${DIM}ssh -p ${ssh_port}"
  discover_service_ports "$ds_dir" | while IFS='|' read -r _key port _label; do
    echo -n " \\"
    echo ""
    echo -n "  -L ${port}:127.0.0.1:${port}"
  done
  echo " \\"
  echo -e "  root@${host_ip}${NC}"
  echo ""

  # [T8] Auto-reconnect tunnel script
  if [[ -f "${ds_dir}/connect-tunnel.sh" ]]; then
    echo -e "  ${BOLD}Auto-reconnecting tunnel:${NC} scp + run connect-tunnel.sh on your local machine"
    echo -e "  ${DIM}scp -P ${ssh_port} root@${host_ip}:${ds_dir}/connect-tunnel.sh . && bash connect-tunnel.sh${NC}"
    echo ""
  fi

  # ── [T2/T6] Service list (dynamic from .env) ──────────────────────────
  echo -e "${BOLD}Services:${NC}"
  discover_service_ports "$ds_dir" | while IFS='|' read -r key port label; do
    printf "  %-22s http://localhost:%s\n" "${label}:" "${port}"
  done
  echo ""

  # ── Model transfer help [T11] ──────────────────────────────────────────
  echo -e "${BOLD}Upload Custom Models:${NC}"
  echo "  # LLM models (.gguf):"
  echo "  scp -P ${ssh_port} my-model.gguf root@${host_ip}:${ds_dir}/data/models/"
  echo ""
  echo "  # ComfyUI models (.safetensors):"
  echo "  scp -P ${ssh_port} my-checkpoint.safetensors root@${host_ip}:${ds_dir}/data/comfyui/models/checkpoints/"
  echo "  scp -P ${ssh_port} my-lora.safetensors       root@${host_ip}:${ds_dir}/data/comfyui/models/loras/"
  echo ""
  echo "  # After upload, update the active LLM model:"
  echo "  #   Edit .env: GGUF_FILE=my-model.gguf"
  echo "  #   Then: docker restart dream-llama-server"
  echo ""

  echo -e "${BOLD}Commands:${NC}"
  echo "  bash ${SCRIPT_NAME} --status     # Check health"
  echo "  bash ${SCRIPT_NAME} --teardown   # Stop all (save \$\$\$)"
  echo "  bash ${SCRIPT_NAME} --resume     # Restart after SSH drop"
  echo "  docker ps                         # Container status"
  echo "  nvidia-smi                        # GPU usage"
  if [[ -f "${ds_dir}/logs/aria2c-download.log" ]]; then
    echo "  tail -f ${ds_dir}/logs/aria2c-download.log  # Download progress"
  fi
  echo ""
  echo -e "${BOLD}Background Services:${NC}"
  echo "  Heavy services (ComfyUI, Whisper, Kokoro) download models on first boot."
  echo "  They will become available automatically — no action needed."
  echo "  Check status anytime: bash ${SCRIPT_NAME} --status"
  echo ""
}

#=============================================================================
#
#  MAIN INSTALL FLOW
#
#=============================================================================

main() {
  # Route subcommands
  case "${1:-}" in
    --teardown|teardown)  cmd_teardown; exit 0 ;;
    --status|status)      cmd_status; exit 0 ;;
    --resume|resume)      cmd_resume; exit 0 ;;
    --version)            echo "dreamserver-vastai-setup v${SCRIPT_VERSION}"; exit 0 ;;
    --help|-h)
      echo "Usage: bash ${SCRIPT_NAME} [--teardown|--status|--resume|--version]"
      exit 0
      ;;
  esac

  # ── Preamble ──────────────────────────────────────────────────────────────
  echo ""
  echo -e "${CYAN}${BOLD}  DreamServer — Vast.ai Setup v${SCRIPT_VERSION}${NC}"
  echo -e "${DIM}  https://github.com/Light-Heart-Labs/DreamServer${NC}"
  echo ""

  acquire_lock
  mkdir -p "$(dirname "$LOGFILE")"
  echo "=== Setup started at $(_ts) ===" >> "$LOGFILE"

  #=========================================================================
  # Phase 0: Preflight checks
  #=========================================================================
  step "Phase 0/15: Preflight checks"

  # Must be root
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Run: sudo bash ${SCRIPT_NAME}"
    exit 1
  fi

  # ── GPU detection (NVIDIA / AMD / CPU-only) ──────────────────────────────
  # Vast.ai offers NVIDIA (majority), AMD MI300X, and CPU-only instances.
  # DreamServer supports all three via compose overlays:
  #   nvidia → docker-compose.nvidia.yml
  #   amd    → docker-compose.amd.yml
  #   cpu    → (base only, no GPU overlay)

  local GPU_BACKEND="cpu"   # default fallback
  local gpu_name="none"
  local gpu_vram="0"
  local gpu_count=0

  if command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=name --format=csv,noheader &>/dev/null 2>&1; then
    GPU_BACKEND="nvidia"
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)
    gpu_vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | xargs)
    gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
    log "NVIDIA GPU detected: ${gpu_name} × ${gpu_count} (${gpu_vram} MiB VRAM each)"

  elif command -v rocm-smi &>/dev/null || [[ -e /dev/kfd ]]; then
    GPU_BACKEND="amd"
    gpu_name=$(rocm-smi --showproductname 2>/dev/null | grep -oP 'Card series:\s*\K.*' | head -1 || echo "AMD GPU")
    gpu_vram=$(rocm-smi --showmeminfo vram 2>/dev/null | grep -oP 'Total Memory \(B\):\s*\K[0-9]+' | head -1 || echo "0")
    # Convert bytes to MiB
    if [[ "${gpu_vram:-0}" -gt 1000000 ]]; then
      gpu_vram=$(( gpu_vram / 1048576 ))
    fi
    gpu_count=$(rocm-smi --showid 2>/dev/null | grep -c 'GPU\[' || echo 1)
    log "AMD GPU detected: ${gpu_name} × ${gpu_count} (${gpu_vram} MiB VRAM)"

  else
    warn "No GPU detected — running in CPU-only mode"
    warn "DreamServer will use CPU inference (slower but functional)"
    gpu_vram=0
  fi

  local cpu_count disk_avail_gb
  cpu_count=$(nproc)
  disk_avail_gb=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')

  log "GPU backend: ${GPU_BACKEND} | CPUs: ${cpu_count} | Disk: ${disk_avail_gb} GB"

  # VRAM check (skip for CPU-only)
  if [[ "$GPU_BACKEND" != "cpu" && "${gpu_vram:-0}" -lt "$MIN_VRAM_MB" ]]; then
    warn "GPU VRAM (${gpu_vram} MiB) is below recommended (${MIN_VRAM_MB} MiB)."
    warn "Small models will still work. Large models may OOM."
  fi

  # Disk space check — Vast.ai disks are static, cannot be resized
  if [[ "${disk_avail_gb:-0}" -lt "$MIN_DISK_GB" ]]; then
    err "Disk space (${disk_avail_gb} GB) is below minimum (${MIN_DISK_GB} GB)."
    err "DreamServer needs 40+ GB. Create a new Vast.ai instance with more disk."
    exit 1
  fi

  # Docker check
  if ! command -v docker &>/dev/null; then
    err "Docker not found. Use a Vast.ai image with Docker pre-installed."
    exit 1
  fi

  # Docker Compose check
  local compose_cmd
  compose_cmd=$(get_compose_cmd)
  log "Docker Compose: ${compose_cmd} ($(${compose_cmd} version --short 2>/dev/null || echo 'unknown'))"

  # Verify GPU passthrough into Docker (NVIDIA-specific)
  if [[ "$GPU_BACKEND" == "nvidia" ]]; then
    if ! docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi &>/dev/null 2>&1; then
      warn "NVIDIA GPU passthrough test failed — checking nvidia-container-toolkit..."
      if ! dpkg -l nvidia-container-toolkit &>/dev/null 2>&1; then
        warn "nvidia-container-toolkit not installed — attempting install"
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
          | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
          | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
          | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
        apt-get update -qq && apt-get install -y -qq nvidia-container-toolkit > /dev/null 2>&1
        nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
        systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
        log "nvidia-container-toolkit installed and configured"
      fi
    else
      log "NVIDIA Docker passthrough verified"
    fi
  elif [[ "$GPU_BACKEND" == "amd" ]]; then
    # AMD GPU passthrough check — verify /dev/kfd and /dev/dri are accessible
    if [[ ! -e /dev/kfd ]]; then
      warn "/dev/kfd not found — AMD GPU may not be accessible from containers"
    fi
    if [[ ! -d /dev/dri ]]; then
      warn "/dev/dri not found — AMD GPU rendering may not work"
    fi
    # Check for ROCm Docker support
    if docker run --rm --device=/dev/kfd --device=/dev/dri rocm/rocm-terminal:latest rocm-smi &>/dev/null 2>&1; then
      log "AMD ROCm Docker passthrough verified"
    else
      warn "AMD ROCm Docker test failed — GPU may need driver configuration"
    fi
  fi

  # DNS check — some Vast.ai instances have broken resolv.conf
  if ! host github.com &>/dev/null 2>&1 && ! nslookup github.com &>/dev/null 2>&1; then
    if ! curl -sf --max-time 5 https://github.com > /dev/null 2>&1; then
      warn "DNS resolution may be broken — adding Google DNS as fallback"
      if ! grep -q '8.8.8.8' /etc/resolv.conf 2>/dev/null; then
        echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
      fi
    fi
  fi

  log "All preflight checks passed"

  #=========================================================================
  # Phase 1: System dependencies
  #=========================================================================
  step "Phase 1/15: Installing system dependencies"

  # Only install what's missing
  local pkgs_needed=()
  for pkg in sudo git curl jq wget openssl aria2 procps iproute2 acl; do
    if ! command -v "$pkg" &>/dev/null 2>&1; then
      pkgs_needed+=("$pkg")
    fi
  done
  # Special: ss is in iproute2, not its own binary
  if ! command -v ss &>/dev/null 2>&1; then
    pkgs_needed+=("iproute2")
  fi

  if [[ ${#pkgs_needed[@]} -gt 0 ]]; then
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq "${pkgs_needed[@]}" > /dev/null 2>&1
    log "Installed: ${pkgs_needed[*]}"
  else
    log "All dependencies already present"
  fi

  #=========================================================================
  # Phase 2: /tmp permissions
  #=========================================================================
  step "Phase 2/15: Fixing /tmp permissions"

  if [[ "$(stat -c '%a' /tmp 2>/dev/null)" != "1777" ]]; then
    chown root:root /tmp
    chmod 1777 /tmp
    log "/tmp permissions fixed (was broken)"
  else
    log "/tmp permissions OK"
  fi

  #=========================================================================
  # Phase 3: Create non-root user
  #=========================================================================
  step "Phase 3/15: Creating user '${DREAM_USER}'"

  if id -u "$DREAM_USER" &>/dev/null; then
    log "User '${DREAM_USER}' already exists"
  else
    useradd -m -s /bin/bash -u 1000 "$DREAM_USER" 2>/dev/null || \
      useradd -m -s /bin/bash "$DREAM_USER"
    log "User '${DREAM_USER}' created"
  fi

  # Sudo + docker group
  usermod -aG sudo "$DREAM_USER" 2>/dev/null || true
  echo "${DREAM_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-dream
  chmod 440 /etc/sudoers.d/90-dream

  if getent group docker &>/dev/null; then
    usermod -aG docker "$DREAM_USER"
    log "Added ${DREAM_USER} to docker group"
  fi

  # Copy SSH keys so user can be accessed directly
  if [[ -d /root/.ssh && ! -d "${DREAM_HOME}/.ssh" ]]; then
    cp -r /root/.ssh "${DREAM_HOME}/.ssh"
    chown -R "${DREAM_USER}:${DREAM_USER}" "${DREAM_HOME}/.ssh"
    chmod 700 "${DREAM_HOME}/.ssh"
    chmod 600 "${DREAM_HOME}/.ssh/"* 2>/dev/null || true
  fi

  log "User configured"

  #=========================================================================
  # Phase 4: Clone / locate repository
  #=========================================================================
  step "Phase 4/15: Setting up DreamServer repository"

  local repo_dir="${DREAM_HOME}/DreamServer"

  # Check if repo already exists from a previous run
  if [[ -d "${repo_dir}/.git" ]]; then
    log "Repository already exists at ${repo_dir}"
    # Pull latest if possible (non-fatal)
    su - "$DREAM_USER" -c "cd ${repo_dir} && git pull --ff-only 2>/dev/null" || \
      warn "Could not pull latest (non-fatal — using existing checkout)"
  else
    # Check if repo was cloned elsewhere (some Vast.ai onstart scripts do this)
    local found_repo=""
    for candidate in /root/DreamServer /workspace/DreamServer /opt/DreamServer; do
      if [[ -d "${candidate}/.git" ]]; then
        found_repo="$candidate"
        break
      fi
    done

    if [[ -n "$found_repo" ]]; then
      mv "$found_repo" "$repo_dir"
      log "Moved repository from ${found_repo}"
    else
      su - "$DREAM_USER" -c "git clone --depth 1 --branch ${REPO_BRANCH} ${REPO_URL} ${repo_dir}"
      log "Cloned DreamServer (shallow, branch: ${REPO_BRANCH})"
    fi
  fi

  fix_ownership "$repo_dir" "$DREAM_USER"

  #=========================================================================
  # Phase 5: Run DreamServer installer (with timeout protection)
  #=========================================================================
  step "Phase 5/15: Running DreamServer installer"

  # ── Why timeout? ────────────────────────────────────────────────────────
  # The DreamServer installer's Phase 6 "Systems Online" polls EVERY enabled
  # service's health endpoint sequentially. Heavy services block it:
  #   - ComfyUI: downloads SDXL/FLUX checkpoints (6-12 GB) on first start
  #   - Perplexica: pulls SearXNG index + embedding models
  #   - Whisper/Kokoro: pull model weights
  #
  # We DON'T disable these services — they should start and download in
  # background. We just cap the installer time so it doesn't hang forever.
  # After timeout, our own Phase 11 starts everything properly and reports
  # background download status instead of blocking on health checks.

  local INSTALLER_TIMEOUT=600  # 10 minutes
  warn "Running installer (${INSTALLER_TIMEOUT}s timeout)..."
  warn "Heavy services (ComfyUI, Whisper, etc.) will continue downloading after timeout."

  local install_exit=0
  local installer_pid

  # Run installer in background so we can enforce timeout
  su - "$DREAM_USER" -c "cd ${repo_dir} && ./install.sh --non-interactive" &
  installer_pid=$!

  # Wait with timeout
  local waited=0
  while kill -0 "$installer_pid" 2>/dev/null; do
    if [[ $waited -ge $INSTALLER_TIMEOUT ]]; then
      warn "Installer reached ${INSTALLER_TIMEOUT}s limit — proceeding with our own setup"
      warn "Heavy services are still downloading in background (this is fine)"
      # Kill the installer's wait loop, not the services themselves
      kill -TERM "$installer_pid" 2>/dev/null || true
      sleep 2
      kill -9 "$installer_pid" 2>/dev/null || true
      # Kill any hanging docker-compose wait/health-check processes ONLY
      # (NOT the actual containers — they should keep running)
      pkill -f "Linking.*\[.*s\]" 2>/dev/null || true
      install_exit=124  # timeout exit code
      break
    fi
    sleep 5
    waited=$((waited + 5))

    # Print progress every 60s
    if (( waited % 60 == 0 )); then
      log "Installer running... (${waited}s / ${INSTALLER_TIMEOUT}s max)"
    fi
  done

  # Collect exit code if installer finished naturally
  if [[ $install_exit -ne 124 ]]; then
    wait "$installer_pid" 2>/dev/null || install_exit=$?
  fi

  if [[ $install_exit -eq 0 ]]; then
    log "DreamServer installer completed successfully"
  elif [[ $install_exit -eq 124 ]]; then
    log "Installer timed out (normal for heavy services) — continuing with setup"
  else
    warn "Installer exited with code ${install_exit} — applying fixes and continuing"
  fi

  #=========================================================================
  # Phase 6: Locate active working directory
  #=========================================================================
  step "Phase 6/15: Locating active dream-server directory"

  local ds_dir
  ds_dir=$(find_dream_dir) || {
    err "Could not find dream-server directory after install"
    err "Expected at: ${DREAM_HOME}/dream-server or ${repo_dir}/dream-server"
    exit 1
  }

  log "Active directory: ${ds_dir}"
  fix_ownership "$ds_dir" "$DREAM_USER"

  #=========================================================================
  # Phase 7: Post-install fixes
  #=========================================================================
  step "Phase 7/15: Applying post-install fixes"

  apply_post_install_fixes "$ds_dir" "$GPU_BACKEND"

  # Also fix the secondary directory if it exists (installer duality)
  local alt_dir=""
  if [[ "$ds_dir" == "${DREAM_HOME}/dream-server" && -d "${repo_dir}/dream-server" ]]; then
    alt_dir="${repo_dir}/dream-server"
  elif [[ "$ds_dir" == "${repo_dir}/dream-server" && -d "${DREAM_HOME}/dream-server" ]]; then
    alt_dir="${DREAM_HOME}/dream-server"
  fi

  if [[ -n "$alt_dir" && -f "${alt_dir}/.env" ]]; then
    apply_post_install_fixes "$alt_dir" "$GPU_BACKEND"
    log "Also fixed secondary directory: ${alt_dir}"
  fi

  #=========================================================================
  # Phase 8: Guarantee bootstrap model exists
  #=========================================================================
  step "Phase 8/15: Ensuring bootstrap model is available"

  # The #1 cause of "Linking llama-server [infinite]" is: the GGUF_FILE
  # env var points to a model that doesn't exist or is still downloading.
  # llama-server starts, can't find the model, crashes, Docker restarts it,
  # the health check never passes, and the installer hangs forever.
  #
  # Fix: verify the model file actually exists. If not, download a small
  # bootstrap model synchronously so llama-server has something to load.

  local env_file="${ds_dir}/.env"
  local data_dir="${ds_dir}/data"
  local gguf_file models_dir model_path

  gguf_file=$(env_get "$env_file" "GGUF_FILE")
  models_dir="${data_dir}/models"
  mkdir -p "$models_dir"

  # Check if the configured model actually exists
  local model_ready=false
  if [[ -n "$gguf_file" ]]; then
    model_path="${models_dir}/${gguf_file}"
    if [[ -f "$model_path" ]]; then
      local file_size
      file_size=$(stat -c%s "$model_path" 2>/dev/null || echo 0)
      if [[ $file_size -gt 100000000 ]]; then  # > 100MB = probably valid
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

  # Check for ANY .gguf file if the configured one doesn't exist
  if [[ "$model_ready" != "true" ]]; then
    local any_model
    any_model=$(find "$models_dir" -name "*.gguf" -size +100M 2>/dev/null | head -1 || true)
    if [[ -n "$any_model" ]]; then
      local found_name
      found_name=$(basename "$any_model")
      env_set "$env_file" "GGUF_FILE" "$found_name"
      model_ready=true
      log "Found existing model: ${found_name} — updated GGUF_FILE"
    fi
  fi

  # Last resort: download a small bootstrap model synchronously
  if [[ "$model_ready" != "true" ]]; then
    warn "No usable model found — downloading bootstrap model..."
    local bootstrap_url="https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf"
    local bootstrap_name="Qwen3-0.6B-Q4_K_M.gguf"

    # Use aria2c for speed, fallback to curl
    if command -v aria2c &>/dev/null; then
      aria2c -x 8 -s 8 -k 5M \
        --file-allocation=none \
        --console-log-level=notice \
        -d "$models_dir" -o "$bootstrap_name" \
        "$bootstrap_url" 2>&1 | tail -5
    else
      curl -L --progress-bar -o "${models_dir}/${bootstrap_name}" "$bootstrap_url"
    fi

    if [[ -f "${models_dir}/${bootstrap_name}" ]]; then
      env_set "$env_file" "GGUF_FILE" "$bootstrap_name"
      model_ready=true
      log "Bootstrap model downloaded: ${bootstrap_name}"
    else
      err "Failed to download bootstrap model — llama-server will not start"
      warn "Continuing anyway — other services may still work"
    fi
  fi

  # Fix ownership on models directory (aria2c runs as root, but dream user needs access)
  fix_known_uid_requirements "$data_dir" "$GPU_BACKEND"
  apply_data_acl "$models_dir" 2>/dev/null || true

  #=========================================================================
  # Phase 9: Optimize background model downloads
  #=========================================================================
  step "Phase 9/15: Optimizing model downloads"

  optimize_model_download "$ds_dir"

  #=========================================================================
  # Phase 10: Handle Vast.ai environment quirks
  #=========================================================================
  step "Phase 10/15: Applying Vast.ai-specific fixes"

  # ── No systemd ──────────────────────────────────────────────────────────
  # Vast.ai instances typically don't have systemd (they use init/runit).
  # DreamServer's host-agent installs as a systemd service, which fails.
  # Fix: start host-agent manually in background if dream-cli is available.

  if ! command -v systemctl &>/dev/null && ! pidof systemd &>/dev/null; then
    log "No systemd detected — Vast.ai environment confirmed"

    local dream_cli="${ds_dir}/dream-cli"
    if [[ -x "$dream_cli" ]]; then
      # Start host agent in background (non-systemd mode)
      su - "$DREAM_USER" -c "cd ${ds_dir} && ./dream-cli agent start" 2>/dev/null || \
        warn "Host agent start failed (non-fatal — dashboard may have limited features)"
    fi
  fi

  # ── Disable non-essential extensions that fail on Vast.ai ────────────────
  # OpenCode requires interactive setup and auto-generated passwords that
  # may not be configured. If it's failing, disable it to unblock everything.

  if docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q 'dream-opencode.*Restarting'; then
    warn "OpenCode is crash-looping — disabling to unblock other services"
    local dream_cli="${ds_dir}/dream-cli"
    if [[ -x "$dream_cli" ]]; then
      su - "$DREAM_USER" -c "cd ${ds_dir} && ./dream-cli disable opencode" 2>/dev/null || true
    else
      # Manual disable: stop the container
      docker stop dream-opencode 2>/dev/null || true
      docker rm dream-opencode 2>/dev/null || true
    fi
  fi

  # ── Shared memory fix ──────────────────────────────────────────────────
  # Some Vast.ai instances have tiny /dev/shm (64MB default). GPU containers
  # need more for CUDA IPC. Check and warn.
  local shm_size_kb
  shm_size_kb=$(df /dev/shm 2>/dev/null | awk 'NR==2{print $2}' || echo 0)
  if [[ "${shm_size_kb:-0}" -lt 1048576 ]]; then  # < 1GB
    local shm_mb=$(( shm_size_kb / 1024 ))
    warn "/dev/shm is only ${shm_mb} MB — GPU containers may be memory-starved"
    warn "If llama-server crashes with OOM, recreate instance with --shm-size 4g"
    # Try to remount with more space (works on some Vast.ai instances)
    mount -o remount,size=4G /dev/shm 2>/dev/null || true
  fi

  log "Vast.ai environment fixes applied"

  #=========================================================================
  # Phase 10b: Pre-pull Docker images in parallel
  #=========================================================================
  prepull_docker_images "$ds_dir"

  #=========================================================================
  # Phase 11: Start services + verify
  #=========================================================================
  step "Phase 11/15: Starting services"

  start_services "$ds_dir"

  # ── Smart health-check loop with llama-server diagnostics ────────────────
  echo -n "  Waiting for services "
  local max_wait=120 elapsed=0 llama_diagnosed=false
  while [[ $elapsed -lt $max_wait ]]; do
    local healthy running
    healthy=$(docker ps --filter "health=healthy" --format '{{.Names}}' 2>/dev/null | wc -l)
    running=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)

    echo -n "."

    # Core stack up = at least 3 healthy
    if [[ $healthy -ge 3 ]]; then
      echo ""
      log "Core services healthy (${healthy}/${running} containers)"
      break
    fi

    # At 45s mark, diagnose llama-server if it's still not healthy
    if [[ $elapsed -ge 45 && "$llama_diagnosed" != "true" ]]; then
      llama_diagnosed=true
      local llama_status
      llama_status=$(docker inspect --format '{{.State.Status}}' dream-llama-server 2>/dev/null || echo "missing")

      if [[ "$llama_status" == "restarting" ]]; then
        echo ""
        warn "llama-server is crash-looping — diagnosing..."
        local llama_logs
        llama_logs=$(docker logs --tail 20 dream-llama-server 2>&1 || true)

        # Check for common failure modes
        if echo "$llama_logs" | grep -qi "CUDA out of memory\|out of memory\|OOM\|not enough"; then
          err "Model too large for GPU VRAM!"
          warn "Switching to smallest bootstrap model..."

          # Download and swap to tiny model
          local tiny_url="https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf"
          local tiny_name="Qwen3-0.6B-Q4_K_M.gguf"
          if [[ ! -f "${models_dir}/${tiny_name}" ]]; then
            aria2c -x 8 -s 8 -d "$models_dir" -o "$tiny_name" "$tiny_url" 2>/dev/null || \
              curl -sL -o "${models_dir}/${tiny_name}" "$tiny_url"
          fi
          env_set "$env_file" "GGUF_FILE" "$tiny_name"
          docker restart dream-llama-server 2>/dev/null || true
          echo -n "  Retrying with smaller model "

        elif echo "$llama_logs" | grep -qi "No such file\|model file not found\|failed to load"; then
          err "Model file not found by llama-server!"
          # Re-check GGUF_FILE
          local current_gguf
          current_gguf=$(env_get "$env_file" "GGUF_FILE")
          if [[ -n "$current_gguf" && ! -f "${models_dir}/${current_gguf}" ]]; then
            warn "GGUF_FILE='${current_gguf}' does not exist in ${models_dir}/"
            # Find any model
            local fallback
            fallback=$(find "$models_dir" -name "*.gguf" -size +50M 2>/dev/null | head -1 | xargs -r basename)
            if [[ -n "$fallback" ]]; then
              env_set "$env_file" "GGUF_FILE" "$fallback"
              docker restart dream-llama-server 2>/dev/null || true
              warn "Switched to ${fallback}"
            fi
          fi

        elif echo "$llama_logs" | grep -qi "address already in use\|bind failed"; then
          err "Port conflict on llama-server port!"
          warn "Check: ss -tlnp | grep :8080"
        fi

      elif [[ "$llama_status" == "running" ]]; then
        # Running but not healthy yet — model is still loading, this is normal
        log "llama-server is running — model loading in progress"
      fi
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ $elapsed -ge $max_wait ]]; then
    echo ""
    warn "Health-check timeout (${max_wait}s) — some services may still be starting"
    warn "This is often normal for large model loading. Check: docker ps"
  fi

  # ── Report background service status ──────────────────────────────────────
  # Instead of stopping slow services, report what they're doing.
  # Heavy services are expected to take 5-30 min on first boot.

  echo ""
  echo -e "${BOLD}Service Status:${NC}"
  echo ""

  # Categorize services dynamically from manifests
  local -a core_services=()
  local -a heavy_services=()
  local -a normal_services=()

  # Core base services (defined in docker-compose.base.yml, no extension manifest)
  core_services=(llama-server open-webui dashboard dashboard-api)

  # Discover extension services by startup_behavior
  while IFS='|' read -r sid _pe _pd _name cat _proxy startup _cname; do
    [[ -z "$sid" ]] && continue
    # Skip services already in core list
    case "$sid" in open-webui|dashboard|dashboard-api) continue ;; esac
    if [[ "$startup" == "heavy" ]]; then
      heavy_services+=("$sid")
    else
      normal_services+=("$sid")
    fi
  done < <(discover_all_services "$ds_dir")

  # Report core services
  for svc in "${core_services[@]}"; do
    local container="dream-${svc}"
    local status
    status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
    local health
    health=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")

    if [[ "$health" == "healthy" ]]; then
      echo -e "  ${GREEN}✓${NC} ${svc}: healthy"
    elif [[ "$status" == "running" ]]; then
      echo -e "  ${YELLOW}◌${NC} ${svc}: starting up..."
    elif [[ "$status" == "restarting" ]]; then
      echo -e "  ${RED}↻${NC} ${svc}: restarting (check: docker logs ${container})"
    elif [[ "$status" == "not found" ]]; then
      echo -e "  ${DIM}·${NC} ${svc}: not deployed"
    else
      echo -e "  ${RED}✗${NC} ${svc}: ${status}"
    fi
  done

  # Report heavy/background services
  for svc in "${heavy_services[@]}"; do
    local container="dream-${svc}"
    local status
    status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")

    if [[ "$status" == "not found" || "$status" == "exited" ]]; then
      echo -e "  ${DIM}·${NC} ${svc}: not deployed"
    elif [[ "$status" == "running" ]]; then
      local health
      health=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
      if [[ "$health" == "healthy" ]]; then
        echo -e "  ${GREEN}✓${NC} ${svc}: ready"
      else
        # Heavy services may download models on first boot — report generically
        echo -e "  ${CYAN}↓${NC} ${svc}: initializing in background (may be downloading models)"
      fi
    elif [[ "$status" == "restarting" ]]; then
      echo -e "  ${YELLOW}↻${NC} ${svc}: restarting (downloading models — will stabilize)"
    fi
  done

  # Report normal extension services
  for svc in "${normal_services[@]}"; do
    local container="dream-${svc}"
    local status
    status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")

    if [[ "$status" == "not found" || "$status" == "exited" ]]; then
      continue  # Skip undeployed normal services (not interesting to user)
    elif [[ "$status" == "running" ]]; then
      local health
      health=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
      if [[ "$health" == "healthy" ]]; then
        echo -e "  ${GREEN}✓${NC} ${svc}: healthy"
      else
        echo -e "  ${YELLOW}◌${NC} ${svc}: starting up..."
      fi
    elif [[ "$status" == "restarting" ]]; then
      echo -e "  ${YELLOW}↻${NC} ${svc}: restarting (check: docker logs ${container})"
    fi
  done

  # Report any other dream-* containers not in our lists
  local all_containers
  all_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^dream-' | sed 's/^dream-//' || true)
  local known_listed
  known_listed=$(printf '%s\n' "${core_services[@]}" "${heavy_services[@]}" "${normal_services[@]}")
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    if ! echo "$known_listed" | grep -qx "$c"; then
      local cstatus
      cstatus=$(docker inspect --format '{{.State.Status}}' "dream-${c}" 2>/dev/null || echo "?")
      local chealth
      chealth=$(docker inspect --format '{{.State.Health.Status}}' "dream-${c}" 2>/dev/null || echo "none")
      if [[ "$chealth" == "healthy" ]]; then
        echo -e "  ${GREEN}✓${NC} ${c}: healthy"
      elif [[ "$cstatus" == "running" ]]; then
        echo -e "  ${YELLOW}◌${NC} ${c}: running"
      elif [[ "$cstatus" == "restarting" ]]; then
        echo -e "  ${YELLOW}↻${NC} ${c}: restarting"
      fi
    fi
  done <<< "$all_containers"

  echo ""

  # Background model download status
  if pgrep -f "aria2c.*gguf" > /dev/null 2>&1; then
    echo -e "  ${CYAN}↓${NC} LLM model: upgrading in background (aria2c)"
    echo "    Monitor: tail -f ${ds_dir}/logs/aria2c-download.log"
  fi
  local bg_upgrade="${ds_dir}/logs/model-upgrade.log"
  if [[ -f "$bg_upgrade" ]] && pgrep -f "model-upgrade\|model.*download" > /dev/null 2>&1; then
    echo -e "  ${CYAN}↓${NC} LLM model: upgrading in background (DreamServer)"
    echo "    Monitor: tail -f ${bg_upgrade}"
  fi
  echo ""

  #=========================================================================
  # Phase 12/15: [T4] TTS/STT readiness gates
  #=========================================================================
  step "Phase 12/15: Verifying TTS/STT model availability"

  # Whisper ASR (already existed)
  ensure_whisper_asr_model "$ds_dir"

  # [T4] Kokoro TTS readiness (new)
  ensure_tts_model_ready "$ds_dir"

  #=========================================================================
  # Phase 13/15: [T3] ComfyUI extra model downloads
  #=========================================================================
  step "Phase 13/15: ComfyUI model preload"

  # Download user-specified models if COMFYUI_EXTRA_MODELS is set in .env
  comfyui_preload_models "$ds_dir" "$GPU_BACKEND"

  #=========================================================================
  # Phase 14/15: [T1] Reverse proxy + [T12] Cloudflare tunnel
  #=========================================================================
  step "Phase 14/15: Setting up access layer"

  # [T1] Deploy Caddy reverse proxy (single-port access)
  # Failure is non-fatal — falls back to SSH tunnel
  local PROXY_PORT="${VAST_TCP_PORT_8080:-8080}"
  if setup_reverse_proxy "$ds_dir" "$PROXY_PORT"; then
    log "Reverse proxy active — all services at port ${PROXY_PORT}"
  else
    warn "Reverse proxy unavailable — use SSH tunnel instead"
  fi

  # [T12] Optional Cloudflare Tunnel (if token provided)
  setup_cloudflare_tunnel "$ds_dir"

  # [T8] Generate auto-reconnecting SSH tunnel script
  generate_ssh_tunnel_script "$ds_dir"

  #=========================================================================
  # Phase 15/15: Summary
  #=========================================================================
  step "Phase 15/15: Setup complete"

  print_access_info "$ds_dir"

  echo "=== Setup completed at $(_ts) ===" >> "$LOGFILE"
  log "Setup complete! Core services ready. Heavy services downloading in background."
}

# ── Entry point ─────────────────────────────────────────────────────────────
main "$@"