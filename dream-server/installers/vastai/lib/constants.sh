#!/usr/bin/env bash
# ============================================================================
# Dream Server — Vast.ai Constants
# ============================================================================
# Part of: installers/vastai/lib/
# Purpose: Readonly variables, colors, paths, thresholds
#
# Expects: (nothing — first file sourced)
# Provides: VASTAI_VERSION, DREAM_USER, DREAM_HOME, REPO_URL, REPO_BRANCH,
#           MIN_DISK_GB, MIN_VRAM_MB, LOCKFILE, LOGFILE, color codes
#
# Modder notes:
#   All constants are readonly. Override via env vars BEFORE sourcing.
#   Variables are consumed by other files sourced after this one.
#
# SPDX-License-Identifier: Apache-2.0
# ============================================================================

# shellcheck disable=SC2034  # Variables used by sourcing scripts
set -euo pipefail

readonly VASTAI_VERSION="6.0.0"
readonly LOCKFILE="/tmp/dreamserver-vastai-setup.lock"
readonly LOGFILE="/var/log/dreamserver-vastai-setup.log"

readonly DREAM_USER="dream"
readonly DREAM_HOME="/home/${DREAM_USER}"
readonly REPO_URL="https://github.com/Light-Heart-Labs/DreamServer.git"
readonly REPO_BRANCH="main"
readonly MIN_DISK_GB=40
readonly MIN_VRAM_MB=8000
readonly INSTALLER_TIMEOUT=600

# ── Colors ──────────────────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'
