#!/usr/bin/env bash
# Regression: TLS CA remediation installs a proxy chain, is idempotent, and gates phase 09.
set -euo pipefail

P2P_GPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGFILE="$(mktemp -t p2p-gpu-tls.XXXXXX)"
STUB_DIR="$(mktemp -d -t p2p-gpu-stub.XXXXXX)"
CA_STORE_DIR="$(mktemp -d -t p2p-gpu-ca.XXXXXX)"
DOCKER_CERTS_DIR="$(mktemp -d -t p2p-gpu-docker-certs.XXXXXX)"
PKG_MARKER="${STUB_DIR}/ca-certificates.installed"
TLS_FIXED_MARKER="${STUB_DIR}/tls-fixed"
trap 'rm -f "$LOGFILE"; rm -rf "$STUB_DIR" "$CA_STORE_DIR" "$DOCKER_CERTS_DIR"' EXIT

log() { :; }
warn() { :; }
err() { :; }
step() { :; }
sleep() { :; }

# shellcheck source=../lib/environment.sh
source "${P2P_GPU_DIR}/lib/environment.sh"

export PATH="${STUB_DIR}:${PATH}"
export DREAM_PROXY_CA_STORE_DIR="$CA_STORE_DIR"
export DREAM_DOCKER_CERTS_DIR="$DOCKER_CERTS_DIR"
export PKG_MARKER TLS_FIXED_MARKER LOGFILE TLS_FIX_SCENARIO

cat >"${STUB_DIR}/dpkg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-s" && "$2" == "ca-certificates" ]]; then
  if [[ -f "$PKG_MARKER" ]]; then
    exit 0
  fi
  exit 1
fi
echo "unexpected dpkg call: $*" >&2
exit 1
EOF

cat >"${STUB_DIR}/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch "$PKG_MARKER"
exit 0
EOF

cat >"${STUB_DIR}/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${TLS_FIX_SCENARIO:-extract}" == "broken" ]]; then
  exit 0
fi

cat <<'CERTS'
-----BEGIN CERTIFICATE-----
MIIBaTCCAQ+gAwIBAgIUXA111111111111111111111111110wCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwIcHJveHktMDEwHhcNMjYwMTAxMDAwMDAwWhcNMzYwMTAxMDAw
MDAwWjATMREwDwYDVQQDDAhwcm94eS0wMTBZMBMGByqGSM49AgEGCCqGSM49AwEH
A0IABBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIBazCCAQGgAwIBAgIUYB2222222222222222222222222220wCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwIcHJveHktMDIwHhcNMjYwMTAxMDAwMDAwWhcNMzYwMTAxMDAw
MDAwWjATMREwDwYDVQQDDAhwcm94eS0wMjBZMBMGByqGSM49AgEGCCqGSM49AwEH
A0IACCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
-----END CERTIFICATE-----
CERTS
EOF

cat >"${STUB_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"https://registry-1.docker.io/v2/"* ]]; then
  if [[ -f "$TLS_FIXED_MARKER" ]]; then
    exit 0
  fi
  exit 1
fi
exit 0
EOF

cat >"${STUB_DIR}/update-ca-certificates" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch "$TLS_FIXED_MARKER"
exit 0
EOF

cat >"${STUB_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "pull" && "$2" == "hello-world:latest" ]]; then
  if [[ -f "$TLS_FIXED_MARKER" ]]; then
    exit 0
  fi
  exit 1
fi
if [[ "$1" == "pull" && "$2" == "hello-world" ]]; then
  if [[ -f "$TLS_FIXED_MARKER" ]]; then
    exit 0
  fi
  exit 1
fi
exit 0
EOF

cat >"${STUB_DIR}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF

cat >"${STUB_DIR}/service" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF

cat >"${STUB_DIR}/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift
exec "$@"
EOF

chmod +x \
  "${STUB_DIR}/dpkg" \
  "${STUB_DIR}/apt-get" \
  "${STUB_DIR}/openssl" \
  "${STUB_DIR}/curl" \
  "${STUB_DIR}/update-ca-certificates" \
  "${STUB_DIR}/docker" \
  "${STUB_DIR}/systemctl" \
  "${STUB_DIR}/service" \
  "${STUB_DIR}/timeout"

count_proxy_certs() {
  find "$CA_STORE_DIR" -maxdepth 1 -type f -name 'dream-proxy-*.crt' | wc -l | tr -d ' '
}

TLS_FIX_SCENARIO=extract
if remediate_tls_trust; then
  first_rc=0
else
  first_rc=$?
fi

if [[ "$first_rc" -ne 0 ]]; then
  echo "Expected remediation to succeed on extracted chain" >&2
  exit 1
fi

if [[ "$TLS_OK" != "true" ]]; then
  echo "Expected TLS_OK=true after remediation" >&2
  exit 1
fi

first_count="$(count_proxy_certs)"
if [[ "$first_count" -ne 2 ]]; then
  echo "Expected 2 proxy CA certs after first remediation, got ${first_count}" >&2
  exit 1
fi

if [[ ! -f "${DOCKER_CERTS_DIR}/docker.io/ca.crt" || ! -f "${DOCKER_CERTS_DIR}/ghcr.io/ca.crt" ]]; then
  echo "Expected Docker registry trust files to be created" >&2
  exit 1
fi

TLS_FIX_SCENARIO=extract
if remediate_tls_trust; then
  second_rc=0
else
  second_rc=$?
fi

if [[ "$second_rc" -ne 0 ]]; then
  echo "Expected remediation to remain successful on rerun" >&2
  exit 1
fi

second_count="$(count_proxy_certs)"
if [[ "$second_count" -ne 2 ]]; then
  echo "Expected remediation rerun to stay idempotent, got ${second_count} certs" >&2
  exit 1
fi

TLS_FIX_SCENARIO=broken
rm -f "$TLS_FIXED_MARKER"
rm -f "${CA_STORE_DIR}"/dream-proxy-*.crt

if remediate_tls_trust; then
  echo "Expected remediation to fail when no proxy CA can be extracted" >&2
  exit 1
fi

if [[ "$TLS_OK" != "false" ]]; then
  echo "Expected TLS_OK=false after unfixable remediation" >&2
  exit 1
fi

if (TLS_OK=false; _gate_phase09_tls_trust); then
  echo "Expected phase 09 TLS gate to abort when TLS_OK=false" >&2
  exit 1
fi