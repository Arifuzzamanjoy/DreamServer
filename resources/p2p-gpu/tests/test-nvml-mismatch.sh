#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_handle_nvml_mismatch_repairs_on_status_one() (
  set -euo pipefail
  export LOGFILE
  LOGFILE="$(mktemp)"
  trap 'rm -f "$LOGFILE"' EXIT

  log() { :; }
  warn() { :; }
  err() { :; }
  DREAM_USER="dream"
  DREAM_HOME="/home/dream"

  # shellcheck source=../lib/environment.sh
  source "${SCRIPT_DIR}/../lib/environment.sh"

  local repair_calls=0
  detect_nvml_mismatch() { return 1; }
  repair_nvml_mismatch() { repair_calls=$((repair_calls + 1)); return 0; }

  handle_nvml_mismatch "mock-image" "repair"
  [[ "$repair_calls" -eq 1 ]]
)

test_handle_nvml_mismatch_skips_repair_on_inconclusive() (
  set -euo pipefail
  export LOGFILE
  LOGFILE="$(mktemp)"
  trap 'rm -f "$LOGFILE"' EXIT

  log() { :; }
  warn() { :; }
  err() { :; }
  DREAM_USER="dream"
  DREAM_HOME="/home/dream"

  # shellcheck source=../lib/environment.sh
  source "${SCRIPT_DIR}/../lib/environment.sh"

  local repair_calls=0
  detect_nvml_mismatch() { return 2; }
  repair_nvml_mismatch() { repair_calls=$((repair_calls + 1)); return 0; }

  handle_nvml_mismatch "mock-image" "repair"
  [[ "$repair_calls" -eq 0 ]]
)

test_repair_nvml_mismatch_handles_initial_mismatch_under_set_e() (
  set -euo pipefail
  export LOGFILE
  LOGFILE="$(mktemp)"
  trap 'rm -f "$LOGFILE"' EXIT

  log() { :; }
  warn() { :; }
  err() { :; }
  DREAM_USER="dream"
  DREAM_HOME="/home/dream"

  # shellcheck source=../lib/environment.sh
  source "${SCRIPT_DIR}/../lib/environment.sh"

  local detect_calls=0 apt_calls=0
  detect_nvml_mismatch() {
    detect_calls=$((detect_calls + 1))
    if [[ "$detect_calls" -eq 1 ]]; then
      return 1
    fi
    return 0
  }
  dpkg() { echo "ii  nvidia-driver-535  535.183.01-0ubuntu0  amd64"; }
  apt-get() { apt_calls=$((apt_calls + 1)); return 0; }
  systemctl() { return 0; }
  service() { return 0; }
  sleep() { :; }

  repair_nvml_mismatch "mock-image"
  [[ "$detect_calls" -eq 2 ]]
  [[ "$apt_calls" -eq 2 ]]
)

test_repair_nvml_mismatch_reports_failure_when_mismatch_persists() (
  set -euo pipefail
  export LOGFILE
  LOGFILE="$(mktemp)"
  trap 'rm -f "$LOGFILE"' EXIT

  log() { :; }
  warn() { :; }
  err() { :; }
  DREAM_USER="dream"
  DREAM_HOME="/home/dream"

  # shellcheck source=../lib/environment.sh
  source "${SCRIPT_DIR}/../lib/environment.sh"

  local detect_calls=0
  detect_nvml_mismatch() {
    detect_calls=$((detect_calls + 1))
    return 1
  }
  dpkg() { echo "ii  nvidia-driver-535  535.183.01-0ubuntu0  amd64"; }
  apt-get() { return 0; }
  systemctl() { return 0; }
  service() { return 0; }
  sleep() { :; }

  if repair_nvml_mismatch "mock-image"; then
    return 1
  fi
  [[ "$detect_calls" -eq 2 ]]
)

test_repair_nvml_mismatch_skips_when_no_apt_package() (
  set -euo pipefail
  export LOGFILE
  LOGFILE="$(mktemp)"
  trap 'rm -f "$LOGFILE"' EXIT

  log() { :; }
  warn() { :; }
  err() { :; }
  DREAM_USER="dream"
  DREAM_HOME="/home/dream"

  # shellcheck source=../lib/environment.sh
  source "${SCRIPT_DIR}/../lib/environment.sh"

  local apt_calls=0
  detect_nvml_mismatch() { return 1; }
  dpkg() { return 0; }
  apt-get() { apt_calls=$((apt_calls + 1)); return 0; }

  if repair_nvml_mismatch "mock-image"; then
    return 1
  fi
  [[ "$apt_calls" -eq 0 ]]
)

run_test() {
  local name="$1"
  if "$name"; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name}" >&2
    exit 1
  fi
}

run_test test_handle_nvml_mismatch_repairs_on_status_one
run_test test_handle_nvml_mismatch_skips_repair_on_inconclusive
run_test test_repair_nvml_mismatch_handles_initial_mismatch_under_set_e
run_test test_repair_nvml_mismatch_reports_failure_when_mismatch_persists
run_test test_repair_nvml_mismatch_skips_when_no_apt_package

echo "All NVML mismatch regression tests passed."
