#!/usr/bin/env bash
# ============================================================================
# Dream Server — Vast.ai Phase 08: Vast.ai Quirks
# ============================================================================
# Part of: p2p-gpu/phases/
# Purpose: No-systemd workaround, /dev/shm remount, OpenCode crash-loop fix
#
# Expects: DS_DIR, DREAM_USER, log(), warn()
# Provides: Vast.ai-specific environment fixes applied
#
# Fixes covered: #18 (/dev/shm), #21 (no systemd), #22 (OpenCode crash-loop),
#                #24 (/dev/shm too small)
#
# SPDX-License-Identifier: Apache-2.0
# ============================================================================

set -euo pipefail

step "Phase 8/12: Applying Vast.ai-specific fixes"

# ── No systemd ─────────────────────────────────────────────────────────────
if ! command -v systemctl &>/dev/null && ! pidof systemd &>/dev/null; then
  log "No systemd detected — Vast.ai environment confirmed"
  dream_cli="${DS_DIR}/dream-cli"
  if [[ -x "$dream_cli" ]]; then
    # Start host agent early on no-systemd hosts so model downloads and dashboard
    # operations are available before the compose stack fully settles.
    # [NON-FATAL: host-agent] Agent start can be retried in later phases.
    su - "$DREAM_USER" -c "cd ${DS_DIR} && DREAM_HOME=${DS_DIR} ./dream-cli agent start" 2>&1 || \
      warn "Host agent start failed (non-fatal — will retry in phase 09)"
  fi
fi

# ── OpenCode crash-loop disable ────────────────────────────────────────────
if docker ps -a --format '{{.Names}} {{.Status}}' 2>&1 | grep -q 'dream-opencode.*Restarting'; then
  warn "OpenCode is crash-looping — disabling to unblock other services"
  dream_cli="${DS_DIR}/dream-cli"
  if [[ -x "$dream_cli" ]]; then
    # [NON-FATAL: opencode] Individual service failure does not block others.
    su - "$DREAM_USER" -c "cd ${DS_DIR} && ./dream-cli disable opencode" 2>&1 \
      || warn "dream-cli disable opencode failed (non-fatal)"
  else
    # [NON-FATAL: opencode] Individual service failure does not block others.
    docker stop dream-opencode || warn "opencode stop failed (non-fatal)"
    # [NON-FATAL: opencode] Individual service failure does not block others.
    docker rm dream-opencode || warn "opencode rm failed (non-fatal)"
  fi
fi

# ── Shared memory fix ─────────────────────────────────────────────────────
shm_size_kb=$(df /dev/shm 2>&1 | awk 'NR==2{print $2}' || echo 0)
if [[ "${shm_size_kb:-0}" -lt 1048576 ]]; then
  shm_mb=$(( shm_size_kb / 1024 ))
  warn "/dev/shm is only ${shm_mb} MB — GPU containers may be memory-starved"
  # [NON-FATAL: perf] Remount is a performance optimization only.
  mount -o remount,size=4G /dev/shm || warn "/dev/shm remount failed (non-fatal)"
fi

# ── Docker TLS Proxy Interception Workaround ───────────────────────────────
if curl -I https://ghcr.io/v2/ 2>&1 | grep -q "unable to get local issuer certificate\|certificate signed by unknown authority\|certificate problem"; then
  log "Vast.ai TLS proxy interception detected — applying insecure-registries workaround"
  
  if command -v docker &>/dev/null && [[ -f /etc/docker/daemon.json ]]; then
    if ! command -v jq &>/dev/null; then
      apt-get update && apt-get install -y jq >/dev/null || true
    fi
    
    if command -v jq &>/dev/null; then
      # Use jq to append insecure-registries array and ensure unique entries
      jq '."insecure-registries" = (."insecure-registries" // []) + ["ghcr.io", "docker.io", "registry-1.docker.io", "quay.io", "nvcr.io", "lscr.io", "cr.weaviate.io"] | ."insecure-registries" |= unique' /etc/docker/daemon.json > /tmp/daemon.json.tmp
      mv /tmp/daemon.json.tmp /etc/docker/daemon.json
      
      # Restart docker safely
      if command -v systemctl &>/dev/null && systemctl is-active docker >/dev/null 2>&1; then
        systemctl restart docker || warn "Failed to restart docker service"
      elif command -v service &>/dev/null; then
        service docker restart || warn "Failed to restart docker service"
      fi
      sleep 3
      log "Docker restarted with insecure-registries to bypass TLS interception"
    fi
  fi
fi

# ── Pre-pull Docker images ─────────────────────────────────────────────────
prepull_docker_images "$DS_DIR"

log "Vast.ai environment fixes applied"
