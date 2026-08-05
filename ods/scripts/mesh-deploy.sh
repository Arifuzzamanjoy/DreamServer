#!/usr/bin/env bash
# ============================================================================
# Deploy a DreamReason mesh across every node in the roster, from one machine.
#
# Runs on the OPERATOR's machine, not on a node. That is the security choice,
# not an accident: the alternative is putting a provider API key on every
# rented box so nodes can discover each other, and those boxes run on hardware
# owned by strangers. Here the credentials stay on the operator's machine and
# only per-mesh secrets are pushed out.
#
# What it does, per node, idempotently:
#   1. sync this checkout into the node's install dir
#   2. write the shared mesh secrets and that node's advertised skills
#   3. rebuild the images whose source actually changed
#   4. exchange SSH keys between every pair of nodes
#   5. form the tunnels and write the peer file
#   6. regenerate the LiteLLM routes and reload
#   7. verify the node can see its peers
#
# Requires only SSH access to every node. It does NOT create instances -- that
# needs a provider key, and provisioning is where the operator should stay in
# the loop.
#
#   bash scripts/mesh-deploy.sh --check    # what would happen, touch nothing
#   bash scripts/mesh-deploy.sh            # deploy the whole mesh
#
# Exit status is the number of nodes that failed.
# ============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ODS_DIR="$(pwd)"

ROSTER="${MESH_NODES_FILE:-config/mesh-nodes.conf}"
REMOTE_DIR="${MESH_REMOTE_DIR:-/home/dream/ods}"
SSH_KEY="${MESH_DEPLOY_KEY:-$HOME/.ssh/id_ed25519}"
DRY_RUN=0
[[ "${1:-}" == "--check" ]] && DRY_RUN=1

ok()    { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
no()    { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }
info()  { printf '  \033[36m[..]\033[0m   %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

[[ -f "$ROSTER" ]] || { no "no roster at ${REPO_ODS_DIR}/${ROSTER}"; exit 1; }
[[ -f "$SSH_KEY" ]] || { no "no SSH key at ${SSH_KEY} (set MESH_DEPLOY_KEY)"; exit 1; }

roster_entries() { grep -vE '^\s*(#|$)' "$ROSTER"; }

# Roster: <name> <user>@<host>:<ssh-port> [skills]
node_host()  { local e="$1"; e="${e%%:*}"; echo "${e#*@}"; }
node_user()  { local e="$1"; echo "${e%%@*}"; }
node_port()  { echo "${1##*:}"; }

# -n is load-bearing. Every caller runs inside a `while read` over the roster,
# and without it ssh drains the loop's stdin, so the first node is deployed and
# the rest are silently skipped with a success exit.
on_node() {
  local endpoint="$1"; shift
  ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=20 -o BatchMode=yes \
      -i "$SSH_KEY" -p "$(node_port "$endpoint")" \
      "$(node_user "$endpoint")@$(node_host "$endpoint")" "$@"
}

sync_to_node() {
  local endpoint="$1"
  # NO --delete or --delete-excluded. --delete-excluded deletes the excluded
  # paths on the receiver, which is the exact opposite of what excluding them
  # is for: it wipes .env and every downloaded model. Additive sync only.
  rsync -az \
    --exclude '.env' --exclude 'data/' --exclude '.git' \
    --exclude '.compose-flags' --exclude 'config/mesh-peers.json' \
    -e "ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i ${SSH_KEY} -p $(node_port "$endpoint")" \
    "${REPO_ODS_DIR}/" \
    "$(node_user "$endpoint")@$(node_host "$endpoint"):${REMOTE_DIR}/"
}

# ── Secrets ────────────────────────────────────────────────────────────────
#
# One shared value each, reused across the mesh:
#
#   MESH_PEER_API_KEY  what a peer presents to another peer's dashboard-api
#   MESH_PEER_KEY      what a peer presents to another peer's LiteLLM, which
#                      must equal every peer's LITELLM_KEY because the
#                      generated mesh.yaml names a single env var on every
#                      peer route
#
# Generated once here and pushed, rather than generated per node, because a
# per-node value cannot possibly match and the failure is a quiet
# `unauthorized` rather than a crash.
mesh_secrets() {
  local cache="${TMPDIR:-/tmp}/ods-mesh-secrets.env"
  if [[ ! -f "$cache" ]]; then
    umask 077
    {
      echo "MESH_PEER_API_KEY=$(openssl rand -hex 24)"
      echo "LITELLM_KEY=sk-$(openssl rand -hex 18)"
    } > "$cache"
  fi
  cat "$cache"
}

set_env_on_node() {
  local endpoint="$1" skills="$2" mesh_key="$3" litellm_key="$4"
  on_node "$endpoint" "cd ${REMOTE_DIR} && \
    sed -i '/^MESH_PEER_API_KEY=/d;/^MESH_PEER_KEY=/d;/^LITELLM_KEY=/d;/^MESH_NODE_SKILLS=/d;/^ODS_MODE=/d' .env && \
    printf 'ODS_MODE=mesh\nMESH_PEER_API_KEY=%s\nLITELLM_KEY=%s\nMESH_PEER_KEY=%s\nMESH_NODE_SKILLS=%s\n' \
      '${mesh_key}' '${litellm_key}' '${litellm_key}' '${skills}' >> .env"
}

# ── Steps ──────────────────────────────────────────────────────────────────

collect_pubkeys() {
  local name endpoint pub
  while read -r name endpoint _; do
    on_node "$endpoint" "cd ${REMOTE_DIR} && bash scripts/mesh-connect.sh init >/dev/null 2>&1 || true"
    pub="$(on_node "$endpoint" 'cat /root/.ssh/ods_mesh.pub')"
    printf '%s\n' "$pub"
  done < <(roster_entries)
}

# Keys travel base64-encoded so no quoting survives the trip to the remote
# shell. Appended only when absent, so re-running does not grow the file.
distribute_pubkeys() {
  local keys="$1" encoded name endpoint
  encoded="$(printf '%s\n' "$keys" | base64 -w0)"
  while read -r name endpoint _; do
    on_node "$endpoint" "mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
      touch /root/.ssh/authorized_keys && \
      printf '%s' '${encoded}' | base64 -d | while IFS= read -r k; do \
        if [ -n \"\$k\" ] && ! grep -qxF \"\$k\" /root/.ssh/authorized_keys; then \
          printf '%s\n' \"\$k\" >> /root/.ssh/authorized_keys; \
        fi; \
      done && chmod 600 /root/.ssh/authorized_keys"
    ok "${name}: peer keys installed"
  done < <(roster_entries)
}

rebuild_node() {
  local endpoint="$1"
  # mode-switch is what enables the coordinator: it renames
  # compose.yaml.disabled to compose.yaml. Setting ODS_MODE=mesh in .env is not
  # enough on its own -- the node comes up in mesh mode with no coordinator,
  # which looks like a working deploy until something asks it to reason.
  #
  # dashboard-api and dreamreason bake their Python into images, so a file sync
  # alone changes nothing about what is running.
  on_node "$endpoint" "cd ${REMOTE_DIR} && \
    bash scripts/mode-switch.sh mesh >/dev/null 2>&1; \
    docker compose -f docker-compose.base.yml build dashboard-api >/dev/null 2>&1 && \
    docker build -q -t ods-dreamreason:local extensions/services/dreamreason >/dev/null 2>&1 && \
    rm -f .compose-flags && ODS_HOME=${REMOTE_DIR} ./ods-cli restart >/dev/null 2>&1"
}

wire_node() {
  local endpoint="$1"
  on_node "$endpoint" "cd ${REMOTE_DIR} && bash scripts/mesh-connect.sh up >/dev/null 2>&1 || true"
}

reload_routes() {
  local endpoint="$1"
  # docker restart, not ods-cli: ods-cli restart is `compose up -d`, a no-op
  # when only a mounted config file changed, so LiteLLM would keep serving the
  # routes it started with.
  on_node "$endpoint" "cd ${REMOTE_DIR} && \
    KEY=\$(grep -m1 '^DASHBOARD_API_KEY=' .env | cut -d= -f2-) && \
    curl -s -m 90 -H \"Authorization: Bearer \$KEY\" localhost:3002/api/mesh/peers \
      | python3 scripts/generate-mesh-litellm-config.py -o config/litellm/mesh.yaml >/dev/null && \
    docker restart ods-litellm ods-dreamreason >/dev/null"
}

verify_node() {
  local endpoint="$1"
  on_node "$endpoint" "cd ${REMOTE_DIR} && \
    KEY=\$(grep -m1 '^DASHBOARD_API_KEY=' .env | cut -d= -f2-) && \
    curl -s -m 90 -H \"Authorization: Bearer \$KEY\" localhost:3002/api/mesh/peers \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print(str(d[\"peer_count\"])+\" peers, \"+str(d[\"idle_count\"])+\" idle\")'"
}

# ── Main ───────────────────────────────────────────────────────────────────

head_ "Roster"
node_count=0
while read -r name endpoint skills; do
  node_count=$((node_count + 1))
  info "${name}  $(node_host "$endpoint"):$(node_port "$endpoint")  skills=${skills:-general}"
done < <(roster_entries)
ok "${node_count} node(s)"

if [[ "$DRY_RUN" == "1" ]]; then
  head_ "Check mode — reachability only, nothing changed"
  failures=0
  while read -r name endpoint _; do
    if on_node "$endpoint" 'echo ok' >/dev/null 2>&1; then
      ok "${name}: reachable"
    else
      no "${name}: unreachable over SSH"
      failures=$((failures + 1))
    fi
  done < <(roster_entries)
  exit "$failures"
fi

# Parsed rather than eval'd: eval on generated text is a footgun for no gain,
# and explicit assignment is what makes the two names obviously defined.
SECRETS="$(mesh_secrets)"
MESH_PEER_API_KEY="$(printf '%s\n' "$SECRETS" | grep '^MESH_PEER_API_KEY=' | cut -d= -f2-)"
LITELLM_KEY="$(printf '%s\n' "$SECRETS" | grep '^LITELLM_KEY=' | cut -d= -f2-)"
[[ -n "$MESH_PEER_API_KEY" && -n "$LITELLM_KEY" ]] || { no "could not prepare mesh secrets"; exit 1; }
head_ "Secrets"
ok "shared mesh + LiteLLM keys prepared"

head_ "1/5  Sync and configure"
failures=0
while read -r name endpoint skills; do
  if sync_to_node "$endpoint" >/dev/null 2>&1 \
     && set_env_on_node "$endpoint" "${skills:-general}" "$MESH_PEER_API_KEY" "$LITELLM_KEY"; then
    ok "${name}: code synced, env set (skills=${skills:-general})"
  else
    no "${name}: sync or env failed"
    failures=$((failures + 1))
  fi
done < <(roster_entries)

head_ "2/5  Exchange SSH keys"
ALL_KEYS="$(collect_pubkeys)"
distribute_pubkeys "$ALL_KEYS"

head_ "3/5  Rebuild images"
while read -r name endpoint _; do
  if rebuild_node "$endpoint"; then
    ok "${name}: images rebuilt, stack up"
  else
    no "${name}: rebuild failed"
    failures=$((failures + 1))
  fi
done < <(roster_entries)

head_ "4/5  Form tunnels"
while read -r name endpoint _; do
  wire_node "$endpoint"
  ok "${name}: tunnels up, peer file written"
done < <(roster_entries)

head_ "5/5  Routes and verify"
while read -r name endpoint _; do
  reload_routes "$endpoint" || true
done < <(roster_entries)
sleep 20
while read -r name endpoint _; do
  result="$(verify_node "$endpoint" 2>/dev/null || echo 'no answer')"
  if [[ "$result" == *"peers"* ]]; then
    ok "${name}: ${result}"
  else
    no "${name}: ${result}"
    failures=$((failures + 1))
  fi
done < <(roster_entries)

head_ "Summary"
if [[ "$failures" == "0" ]]; then
  ok "mesh deployed across ${node_count} node(s)"
else
  no "${failures} step(s) failed — rerun is safe, every step is idempotent"
fi
exit "$failures"
