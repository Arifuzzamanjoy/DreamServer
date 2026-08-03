# Mesh development scaffolding

Scratch tooling for DreamReason. **Not part of the extension system** — nothing
here is a service manifest, and `scripts/resolve-compose-stack.sh` never merges
it. It exists so mesh behaviour can be developed without a second machine.

Peers are named by **skill**, not hostname. Skill-level routing is the finding
from Symbolic-MoE (arXiv 2503.05641): routing on `algebra` rather than `math`
measured +8.15% absolute over the best multi-agent baseline.

## Option A — real inference (needs Docker + GPU + weights)

Three llama-server containers on one host:

```bash
docker compose -f docker-compose.mesh-dev.yml up -d
```

| Peer | Port | Default model | Tier |
|---|---|---|---|
| `mesh-peer-code` | 8081 | `Qwen3.5-2B-Q4_K_M.gguf` | 0 (1221 MB) |
| `mesh-peer-reasoning` | 8082 | `Qwen3.5-9B-Q4_K_M.gguf` | 1 (5760 MB) |
| `mesh-peer-general` | 8083 | `Qwen3.5-2B-Q4_K_M.gguf` | 0 (1221 MB) |

Models must already exist in `./data/models`. Run on CPU with
`MESH_DEV_GPU_LAYERS=0`.

## Option B — fake peers (no Docker, no GPU, no weights)

```bash
bash scripts/mesh-dev/start-fake-peers.sh
xargs kill </tmp/ods-mesh-dev-peers.pids   # stop
```

`fake-peer.py` mimics response *shapes* only and does no inference. It serves
the two endpoints peer discovery composes, plus a chat endpoint:

- `GET /api/node/capabilities`
- `GET /api/gpu/idle`
- `POST /v1/chat/completions`
- `GET /v1/models`, `GET /health`

### Behaviours

`--behavior` maps each failure mode to a distinct observable outcome, so peer
states stay distinguishable rather than collapsing into one generic error:

| Behaviour | Effect | Discovery should report |
|---|---|---|
| `ok` | answers normally | `online-idle` |
| `busy` | healthy, GPU at 95% | `online-busy` |
| `hang` | accepts, never responds | `timed-out` |

A port with nothing listening exercises `unreachable`.
