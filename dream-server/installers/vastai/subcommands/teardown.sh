#!/usr/bin/env bash
# ============================================================================
# Dream Server — Vast.ai Subcommand: teardown
# ============================================================================
# Part of: installers/vastai/subcommands/
# Purpose: Stop all containers and background processes to halt billing
#
# Expects: log(), warn(), err(), find_dream_dir(), get_compose_cmd(),
#          SCRIPT_NAME
# Provides: Clean shutdown of all DreamServer services
#
# SPDX-License-Identifier: Apache-2.0
# ============================================================================

set -euo pipefail

cmd_teardown() {
  step "Teardown — stopping all services to halt billing"
  local ds_dir
  ds_dir=$(find_dream_dir) || { err "DreamServer directory not found"; exit 1; }

  cd "$ds_dir"

  if [[ -f "docker-compose.base.yml" ]]; then
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    $compose_cmd down --remove-orphans 2>&1 || warn "Compose down had warnings (non-fatal)"
  fi

  pkill -f "aria2c.*gguf" || warn "no aria2c process to kill (non-fatal)"
  pkill -f "model-swap-on-complete" || warn "no model-swap watcher to kill (non-fatal)"

  log "All services stopped. Storage billing continues."
  log "To fully stop billing: delete the instance from Vast.ai console."
  echo ""
  echo -e "${BOLD}Data preserved at:${NC} ${ds_dir}/data/"
  echo -e "${BOLD}To resume:${NC} bash ${SCRIPT_NAME} --resume"
}
