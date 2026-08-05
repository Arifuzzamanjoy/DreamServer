# DreamReason benchmark: mesh vs single node

Two arms over the same BBH items:

| Arm | Path |
|---|---|
| `single` | one completion from one model, straight through LiteLLM |
| `mesh` | the coordinator's `/v1/reason` — fan out to ≤3 peers, then select |

## Requirements

The runner talks HTTP from the host, so it needs httpx outside the containers:

```bash
pip3 install --break-system-packages httpx
```

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

## Results on real hardware

Three Vast.ai nodes, three different models, one GPU each. Raw output in
`results/`.

| node | GPU | model | role |
|---|---|---|---|
| vast-3060 | RTX 3060 12GB | Qwen3.5-9B-Q4_K_M | coordinator — `local` and the `single` baseline |
| vast-3090-2 | RTX 3090 24GB | DeepSeek-R1-Distill-Qwen-32B | `peer-reasoning` |
| vast-4090 | RTX 4090 24GB | gemma-4-31B-it-Q4_0 | `peer-logic` |

The coordinator runs the **weakest** model on purpose. Whichever node
coordinates is both `local` and the single-node baseline, so putting the
strongest model there saturates the baseline and leaves selection nothing to
win — which is exactly how an earlier run measured single 30/30 against mesh
24/30.

| task | items | single | mesh | delta | tokens/item | p50 latency |
|---|---|---|---|---|---|---|
| `logical_deduction_three_objects` | 30 | 1.000 | 1.000 | +0.000 | 350 → 1150 | 4.5s → 10.0s |
| `logical_deduction_five_objects` | 30 | 0.967 | 1.000 | +0.033 | 793 → 2349 | 9.9s → 25.0s |
| `logical_deduction_seven_objects` | 20 | 0.900 | 1.000 | +0.100 | 1144 → 3193 | 15.7s → 32.2s |

**Do not read the deltas as wins.** On the seven-object task `local` scored
0.900 as the `single` arm and 1.000 as a mesh candidate — the same model, the
same twenty questions, two stochastic samples differing by two items. That
accounts for the entire margin. With n=20 and two discordant items the result
is not significant, and the same caveat applies to the one-item margin at five
objects. Settling it needs greedy decoding, so `local` cannot differ between
arms, at n >= 100.

What the runs *do* establish:

* The mesh never scored **below** the baseline on any task. That floor is what
  `peer_models` exists to provide and previously did not.
* Selection left **nothing** on the table: oracle 1.000 against mesh 1.000 at
  seven objects. Whenever a correct answer was among the candidates it came
  back.
* The judge fired **zero times in 80 items**. Consensus and plurality resolved
  everything, which is the cheap path working as designed.
* **Declared skills are not capability.** DeepSeek-R1 scored 0.900 on
  seven-object deduction while Gemma and the 9B both scored 1.000 — the worst
  of the three on the task its `MESH_NODE_SKILLS=reasoning` label claims. This
  is the premise the capability ledger acts on, now measured rather than
  asserted.

### The result that disappoints

**Token cost goes up ~3.3×, not down.** The deck's 90% cost reduction is not
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
quality. Straggler ratio measured 2.0–2.5 across the three tasks, and the cause
is visible per-model: on one three-object item DeepSeek-R1 spent 948 completion
tokens reaching its answer where Gemma spent 128. That is MOSAIC's documented
failure mode (arXiv 2606.03014) — mixing instruction-tuned with long-reasoning
models produces extreme generation-length variance, and the whole fan-out waits
on the slowest.

It also sets a floor on `MESH_MAX_TOKENS`. At the old default of 512 the
reasoning peer is cut off mid-thought and scores zero on every item, so the run
would measure the cap rather than the mesh. Any mesh carrying a long-CoT model
needs 2048.

### A bug this benchmark caught

The first run reported **0 judge calls across all 14 items** — the consensus
bypass was firing every time. Peers that reason aloud share nearly all their
text and differ only in the final token, so `(A)`, `(B)` and `(C)` scored
0.957 on surface similarity and were treated as unanimous. Selection was
silently disabled on exactly the task being used to evaluate it.

Consensus now compares the *extracted answer* for structured replies and only
falls back to text similarity for free-form ones. The corrected numbers above
are worse than the buggy ones, because the judge now actually runs.

## Reproducing, and what to fix in the method

`bash scripts/mesh-deploy.sh` brings up every node in `config/mesh-nodes.conf`,
then run the benchmark from the coordinator. Two things the runs above got
wrong, worth fixing before trusting a next result:

1. **Sampling was stochastic**, so `local` could and did score differently as
   the `single` arm than as a mesh candidate. Every reported delta is inside
   that noise. Run both arms greedy.
2. **n was too small.** 20–30 items puts the standard error near ±0.09, wider
   than any margin measured. Use `--limit 250` for a full task.

Give each node different weights. Three nodes running the same model is the
homogeneous regime where diverse-team selection scores 0.512, near chance,
against 0.810 for genuinely different peers (arXiv 2603.20324) — fan-out buys
nothing there and still costs the tokens.

Pick tasks the aggregator can compare. `consensus_key` extracts option letters
and yes/no/true/false/valid/invalid; anything answering with a number or free
text falls back to comparing the prose around the answer, which scores ~0.96
between peers that disagree and silently disables selection. `fetch-bbh.sh`
lists only compatible tasks and says why.

The open question is unchanged: whether selection across heterogeneous peers
recovers enough accuracy to justify ~3.3× the tokens — the crossover threshold
"When Agents Disagree" (arXiv 2603.20324) describes. These runs did not answer
it. They established that the mesh no longer loses, which it reliably did
before.

---

# Routing: keyword vs semantic

`compare-routers.py` scores both routers on `routing-eval.json`, 25 labelled
prompts across 7 skills.

```bash
python3 scripts/mesh-bench/compare-routers.py --arms keyword semantic
```

The semantic arm needs TEI and Qdrant. Seed the capability vectors first:

```bash
python3 scripts/mesh-seed-capabilities.py \
    --tei http://localhost:8081 --qdrant http://localhost:6333
```

| Router | Accuracy | Cost per route |
|---|---|---|
| keyword (baseline) | **1.000** (25/25) | **0.047 ms** |
| semantic (stub embedder) | 0.720 (18/25) | 46.3 ms |

## Read these caveats before drawing a conclusion

**The semantic number is not a verdict on embeddings.** No GPU or TEI model was
available, so that arm ran against a stub bag-of-words hash embedder. A real
sentence-embedding model would score far higher. What the run establishes is
that the wiring, seeding, threshold and comparison harness all work end to end
— not that embeddings lose.

**The keyword baseline was tuned on this set.** Out of the box it scored 0.920
(23/25). The eval exposed two genuine rule bugs — a word-order-dependent regex
that missed "argument valid or invalid", and code rules with no crash
vocabulary, so "why does this program segfault" routed to `reasoning`. Both
fixes generalise beyond the eval, but 1.000 is partly in-sample and the honest
out-of-sample figure is closer to 0.92.

## What does transfer

Even against a stub embedder running on loopback, semantic routing cost
**46 ms per route against 0.047 ms** — three orders of magnitude. A real
TEI round trip plus a Qdrant query over the network will not be cheaper.

So the bar is concrete: embeddings must beat a ~0.92–1.00 keyword baseline by
enough to justify ~1000x the routing latency and two extra services on the
critical path of every request. That is a high bar, and it is why
`MESH_ROUTER` defaults to `keyword`.

Where embeddings should win is the case regexes cannot reach: prompts phrased
with none of the trigger vocabulary, and new skills added without writing
rules. If that matters for a deployment, run this comparison with a real TEI
model before switching.
