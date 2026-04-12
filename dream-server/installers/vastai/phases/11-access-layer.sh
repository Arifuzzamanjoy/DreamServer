#!/usr/bin/env bash
# ============================================================================
# Dream Server — Vast.ai Phase 11: Access Layer
# ============================================================================
# Part of: installers/vastai/phases/
# Purpose: Caddy reverse proxy, Cloudflare tunnel, SSH tunnel script
#
# Expects: DS_DIR, GPU_BACKEND, log(), warn(), setup_reverse_proxy(),
#          setup_cloudflare_tunnel(), generate_ssh_tunnel_script(),
#          comfyui_preload_models()
# Provides: All access methods configured for Vast.ai connectivity
#
# SPDX-License-Identifier: Apache-2.0
# ============================================================================

set -euo pipefail

step "Phase 11/12: Setting up access layer"

# ComfyUI extra model downloads (if configured)
comfyui_preload_models "$DS_DIR" "$GPU_BACKEND"

# Caddy reverse proxy — port 8443 to avoid conflict with Ollama (8080)
PROXY_PORT="${VAST_TCP_PORT_8443:-8443}"
if setup_reverse_proxy "$DS_DIR" "$PROXY_PORT"; then
  log "Reverse proxy active — all services at port ${PROXY_PORT}"
else
  warn "Reverse proxy unavailable — use SSH tunnel instead"
fi

# Optional Cloudflare Tunnel
setup_cloudflare_tunnel "$DS_DIR"

# Auto-reconnecting SSH tunnel script
generate_ssh_tunnel_script "$DS_DIR"
