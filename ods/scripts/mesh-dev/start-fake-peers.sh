#!/usr/bin/env bash
# Start three fake mesh peers on 8081/8082/8083.
#
# Use this when Docker, a GPU, or model weights are unavailable and you only
# need peer discovery / routing / aggregation to have something to talk to.
# For real inference use docker-compose.mesh-dev.yml instead.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pids_file="${MESH_DEV_PID_FILE:-/tmp/ods-mesh-dev-peers.pids}"

start_peer() {
    local port="$1" name="$2" skill="$3" skills="$4" model="$5" behavior="$6"
    python3 "${here}/fake-peer.py" \
        --port "${port}" --name "${name}" --skill "${skill}" \
        --skills "${skills}" --model "${model}" --behavior "${behavior}" \
        >"/tmp/ods-${name}.log" 2>&1 &
    echo "$!" >>"${pids_file}"
    echo "started ${name} on :${port} (skill=${skill}, behavior=${behavior})"
}

: >"${pids_file}"
start_peer 8081 mesh-peer-code      code      "code,algebra"    Qwen3.5-2B-Q4_K_M.gguf ok
start_peer 8082 mesh-peer-reasoning reasoning "reasoning,logic" Qwen3.5-9B-Q4_K_M.gguf ok
start_peer 8083 mesh-peer-general   general   "general"         Qwen3.5-2B-Q4_K_M.gguf ok

echo "pids recorded in ${pids_file}"
echo "stop with: xargs kill <${pids_file}"
