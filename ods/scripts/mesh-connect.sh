#!/usr/bin/env bash
# ============================================================================
# Form the DreamReason mesh from a roster of SSH endpoints.
#
# Rented GPU hosts publish only the ports requested when the instance was
# created, and on Vast.ai that is reliably just 22. So peers are reached by
# tunnelling 3002 and 4000 over SSH rather than by asking the provider to
# expose them, which means a mesh can be formed from instances that were never
# provisioned for one.
#
# Tunnel ports are derived from a node's position in the roster, so every node
# running the same roster computes the same mapping and config/mesh-peers.json
# comes out identical everywhere. Nothing is hand-allocated.
#
# systemd owns tunnel lifetime. A bare `ssh -N -f` dies with its parent shell
# and never comes back, which shows up later as peers that were online at
# deploy time and are unreachable now, with nothing in any log to say when.
#
#   bash scripts/mesh-connect.sh init     # generate this node's mesh key
#   bash scripts/mesh-connect.sh up       # tunnels + peers file
#   bash scripts/mesh-connect.sh status   # what is actually connected
#   bash scripts/mesh-connect.sh down     # tear the tunnels down
#
# Exit status is the number of peers that failed to connect.
# ============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ODS_DIR="$(pwd)"

ROSTER="${MESH_NODES_FILE:-config/mesh-nodes.conf}"
PEERS_FILE="${MESH_PEERS_OUT:-config/mesh-peers.json}"
KEY_FILE="${MESH_TUNNEL_KEY:-/root/.ssh/ods_mesh}"
# Local ports the tunnels land on. Peer i takes base+i, so the mapping is a
# property of the roster rather than of the order things were run in.
API_BASE="${MESH_TUNNEL_API_BASE:-13000}"
LITELLM_BASE="${MESH_TUNNEL_LITELLM_BASE:-14000}"
INTERNAL_API_PORT="${MESH_INTERNAL_API_PORT:-3002}"
INTERNAL_LITELLM_PORT="${MESH_INTERNAL_LITELLM_PORT:-4000}"
UNIT_PREFIX="ods-mesh-tunnel"

ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
no()   { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }
info() { printf '  \033[36m[..]\033[0m   %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── Roster ─────────────────────────────────────────────────────────────────

require_roster() {
  [[ -f "$ROSTER" ]] || {
    no "no roster at ${ODS_DIR}/${ROSTER}"
    printf '       cp config/mesh-nodes.example.conf %s and list every node\n' "$ROSTER"
    exit 1
  }
}

# Roster lines, comments and blanks removed. Order is significant: it fixes
# the port mapping, so it must be stable across nodes.
roster_entries() {
  grep -vE '^\s*(#|$)' "$ROSTER"
}

# This node's name, so it can skip itself. Matched on the roster's host part
# against the public IP the provider assigned, because hostnames inside these
# containers are all "ubuntu" and carry no identity.
self_name() {
  if [[ -n "${MESH_SELF:-}" ]]; then
    echo "$MESH_SELF"
    return 0
  fi
  local ip
  ip="${PUBLIC_IPADDR:-$(grep -m1 '^ODS_PUBLIC_IP=' .env 2>/dev/null | cut -d= -f2- || true)}"
  [[ -n "$ip" ]] || return 0
  roster_entries | awk -v ip="$ip" '{split($2,a,"@"); split(a[2],b,":"); if (b[1]==ip) {print $1; exit}}'
}

# Address containers use to reach a port bound on this host. Detected rather
# than assumed: only dashboard-api declares host.docker.internal, and litellm
# needs to reach peers too.
docker_gateway() {
  docker network inspect ods-network \
    --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null \
    || echo "172.17.0.1"
}

# ── Commands ───────────────────────────────────────────────────────────────

cmd_init() {
  head_ "Mesh tunnel key"
  if [[ -f "$KEY_FILE" ]]; then
    ok "key already exists at ${KEY_FILE}"
  else
    mkdir -p "$(dirname "$KEY_FILE")"
    ssh-keygen -t ed25519 -N "" -f "$KEY_FILE" -C "ods-mesh@$(hostname)" >/dev/null
    ok "generated ${KEY_FILE}"
  fi
  head_ "Install this on EVERY other node, in ~/.ssh/authorized_keys"
  printf '\n%s\n\n' "$(cat "${KEY_FILE}.pub")"
  info "then run: bash scripts/mesh-connect.sh up"
}

# One systemd unit per peer. Restart=always is the point: a tunnel that dies
# silently is indistinguishable from a peer that went away.
write_unit() {
  local name="$1" endpoint="$2" api_port="$3" litellm_port="$4"
  local user_host ssh_port
  user_host="${endpoint%%:*}"
  ssh_port="${endpoint##*:}"

  cat > "/etc/systemd/system/${UNIT_PREFIX}@${name}.service" <<UNIT
[Unit]
Description=ODS mesh tunnel to ${name}
After=network-online.target docker.service

[Service]
ExecStart=/usr/bin/ssh -N \\
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=no \\
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
  -o BatchMode=yes \\
  -i ${KEY_FILE} -p ${ssh_port} \\
  -L 0.0.0.0:${api_port}:127.0.0.1:${INTERNAL_API_PORT} \\
  -L 0.0.0.0:${litellm_port}:127.0.0.1:${INTERNAL_LITELLM_PORT} \\
  ${user_host}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}

cmd_up() {
  require_roster
  [[ -f "$KEY_FILE" ]] || { no "no key — run 'mesh-connect.sh init' first"; exit 1; }

  local me gateway failures=0 index=0
  me="$(self_name)"
  gateway="$(docker_gateway)"

  head_ "Roster"
  if [[ -n "$me" ]]; then
    ok "this node is '${me}'"
  else
    info "this node is not in the roster (set MESH_SELF to fix) — tunnelling to every entry"
  fi
  ok "containers reach this host at ${gateway}"

  head_ "Tunnels"
  local peers_json="" name endpoint api_port litellm_port
  while read -r name endpoint; do
    api_port=$((API_BASE + index))
    litellm_port=$((LITELLM_BASE + index))
    index=$((index + 1))

    [[ "$name" == "$me" ]] && { info "${name}: self, skipped"; continue; }

    write_unit "$name" "$endpoint" "$api_port" "$litellm_port"
    systemctl daemon-reload
    systemctl enable --now "${UNIT_PREFIX}@${name}.service" >/dev/null 2>&1 \
      || warn_unit "$name"
    systemctl restart "${UNIT_PREFIX}@${name}.service"

    # Give ssh a moment to bind before judging it.
    sleep 2
    if curl -fsS -m 5 -o /dev/null "http://127.0.0.1:${api_port}/api/status" 2>/dev/null \
       || [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${api_port}/api/status" 2>/dev/null)" != "000" ]]; then
      ok "${name}: api :${api_port}  litellm :${litellm_port}"
    else
      no "${name}: no answer on :${api_port} — check the key is in ${name}'s authorized_keys"
      failures=$((failures + 1))
    fi

    peers_json+="{\"hostname\":\"${name}\",\"host\":\"${gateway}\",\"api_port\":${api_port},\"litellm_port\":${litellm_port}},"
  done < <(roster_entries)

  head_ "Peer file"
  printf '{"peers":[%s]}\n' "${peers_json%,}" > "$PEERS_FILE"
  ok "wrote ${PEERS_FILE}"

  head_ "Next"
  info "regenerate routes and reload LiteLLM:"
  # These are commands for the operator to copy, not for this shell to run, so
  # $KEY must survive to the terminal unexpanded.
  # shellcheck disable=SC2016
  printf '       KEY=$(grep -m1 ^DASHBOARD_API_KEY= .env | cut -d= -f2-)\n'
  # shellcheck disable=SC2016
  printf '       curl -s -H "Authorization: Bearer $KEY" localhost:%s/api/mesh/peers \\\n' "$INTERNAL_API_PORT"
  printf '         | python3 scripts/generate-mesh-litellm-config.py -o config/litellm/mesh.yaml\n'
  # docker restart, not `ods restart`: the latter is `compose up -d`, which is
  # a no-op when only a mounted config file changed, so LiteLLM keeps serving
  # the routes it started with.
  printf '       docker restart ods-litellm ods-dreamreason\n\n'
  return "$failures"
}

warn_unit() {
  no "could not enable ${UNIT_PREFIX}@${1}.service"
}

cmd_status() {
  require_roster
  local me index=0 name endpoint api_port state code
  me="$(self_name)"
  head_ "Mesh tunnels"
  while read -r name endpoint; do
    api_port=$((API_BASE + index))
    index=$((index + 1))
    [[ "$name" == "$me" ]] && continue
    state="$(systemctl is-active "${UNIT_PREFIX}@${name}.service" 2>/dev/null || echo inactive)"
    code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${api_port}/api/status" 2>/dev/null || echo 000)"
    if [[ "$state" == "active" && "$code" != "000" ]]; then
      ok "${name}: unit ${state}, api :${api_port} answering (HTTP ${code})"
    else
      no "${name}: unit ${state}, api :${api_port} HTTP ${code}"
    fi
  done < <(roster_entries)
}

cmd_down() {
  require_roster
  head_ "Stopping tunnels"
  local name endpoint
  while read -r name endpoint; do
    if systemctl is-enabled "${UNIT_PREFIX}@${name}.service" >/dev/null 2>&1; then
      systemctl disable --now "${UNIT_PREFIX}@${name}.service" >/dev/null 2>&1
      rm -f "/etc/systemd/system/${UNIT_PREFIX}@${name}.service"
      ok "${name}: stopped and removed"
    fi
  done < <(roster_entries)
  systemctl daemon-reload
}

case "${1:-status}" in
  init)   cmd_init ;;
  up)     cmd_up ;;
  status) cmd_status ;;
  down)   cmd_down ;;
  *)
    printf 'Usage: mesh-connect.sh {init|up|status|down}\n'
    exit 2
    ;;
esac
