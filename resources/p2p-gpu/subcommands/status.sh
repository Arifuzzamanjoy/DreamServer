#!/usr/bin/env bash
# ============================================================================
# Dream Server — Vast.ai Subcommand: status
# ============================================================================
# Part of: p2p-gpu/subcommands/
# Purpose: Display GPU info, container status, download progress
#
# Expects: log(), warn(), err(), find_dream_dir()
# Provides: Health status overview
#
# SPDX-License-Identifier: Apache-2.0
# ============================================================================

set -euo pipefail

cmd_status() {
  local ds_dir
  ds_dir=$(find_dream_dir) || { err "DreamServer directory not found"; exit 1; }

  echo -e "\n${BOLD}DreamServer Status${NC}\n"

  # GPU info
  nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu \
    --format=csv,noheader 2>&1 | while IFS=',' read -r name mem_total mem_used util; do
    echo -e "  GPU: ${CYAN}${name}${NC} | VRAM: ${mem_used} /${mem_total} | Util: ${util}"
  done

  echo ""
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1 | head -20

  echo ""
  local healthy running total
  healthy=$(docker ps --filter "health=healthy" --format '{{.Names}}' | wc -l)
  running=$(docker ps --format '{{.Names}}' | wc -l)
  total=$(docker ps -a --format '{{.Names}}' | grep -c '^dream-' || echo 0)
  echo -e "  Containers: ${GREEN}${healthy}${NC} healthy / ${running} running / ${total} total"

  if pgrep -f "aria2c.*gguf" > /dev/null 2>&1; then
    echo -e "  Model download: ${YELLOW}in progress${NC}"
    local dl_log="${ds_dir}/logs/aria2c-download.log"
    [[ -f "$dl_log" ]] && tail -1 "$dl_log" 2>&1 | sed 's/^/    /'
  fi
  echo ""
}
