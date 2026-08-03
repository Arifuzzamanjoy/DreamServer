# DreamReason benchmark: mesh vs single node

Two arms over the same BBH items:

| Arm | Path |
|---|---|
| `single` | one completion from one model, straight through LiteLLM |
| `mesh` | the coordinator's `/v1/reason` — fan out to ≤3 peers, then select |

## Running it

```bash
bash scripts/mesh-bench/fetch-bbh.sh ./bbh

python3 scripts/mesh-bench/run-bbh.py \
    --task ./bbh/logical_deduction_three_objects.json \
    --limit 50 \
    --litellm     http://localhost:4000/v1 \
    --coordinator http://localhost:9200 \
    --single-model local \
    --skills reasoning logic general \
    --json-out results.json
```

Cost is reported as $0 unless you pass `--price-per-mtok`. An all-local mesh
has no per-token price, so tokens are the honest primary unit; dollars only
mean something against a cloud baseline.

## Results so far — read the caveat first

Measured on this repo, 14 items of `logical_deduction_three_objects`, against
**stub peers with synthetic latency and accuracy profiles**. No GPU or model
weights were available.

**The accuracy row is not a quality result.** The stubs were given fixed
per-peer accuracy rates, so mesh selection improves accuracy by construction.
It says nothing about real models. Every other row measures the real
coordination machinery — round trips, token fan-out, straggler behaviour — and
those numbers do transfer.

| metric | single | mesh | delta |
|---|---|---|---|
| accuracy | 0.357 | 0.429 | +0.071 *(stub artifact — ignore)* |
| latency p50 (s) | 0.46 | 1.12 | **+143.4%** |
| latency p95 (s) | 0.55 | 2.32 | **+321.6%** |
| tokens/item | 177 | 821 | **+364.8%** |
| straggler ratio | 1.00 | 1.72 | — |
| judge calls | 0 | 10/14 | — |

### The result that disappoints

**Token cost goes up ~4.6×, not down.** The deck's 90% cost reduction is not
achievable by this architecture, and neither is LLMRouterBench's ~32% — because
those measure a different thing. A *router* picks one cheaper model per query
and saves money. DreamReason *fans out*: three peers answer, and a judge reads
all three. Those are opposite cost structures. Fan-out buys quality with
tokens; it cannot also save them.

The ~32% target only becomes meaningful if the mesh is used to route *away*
from a paid cloud model toward idle local GPUs. Framed that way the saving is
real but it comes from displacing cloud spend, not from the mixture-of-agents
mechanism. Worth being precise about which claim is being made.

**Latency is materially worse**, as expected — MoA trades round trips for
quality. The straggler ratio of 1.72 shows the slowest peer taking nearly
twice the median, which is MOSAIC's documented failure mode (arXiv 2606.03014):
mixing instruction-tuned with long-reasoning models produces extreme
generation-length variance, and the whole fan-out waits on the slowest.

### A bug this benchmark caught

The first run reported **0 judge calls across all 14 items** — the consensus
bypass was firing every time. Peers that reason aloud share nearly all their
text and differ only in the final token, so `(A)`, `(B)` and `(C)` scored
0.957 on surface similarity and were treated as unanimous. Selection was
silently disabled on exactly the task being used to evaluate it.

Consensus now compares the *extracted answer* for structured replies and only
falls back to text similarity for free-form ones. The corrected numbers above
are worse than the buggy ones, because the judge now actually runs.

## Getting real numbers

On a host with GPUs and weights:

1. `bash scripts/mode-switch.sh mesh && ods restart`
2. Bring up peers — real ones on the tailnet, or
   `docker compose -f docker-compose.mesh-dev.yml up -d` on one box
3. Regenerate peer routes:
   `curl -s -H "Authorization: Bearer $KEY" localhost:3002/api/mesh/peers | \
    python3 scripts/generate-mesh-litellm-config.py -o config/litellm/mesh.yaml`
4. `ods restart litellm`
5. Run the benchmark above with `--limit 250` for a full task

Expect latency to stay worse. The open question real weights answer is whether
judge-based selection across heterogeneous peers recovers enough accuracy to
justify ~4.6× the tokens — which is exactly the crossover threshold
"When Agents Disagree" (arXiv 2603.20324) describes.
