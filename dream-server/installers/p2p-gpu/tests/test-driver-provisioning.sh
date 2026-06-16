#!/usr/bin/env bash
# Regression: harden NVIDIA host-driver provisioning helpers.
set -euo pipefail

P2P_GPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGFILE="$(mktemp -t p2p-gpu-driver.XXXXXX)"
STUB_DIR="$(mktemp -d -t p2p-gpu-stub.XXXXXX)"
APT_MARK_CALLS_FILE="${STUB_DIR}/apt-mark-calls"
# shellcheck disable=SC2034
MIN_DRIVER_VERSION=570
trap 'rm -f "$LOGFILE"; rm -rf "$STUB_DIR"' EXIT

# Minimal logging functions expected by environment.sh
fail() { echo "$*" >&2; exit 1; }
log() { :; }
warn() { :; }
err() { :; }
step() { :; }

export PATH="${STUB_DIR}:${PATH}"
export APT_MARK_CALLS_FILE

cat >"${STUB_DIR}/apt-mark" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  showhold)
    printf '%s\n' \
      nvidia-driver-535 \
      libnvidia-ml1 \
      cuda-drivers-535 \
      unrelated-package
    ;;
  unhold)
    printf '%s\n' "${2:-}" >> "${APT_MARK_CALLS_FILE}"
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat >"${STUB_DIR}/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--query-gpu=driver_version" ]]; then
  printf '%s\n' "${NVIDIA_SMI_DRIVER_VERSION:-}"
  exit 0
fi

exit 1
EOF

cat >"${STUB_DIR}/lspci" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' '0000:01:00.0 VGA compatible controller: NVIDIA Corporation Device'
EOF

chmod +x "${STUB_DIR}/apt-mark" "${STUB_DIR}/nvidia-smi" "${STUB_DIR}/lspci"

# shellcheck source=../lib/environment.sh
source "${P2P_GPU_DIR}/lib/environment.sh"

test() {
  case "$1 $2" in
    "-w /etc/modprobe.d"|"-e /lib/modules/$(uname -r)"|"-e /.dockerenv")
      return 0
      ;;
    *)
      builtin test "$@"
      ;;
  esac
}

if _can_manage_host_driver; then
  fail "Expected _can_manage_host_driver to reject shared-driver container context"
fi

unset -f test

export NVIDIA_SMI_DRIVER_VERSION="535.104.05"
if _detect_driver_below_minimum; then
  fail "Expected _detect_driver_below_minimum to flag 535.x as below minimum"
else
  rc=$?
  [[ $rc -eq 1 ]] || fail "Expected _detect_driver_below_minimum to return 1 for 535.x"
fi

export NVIDIA_SMI_DRIVER_VERSION="580.82.07"
if _detect_driver_below_minimum; then
  :
else
  fail "Expected _detect_driver_below_minimum to return 0 for 580.x"
fi

rm -f "${APT_MARK_CALLS_FILE}"

_unhold_nvidia_packages

if [[ ! -f "${APT_MARK_CALLS_FILE}" ]]; then
  fail "Expected _unhold_nvidia_packages to call apt-mark unhold"
fi

unhold_calls="$(tr '\n' ' ' < "${APT_MARK_CALLS_FILE}" | sed 's/[[:space:]]\+$//')"
expected_calls="nvidia-driver-535 libnvidia-ml1 cuda-drivers-535"
if [[ "$unhold_calls" != "$expected_calls" ]]; then
  fail "Unexpected apt-mark unhold calls: ${unhold_calls}"
fi

unset NVIDIA_SMI_DRIVER_VERSION
rm -f "${STUB_DIR}/nvidia-smi"

command() {
  if [[ "${1:-}" == "-v" && "${2:-}" == "nvidia-smi" ]]; then
    return 1
  fi
  builtin command "$@"
}

if _detect_nvidia_smi_missing; then
  :
else
  fail "Expected _detect_nvidia_smi_missing to return 0 when nvidia-smi is absent"
fi

unset -f command
