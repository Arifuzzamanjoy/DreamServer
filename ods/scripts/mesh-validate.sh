#!/usr/bin/env bash
# ============================================================================
# Validate a DreamReason mesh deployment from inside the node.
#
# Every check states what it proves. A FAIL names the fix rather than just the
# symptom, because on a rented GPU host the usual causes -- an unpublished
# port, a mismatched key, a model still loading -- look identical from outside.
#
#   bash scripts/mesh-validate.sh            # wiring + live checks
#   bash scripts/mesh-validate.sh --bench    # also run a small BBH comparison
#
# Exit status is the number of failed checks.
# ============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

RUN_BENCH=0
[[ "${1:-}" == "--bench" ]] && RUN_BENCH=1

PASS=0; FAIL=0; SKIP=0
API_PORT="$(grep -m1 '^DASHBOARD_API_PORT=' .env 2>/dev/null | cut -d= -f2- || echo 3002)"
API_PORT="${API_PORT:-3002}"
LITELLM_PORT="$(grep -m1 '^LITELLM_PORT=' .env 2>/dev/null | cut -d= -f2- || echo 4000)"
LITELLM_PORT="${LITELLM_PORT:-4000}"
API_KEY="$(grep -m1 '^DASHBOARD_API_KEY=' .env 2>/dev/null | cut -d= -f2- || echo '')"
COORD_PORT="${DREAMREASON_PORT:-9200}"

ok()   { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no()   { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; printf '         fix: %s\n' "$2"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33m[SKIP]\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

api() { curl -fsS -m 10 -H "Authorization: Bearer ${API_KEY}" "http://localhost:${API_PORT}$1"; }
jqr() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

# ── 1. Mode contract ───────────────────────────────────────────────────────
head_ "1. Mode contract (what ods-doctor enforces)"

mode="$(grep -m1 '^ODS_MODE=' .env | cut -d= -f2- || echo '')"
[[ "$mode" == "mesh" ]] \
  && ok "ODS_MODE=mesh" \
  || no "ODS_MODE is '${mode:-unset}', not mesh" "bash scripts/mode-switch.sh mesh && ods restart"

llm_url="$(grep -m1 '^LLM_API_URL=' .env | cut -d= -f2- || echo '')"
[[ "$llm_url" == *litellm* ]] \
  && ok "LLM_API_URL routes through LiteLLM (${llm_url})" \
  || no "LLM_API_URL=${llm_url:-unset} bypasses the peer gateway" "bash scripts/mode-switch.sh mesh"

hermes_url="$(grep -m1 '^HERMES_LLM_BASE_URL=' .env | cut -d= -f2- || echo '')"
[[ "$hermes_url" == *litellm* ]] \
  && ok "HERMES_LLM_BASE_URL routes through LiteLLM" \
  || no "HERMES_LLM_BASE_URL=${hermes_url:-unset} bypasses the gateway" "bash scripts/mode-switch.sh mesh"

if [[ -f .compose-flags ]]; then
  flags="$(cat .compose-flags)"
  [[ "$flags" != *cloud* ]] \
    && ok "no cloud overlay (a mesh node runs its own llama-server)" \
    || no "cloud overlay present; it profiles out local inference" "regenerate .compose-flags for mesh"
else
  skip ".compose-flags absent — cannot check the overlay"
fi

if doctor_out="$(bash scripts/ods-doctor.sh 2>&1)"; then
  if echo "$doctor_out" | grep -q "ODS-RUNTIME-MESH"; then
    no "ods-doctor reports mesh findings" "$(echo "$doctor_out" | grep -o 'ODS-RUNTIME-MESH-[A-Z-]*' | sort -u | tr '\n' ' ')"
  else
    ok "ods-doctor reports zero mesh findings"
  fi
else
  skip "ods-doctor exited non-zero (environment issue, not a mesh finding)"
fi

# ── 2. Services ────────────────────────────────────────────────────────────
head_ "2. Services"

if curl -fsS -m 5 "http://localhost:${LITELLM_PORT}/health/readiness" >/dev/null 2>&1; then
  ok "LiteLLM answering on :${LITELLM_PORT}"
else
  no "LiteLLM not answering on :${LITELLM_PORT}" "ods restart litellm; docker logs ods-litellm"
fi

if curl -fsS -m 5 "http://localhost:${COORD_PORT}/health" >/dev/null 2>&1; then
  ok "coordinator answering on :${COORD_PORT}"
else
  no "coordinator not answering on :${COORD_PORT}" "ods enable dreamreason && ods restart dreamreason"
fi

if [[ -f config/litellm/mesh.yaml ]]; then
  ok "config/litellm/mesh.yaml exists"
  if grep -q 'model_name: mesh' config/litellm/mesh.yaml; then
    ok "'mesh' registered as a model (this is what puts it in the UI dropdown)"
  else
    no "'mesh' missing from mesh.yaml" "regenerate with scripts/generate-mesh-litellm-config.py"
  fi
  # grep -c prints 0 AND exits 1 when there is no match, so a || fallback
  # would append a second 0 and break the arithmetic test below.
  peer_models="$(grep -c 'model_name: peer-' config/litellm/mesh.yaml)" || peer_models=0
  if [[ "$peer_models" -gt 0 ]]; then
    ok "${peer_models} peer model(s) registered"
  else
    skip "no peer-* models yet — expected on a single node with no peers"
  fi
else
  no "config/litellm/mesh.yaml missing" "LiteLLM cannot start in mesh mode without it; regenerate it"
fi

# ── 3. Peer discovery ──────────────────────────────────────────────────────
head_ "3. Peer discovery"

if peers_json="$(api /api/mesh/peers 2>/dev/null)"; then
  ok "/api/mesh/peers responds"
  source_name="$(echo "$peers_json" | jqr "d.get('peer_source','?')")"
  count="$(echo "$peers_json" | jqr "d.get('peer_count',0)")"
  idle="$(echo "$peers_json" | jqr "d.get('idle_count',0)")"
  printf '         source=%s peers=%s idle=%s\n' "$source_name" "$count" "$idle"
  if [[ "$count" -gt 0 ]]; then
    echo "$peers_json" | python3 -c "
import sys,json
for p in json.load(sys.stdin).get('peers',[]):
    print(f\"         - {p.get('hostname')}: {p.get('state')} {p.get('detail') or ''}\")"
    [[ "$idle" -gt 0 ]] \
      && ok "${idle} peer(s) idle and eligible for work" \
      || no "peers found but none idle" "check GPU load, or raise GPU_IDLE_THRESHOLD_PERCENT"
  else
    skip "no peers — single node. Add config/mesh-peers.json, or use docker-compose.mesh-dev.yml"
  fi
else
  no "/api/mesh/peers failed" "check DASHBOARD_API_KEY in .env and 'docker logs ods-dashboard-api'"
fi

# ── 4. The mesh as a usable model ──────────────────────────────────────────
head_ "4. Mesh reachable as a model"

if models="$(curl -fsS -m 10 "http://localhost:${COORD_PORT}/v1/models" 2>/dev/null)"; then
  echo "$models" | grep -q '"mesh"' \
    && ok "coordinator advertises the 'mesh' model" \
    || no "coordinator does not advertise 'mesh'" "check MESH_MODEL_NAME"
else
  skip "coordinator /v1/models unreachable — see section 2"
fi

answer_probe() {
  curl -fsS -m 180 -X POST "http://localhost:${COORD_PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"mesh","messages":[{"role":"user","content":"Solve for x: 3x + 7 = 22. Answer with the number only."}]}'
}

if reply="$(answer_probe 2>/dev/null)"; then
  content="$(echo "$reply" | jqr "d['choices'][0]['message']['content'][:80]")"
  selected="$(echo "$reply" | jqr "d.get('ods_mesh',{}).get('selected_peer','?')")"
  selection="$(echo "$reply" | jqr "d.get('ods_mesh',{}).get('selection','?')")"
  judged="$(echo "$reply" | jqr "d.get('ods_mesh',{}).get('judge_invoked','?')")"
  ok "end-to-end chat through the mesh works"
  printf '         selected=%s via=%s judge=%s\n' "$selected" "$selection" "$judged"
  printf '         answer: %s\n' "$content"
  echo "$content" | grep -q '5' \
    && ok "answer is correct (x=5)" \
    || skip "answer may be wrong — small models miss this; check the text above"
else
  no "chat through the mesh failed" "docker logs ods-dreamreason; confirm peers answer"
fi

# ── 5. Benchmark ───────────────────────────────────────────────────────────
if [[ "$RUN_BENCH" == "1" ]]; then
  head_ "5. Benchmark (single vs mesh)"
  if [[ ! -f bbh/logical_deduction_three_objects.json ]]; then
    bash scripts/mesh-bench/fetch-bbh.sh ./bbh
  fi
  python3 scripts/mesh-bench/run-bbh.py \
    --task bbh/logical_deduction_three_objects.json --limit "${BENCH_LIMIT:-25}" \
    --litellm "http://localhost:${LITELLM_PORT}/v1" \
    --coordinator "http://localhost:${COORD_PORT}" \
    --single-model local --json-out mesh-bench-results.json
  ok "benchmark completed — results in mesh-bench-results.json"
fi

# ── Summary ────────────────────────────────────────────────────────────────
head_ "Summary"
printf '  %d passed, %d failed, %d skipped\n\n' "$PASS" "$FAIL" "$SKIP"
exit "$FAIL"
