# SOTA check: what the DreamReason deck claims, and what the papers say

Every citation in the pitch deck verified against the live source in August
2026. Four hold up, two need correcting, and one paper argues against part of
the premise. The last section is the part that matters: what is actually
implemented in this repo is none of the cited architectures.

## Citation audit

| Deck claim | Verdict |
|---|---|
| MoA, "> GPT-4 using 70B open models" | **Holds** |
| RouteMoA, "90% cost reduction" | **Holds** (89.8%) |
| Symphony, "86% accuracy on BBH", 2026 | **Correct the year and the number** |
| WWW.Serve, CMU, trustless credit + convergence proof | **Holds**; affiliation unverified |
| Tran 2025, collaborative reasoning survey | **Holds** |

### MoA — arXiv 2406.04692

Layered architecture: each layer's agents receive *all* outputs from the
previous layer as auxiliary information, and an aggregator synthesises. Scores
65.1% on AlpacaEval 2.0 against GPT-4 Omni's 57.5%, using only open-source
models. The deck's claim is accurate.
Source: https://arxiv.org/abs/2406.04692

### RouteMoA — arXiv 2601.18130 (January 2026)

A lightweight scorer predicts coarse-grained performance from the query and
narrows the candidate pool **without running inference**; a mixture of judges
then refines scores using outputs that already exist. Reports **89.8% cost
reduction and 63.6% latency reduction** on a large model pool. The deck's "90%"
is a fair rounding.
Source: https://arxiv.org/abs/2601.18130

### Symphony — arXiv 2508.20019 (August **2025**, not 2026)

Closest published work to this project: lightweight LLMs on consumer GPUs
(RTX, Jetson, Apple M-series), coordinated by three mechanisms — a
**decentralized ledger recording capabilities**, a **Beacon-selection protocol**
for dynamic task allocation, and **weighted result voting over Chain-of-Thoughts**.

Two corrections to the deck. The date is 2025. And "86% accuracy on BBH" is not
a headline result — the paper reports absolute gains of **6.5%–41.6% over direct
solving** and 6.5%–29.1% over AutoGen, and separately notes that the spread
across models narrows from 36%–73% to **78%–87%** once Symphony is applied. 86%
is a point inside that band, not the reported accuracy. Quote the gain over
baseline instead; it is both defensible and more impressive.
Source: https://arxiv.org/abs/2508.20019

### WWW.Serve — arXiv 2603.20661 (March 2026)

Decentralized market of anonymous LLM servers: credit-based trustless request
delegation, gossip-driven peer synchronisation, and a duel-and-judge mechanism
for evaluating contributors, with a proof of convergence to a high-quality
equilibrium — good nodes accrue credit, poor nodes lose exposure. The mechanism
claims hold. The CMU attribution in the deck was not confirmed.
Source: https://arxiv.org/abs/2603.20661

### Tran et al. 2025 — arXiv 2501.06322

"Multi-Agent Collaboration Mechanisms: A Survey of LLMs." Frames collaboration
by actors, type, structure, strategy and coordination protocol. Exists, and
supports the general claim.
Source: https://arxiv.org/abs/2501.06322

## The paper that pushes back — arXiv 2606.02646

Already cited in `coordinator.py` for the fan-out cap, and it holds up: thirty
dense debating agents produce no more answer diversity than one on MMLU-Hard,
and LLM debate degrades far faster with group size than human groups
(t ≤ 0.13 vs 0.49–0.90).

The finding the deck should absorb: **within homogeneous teams, the gain usually
credited to "debate" comes from re-evaluation, not from peer content.** So a
mesh of identical models gains little from collaboration as such. The value is
in *heterogeneity* — which is exactly what the deck's expert-mesh diagram shows
and what a single-account Vast testbed running one GGUF everywhere does not.
Source: https://arxiv.org/abs/2606.02646

## Synthesis is not a missing feature — it is a rejected one

Checked because the deck lists "Aggregate text" as a pipeline stage and the
obvious reading is that `aggregator.py` simply has not got there yet. It has.
The two papers its docstring cites both hold up, and both argue the other way.

**When Agents Disagree: The Selection Bottleneck in Multi-Agent LLM Pipelines**
— arXiv 2603.20324. Crosses team composition against aggregation mechanism over
42 tasks in seven categories. A diverse pool's value *is* its variance: one
standout candidate. Selection evaluates candidates individually and takes it;
synthesis compresses everything into one blended response and forfeits it.
**Selection wins in all 42 tasks, and synthesis outputs lose to a single-model
baseline more than 80% of the time.**
Source: https://arxiv.org/abs/2603.20324

**Rethinking Mixture-of-Agents: Is Mixing Different LLMs Beneficial?** — arXiv
2502.00674. Self-MoA, sampling only the single best model, beats mixed MoA by
6.6% on AlpacaEval 2.0 and 3.8% averaged over MMLU, CRUX and MATH, because
mixing lowers the pool's average quality.
Source: https://arxiv.org/abs/2502.00674

So adding synthesis to the fan-out path would likely make this mesh worse than
running one model. "Never blends" is the evidence-backed choice, and the deck
box should read **Select best answer**.

One distinction to preserve. The finding is about blending N competing answers
to the *same* question. Composing answers to *different* sub-questions is a
different regime that neither paper measures, so if decomposition is built
later, its composition step is not condemned by the 80% figure.

## Where the implementation actually sits

This is the gap worth naming before any more building.

**The deck promises:** decompose a query into sub-tasks → route each sub-task to
the best-fit idle node → synthesise a final answer.

**`coordinator.py` implements:** send the *same* question to N peers → if they
agree, return one verbatim → otherwise a judge picks one verbatim.

There is no decomposition step, and `aggregator.py` never synthesises — its
docstring states the selection "never blends". That is a defensible design, but
it is neither the deck's pipeline nor any of the cited architectures:

* **MoA** is layered *synthesis* — agents see each other's outputs and an
  aggregator composes a new answer. The current code has one layer and no
  synthesis.
* **Symphony** is capability-ledger routing plus *weighted CoT voting*. The
  current judge is a single LLM call selecting an index, not weighted voting.
* **RouteMoA** routes *before* inference to avoid paying for every candidate.
  The current coordinator queries all N and pays for all N.

So the honest description of what exists today is **best-of-N sampling with an
LLM judge**. Useful, cheap to reason about, and roughly the selection layer of
MoA — but not collaborative reasoning in the sense the deck describes.

## What each cited paper would actually change here

Ordered by value per unit of work on this codebase.

1. **RouteMoA-style pre-inference routing.** The largest measurable win and the
   smallest change. A lightweight scorer picks which peers to query instead of
   fanning out to a fixed N. Directly attacks the cost and latency the existing
   benchmark already shows getting worse. Does not require touching the judge.

2. **Symphony's capability ledger.** This is what peer discovery in this repo is
   already growing into — `MESH_NODE_SKILLS` plus `/api/mesh/peers` is a
   centralised version of it. Making skills richer (measured, not declared) is
   incremental and does not need a new protocol.

3. **MoA-style synthesis.** Replaces selection with composition and is the step
   that would make the deck's diagram true. Largest change: it supersedes
   `aggregator.py`'s select-one contract and invalidates the current benchmark
   comparison.

4. **Decomposition.** The deck's first box, and the least supported by the cited
   work — none of MoA, Symphony or RouteMoA decompose. It is a planner pattern,
   and adding it means owning sub-task dependency and failure semantics.

5. **WWW.Serve's credit system.** Only meaningful for open membership with
   untrusted nodes. Irrelevant to a single-account testbed, and worth revisiting
   only if the volunteer-mesh premise gets picked up.

## First measured run — three real nodes, August 2026

30 items of `logical_deduction_three_objects`, both arms over the same items.
Mesh: node A coordinating, Qwen3.5-9B on A and B, Llama-3.1-8B on C, over SSH
tunnels. Single: `local` straight through LiteLLM.

| metric | single | mesh | delta |
|---|---|---|---|
| accuracy | **1.000** | **0.800** | **−0.200** |
| failed to answer | 0 | 1 | |
| latency p50 | 4.98s | 3.65s | −26.8% |
| latency p95 | 10.03s | 5.78s | −42.4% |
| tokens/item | 353 | 670 | +90.1% |
| straggler ratio | 1.00 | 2.20 | |
| judge calls | 0 | 9/30 | |

**Read the methodology before the numbers.** The baseline scored 100%: Qwen3.5-9B
saturates this task, so the mesh could not win it, only lose it. The correct
conclusion is not "the mesh does not work" — it is "this experiment could not
have shown that it does". A task with single-node accuracy around 0.4–0.7 is
the only kind that can answer the question in either direction.

What the run does establish is that fan-out **introduced** errors on items a
single node already got right, at +90% tokens. Nine items reached the judge and
it chose wrong often enough to turn a perfect score into 0.800 — which is the
Self-MoA and Ringelmann prediction showing up on real hardware rather than in a
paper. Adding agents to a model that was already correct costs accuracy.

Faster latency is not a mesh win here: peers ran shorter completions, and the
straggler ratio of 2.20 shows fan-out still waiting 2.2x the mean peer.

Two artefacts were found and removed before trusting these numbers. Failures
were first recorded at the full timeout budget rather than their real elapsed
time, which put a fabricated 300s into p95 — they were fast 502s. And an
unparseable judge verdict surfaced as a 500 with a stack trace instead of a
gateway error, aborting the whole run. Both fixed; the table above is the
re-run.

## Recommendation

Fix the deck's two factual errors (Symphony's year, and the 86% figure). Then,
if the goal is to close the gap between promise and code, do RouteMoA-style
routing first — it is the cheapest change with a measurable result, and unlike
synthesis it does not invalidate the benchmark that already exists.

Do not describe the current system as MoA or as collaborative reasoning until
synthesis lands. Calling it best-of-N with a judge is accurate and still a real
result.
