#!/usr/bin/env bash
# ============================================================================
# ODS — Vast.ai Phase 13: DreamReason Mesh (opt-in)
# ============================================================================
# Part of: p2p-gpu/phases/
# Purpose: Switch this node into mesh mode and report its peer coordinates
#
# Expects: ODS_DIR, ODS_USER, log(), warn(), step(), env_get(), env_set()
# Provides: ODS_MODE=mesh, coordinator enabled, peer coordinates printed
#
# Runs only when ODS_MESH=1. Mesh mode is useless on a single instance, and
# building the coordinator image on every deploy costs minutes for nothing.
#
# Rented GPU hosts have no tailnet, so peers are declared by address in
# config/mesh-peers.json rather than discovered. Vast.ai publishes each
# internal port on a DIFFERENT external port (VAST_TCP_PORT_<internal>), so
# this phase prints the coordinates other nodes must be given.
#
# SPDX-License-Identifier: Apache-2.0
# ============================================================================

set -euo pipefail

if [[ "${ODS_MESH:-0}" != "1" ]]; then
  log "Mesh mode not requested (set ODS_MESH=1 to enable) — skipping"
  return 0 2>/dev/null || exit 0
fi

step "Configuring DreamReason mesh (opt-in)"

env_file="${ODS_DIR}/.env"

# ── Switch the node into mesh mode ─────────────────────────────────────────
# mode-switch.sh owns the contract ods-doctor enforces: route LLM_API_URL and
# HERMES_LLM_BASE_URL through LiteLLM, and enable the coordinator.
if [[ -x "${ODS_DIR}/scripts/mode-switch.sh" ]]; then
  su - "$ODS_USER" -c "cd ${ODS_DIR} && bash scripts/mode-switch.sh mesh" 2>&1 \
    || warn "mode-switch.sh mesh failed (non-fatal — check with ods-doctor)"
else
  warn "scripts/mode-switch.sh not found — setting mesh env directly"
  env_set "$env_file" "ODS_MODE" "mesh"
  env_set "$env_file" "LLM_API_URL" "http://litellm:4000"
  env_set "$env_file" "HERMES_LLM_BASE_URL" "http://litellm:4000/v1"
fi

# ── Shared key for cross-node probes ───────────────────────────────────────
# Every node in the mesh needs the SAME key. A mismatch surfaces as
# state=unauthorized on /api/mesh/peers rather than as a hard failure.
mesh_key="$(env_get "$env_file" "MESH_PEER_API_KEY")"
if [[ -z "$mesh_key" ]]; then
  if [[ -n "${ODS_MESH_KEY:-}" ]]; then
    env_set "$env_file" "MESH_PEER_API_KEY" "$ODS_MESH_KEY"
    log "MESH_PEER_API_KEY taken from ODS_MESH_KEY"
  else
    warn "MESH_PEER_API_KEY is unset. Generate one key and set ODS_MESH_KEY to"
    warn "the SAME value on every node, or peers will reject each other."
  fi
fi

# ── Peer file ──────────────────────────────────────────────────────────────
peers_file="${ODS_DIR}/config/mesh-peers.json"
if [[ ! -f "$peers_file" ]]; then
  example="${ODS_DIR}/config/mesh-peers.example.json"
  [[ -f "$example" ]] && cp "$example" "${peers_file}.example" \
    || warn "mesh-peers example not found (non-fatal)"
  log "No config/mesh-peers.json yet — this node has no peers until you add one"
fi

# ── Report this node's coordinates ─────────────────────────────────────────
# Other nodes need the EXTERNAL ports, which Vast.ai remaps.
public_ip="${PUBLIC_IPADDR:-$(env_get "$env_file" "ODS_PUBLIC_IP")}"
api_internal="$(env_get "$env_file" "DASHBOARD_API_PORT")"
api_internal="${api_internal:-3002}"
litellm_internal="$(env_get "$env_file" "LITELLM_PORT")"
litellm_internal="${litellm_internal:-4000}"

api_var="VAST_TCP_PORT_${api_internal}"
litellm_var="VAST_TCP_PORT_${litellm_internal}"
api_external="${!api_var:-$api_internal}"
litellm_external="${!litellm_var:-$litellm_internal}"

if [[ "${!api_var:-}" == "" || "${!litellm_var:-}" == "" ]]; then
  warn "Ports ${api_internal} and/or ${litellm_internal} are not published by the"
  warn "provider. On Vast.ai these must be requested when the instance is"
  warn "CREATED — they cannot be opened afterwards. Peers will be unreachable."
fi

log "Mesh coordinates for this node — add this entry to the OTHER nodes:"
cat <<COORDS
  {
    "hostname": "$(hostname)",
    "host": "${public_ip:-<public-ip>}",
    "api_port": ${api_external},
    "litellm_port": ${litellm_external}
  }
COORDS

log "Then on every node: regenerate peer routes and restart LiteLLM"
log "  python3 scripts/generate-mesh-litellm-config.py \\"
log "      --peers-json <(curl -s -H \"Authorization: Bearer \$DASHBOARD_API_KEY\" \\"
log "          localhost:${api_internal}/api/mesh/peers) -o config/litellm/mesh.yaml"
log "  ./ods-cli restart litellm dreamreason"

log "DreamReason mesh configured"
