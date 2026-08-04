# Running the DreamReason mesh on Vast.ai

The p2p-gpu toolkit is single-instance by design. Mesh mode spans instances, so
three things differ from a normal deploy.

## What changed, and why

**1. No tailnet.** The toolkit has no Tailscale support — access is SSH tunnel
plus Cloudflare, and Tailscale in a rented container needs `/dev/net/tun` and
`NET_ADMIN`, which are not guaranteed. So peers are *declared* by address in
`config/mesh-peers.json` rather than discovered. `MESH_PEER_SOURCE=auto` uses
that file when it exists and falls back to the tailnet when it does not, so the
same build works on both.

**2. Ports are remapped.** Vast.ai publishes each internal port on a different
external one, exposed as `VAST_TCP_PORT_<internal>`. Peers therefore carry
explicit `api_port` and `litellm_port`; the old assumption that every node uses
3002 and 4000 only holds on a tailnet.

> **These ports must be requested when the instance is CREATED.** They cannot
> be opened afterwards. Ask for **3002** and **4000** on every instance, or the
> nodes cannot reach each other and every peer reports `unreachable`.

**3. The coordinator is opt-in.** It ships disabled and only builds when mesh
mode is selected, so a normal single-instance deploy does not spend minutes
building an image it will never run.

## Deploy the right code first

The installer clones a repository rather than using the checkout you run
`setup.sh` from, and it defaults to upstream `main` — which has none of this.
Point it at the branch you want:

```bash
export ODS_REPO_URL="https://github.com/Arifuzzamanjoy/DreamServer.git"
export ODS_REPO_BRANCH="feat/mesh-reasoning"
```

If ODS is already installed, phase 3 reuses `/home/dream/ODS` and never
re-clones, so the exports alone will not replace an existing checkout. Either
remove it first, or repoint it by hand:

```bash
sudo -u dream git -C /home/dream/ODS remote set-url origin "$ODS_REPO_URL"
sudo -u dream git -C /home/dream/ODS fetch origin "$ODS_REPO_BRANCH"
sudo -u dream git -C /home/dream/ODS checkout "$ODS_REPO_BRANCH"
```

## Deploy

On **each** instance, as root:

```bash
export ODS_MESH=1
export ODS_MESH_KEY="$(openssl rand -hex 24)"   # SAME value on every node
bash setup.sh --mesh
```

Generate `ODS_MESH_KEY` **once** and reuse it. A mismatch does not fail loudly —
peers come back as `state=unauthorized`, which is a distinct state precisely so
you can tell it apart from a network problem.

At the end, each node prints its own coordinates:

```json
{ "hostname": "vast-a", "host": "203.0.113.10", "api_port": 41287, "litellm_port": 41288 }
```

## Wire the peers together

On every node, write `config/mesh-peers.json` listing the **other** nodes (a
node does not list itself):

```json
{ "peers": [
  { "hostname": "vast-b", "host": "198.51.100.22", "api_port": 39104, "litellm_port": 39105 }
] }
```

Confirm discovery sees them:

```bash
curl -s -H "Authorization: Bearer $DASHBOARD_API_KEY" \
    localhost:3002/api/mesh/peers | python3 -m json.tool
```

Expect `peer_source: "static"` and `state: "online-idle"` per peer. Anything
else is diagnostic, not a generic failure:

| state | meaning |
|---|---|
| `unreachable` | port not published at instance creation, or wrong external port |
| `timed-out` | reachable but slow — usually a model still loading |
| `unauthorized` | `MESH_PEER_API_KEY` differs between nodes |
| `online-busy` | peer is up but its GPU is above the idle threshold |

Then generate the peer routes and restart, on every node:

```bash
curl -s -H "Authorization: Bearer $DASHBOARD_API_KEY" localhost:3002/api/mesh/peers \
  | python3 scripts/generate-mesh-litellm-config.py -o config/litellm/mesh.yaml
./ods-cli restart litellm dreamreason
```

## Reaching it from your laptop

The tunnel only forwards the dashboard port unless you ask for everything:

```bash
FULL_TUNNEL=1 bash connect-tunnel.sh
```

That forwards every discovered service port, including the coordinator on
9200. A plain `ssh -L 8080:localhost:8080` will not reach it — that is what
ERR_CONNECTION_REFUSED on http://localhost:9200 means. The manual equivalent:

```bash
ssh -p <ssh-port> root@<host> \
    -L 9200:localhost:9200 \
    -L 3001:localhost:3001 \
    -L 3000:localhost:3000 \
    -L 4000:localhost:4000
```

## Verify

```bash
bash scripts/ods-doctor.sh          # expect zero ODS-RUNTIME-MESH-* findings
curl -s localhost:9200/health       # coordinator
curl -s -X POST localhost:9200/v1/reason \
    -H 'Content-Type: application/json' \
    -d '{"question":"Solve for x: 3x + 7 = 22","skills":["algebra","reasoning","general"]}'
```

A good response names the peer that won and why, and the answer is that peer's
answer verbatim — the aggregator selects, it never blends.

## Using it from the UI

After regenerating `mesh.yaml`, Open WebUI's model dropdown gains a **`mesh`**
entry alongside the individual `peer-*` models. Picking `mesh` sends the turn
through fan-out and judge selection; picking a `peer-*` model talks to that one
peer directly, with no selection.

Set `MESH_SHOW_RATIONALE=true` to append the winning peer and the reason to
each reply — useful while validating, noisy afterwards.

The full audit trail is always present on the `ods_mesh` field of the response
for anything that inspects it, and `POST /v1/reason` on port 9200 returns it
directly.

## Testing on a single instance

One node has no peers, so `mesh` has nothing to fan out to and returns 502.
To exercise selection on one machine, run three llama-servers on the stack
network and register them:

```bash
cd /home/dream/ods
docker compose -f docker-compose.mesh-dev.yml up -d

python3 scripts/generate-mesh-litellm-config.py --dev-peers \
    --peers-json <(echo '{"peers":[]}') -o config/litellm/mesh.yaml
docker restart ods-litellm ods-dreamreason
```

Those peers are bare llama-servers, so they are addressed on `:8080` rather
than a peer LiteLLM on `:4000`. The gateway rule applies to real peers on other
machines; there is no second gateway here to route through.

Both models must already be in `data/models`:
`Qwen3.5-2B-Q4_K_M.gguf` and `Qwen3.5-9B-Q4_K_M.gguf`. Use
`MESH_DEV_REASONING_GGUF=Qwen3.5-2B-Q4_K_M.gguf` to run all three on the 2B if
VRAM is tight.

## Benchmark

```bash
bash scripts/mesh-bench/fetch-bbh.sh ./bbh
python3 scripts/mesh-bench/run-bbh.py \
    --task ./bbh/logical_deduction_three_objects.json --limit 250 \
    --coordinator http://localhost:9200 --litellm http://localhost:4000/v1
```

Expect latency to get worse and token use to rise several-fold; see
`scripts/mesh-bench/README.md` for why that is structural rather than a
regression.

## Security note

`expose_ports_for_vastai()` rebinds every published port from `127.0.0.1` to
`0.0.0.0`, which is what makes cross-instance peering possible — and also means
LiteLLM and dashboard-api are reachable from the public internet. Both require
auth (`LITELLM_KEY` is generated by the installer, dashboard-api enforces
`DASHBOARD_API_KEY`), so this is not an open relay, but treat those keys as
production secrets and tear instances down when the test finishes.
