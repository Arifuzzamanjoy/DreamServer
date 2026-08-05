#!/usr/bin/env python3
"""Benchmark DreamReason mesh reasoning against a single node on BBH.

Two arms over the same items:

  single  one completion from one model, straight through LiteLLM
  mesh    the coordinator's /v1/reason -- fan out to <=3 peers, then select

Expect mesh latency to be WORSE. Mixture-of-agents trades round trips for
quality, and heterogeneous peers add straggler effects on top (MOSAIC,
arXiv 2606.03014). The straggler ratio is reported rather than hidden.

Cost expectations are calibrated to LLMRouterBench (Jan 2026; 23,945 prompts,
391,645 query-model tuples), which measured flagship routers at ~32% cost
reduction with no accuracy loss -- not the 90% figure in the deck. For an
all-local mesh the honest primary unit is tokens; dollars only mean something
against a cloud baseline price, so --price-per-mtok is opt-in.

    python3 run-bbh.py --task bbh/logical_deduction_three_objects.json \
        --limit 50 --coordinator http://localhost:9200 \
        --litellm http://localhost:4000/v1 --single-model local
"""

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bench_lib import delta_pct, is_correct, straggler_ratio, summarize  # noqa: E402

MC_INSTRUCTION = (
    "\n\nAnswer with the option letter in parentheses, e.g. (A). "
    "Give the answer on the last line."
)
# BBH is not uniformly multiple choice. formal_fallacies answers valid/invalid,
# web_of_lies and causal_judgement answer Yes/No, boolean_expressions answers
# True/False -- and telling those models to reply with an option letter asks
# for something the task has none of. The reply then scores as wrong for
# following a bad instruction rather than for reasoning badly, on exactly the
# hard tasks that are worth running. Both forms are ones consensus_key can
# extract, so selection still works either way.
WORD_INSTRUCTION = (
    "\n\nGive the answer on the last line as a single word, using the wording "
    "the question offers (for example: valid or invalid, Yes or No, "
    "True or False). Put nothing else on that line."
)


def instruction_for(examples: list) -> str:
    """The answer-format instruction this task needs. Pure.

    Chosen from the targets rather than the task name, so a task added to the
    fetch list gets the right instruction without anyone remembering to say so.
    """
    targets = {str(e["target"]).strip() for e in examples}
    if targets and all(t.startswith("(") and t.endswith(")") for t in targets):
        return MC_INSTRUCTION
    return WORD_INSTRUCTION


def load_task(path: Path, limit: int) -> list:
    """Load a BBH task file. Standard shape: {'examples': [{input, target}]}."""
    data = json.loads(path.read_text())
    examples = data["examples"] if isinstance(data, dict) else data
    return examples[:limit] if limit else examples


def auth_headers(key: str) -> dict:
    """Bearer header for LiteLLM. The gateway runs with a master key in every
    real deployment, so an unauthenticated benchmark just measures 401s."""
    return {"Authorization": f"Bearer {key}"} if key else {}


async def run_single(client, litellm, model, question, timeout, key="",
                     max_tokens=0):
    """One completion straight from one model.

    *max_tokens* must match the coordinator's MESH_MAX_TOKENS. The mesh caps
    every peer at 512 by default while this arm was uncapped, so a reasoning
    model that ran long finished its answer for `single` and was truncated
    before the final line for `mesh` -- scoring the cap, not the mesh. Two arms
    under different generation budgets do not compare.
    """
    payload = {"model": model, "messages": [{"role": "user", "content": question}]}
    if max_tokens > 0:
        payload["max_tokens"] = max_tokens
    start = time.perf_counter()
    resp = await client.post(
        f"{litellm}/chat/completions",
        json=payload,
        headers=auth_headers(key),
        timeout=timeout,
    )
    elapsed = time.perf_counter() - start
    resp.raise_for_status()
    body = resp.json()
    usage = body.get("usage") or {}
    return {
        "reply": body["choices"][0]["message"]["content"],
        "latency_s": elapsed,
        "total_tokens": usage.get("total_tokens", 0),
        "straggler_ratio": 1.0,
        "judge_invoked": False,
    }


async def run_mesh(client, coordinator, question, skills, timeout):
    """One answer from the coordinator, with per-peer timing."""
    start = time.perf_counter()
    resp = await client.post(
        f"{coordinator}/v1/reason",
        json={"question": question, "skills": skills},
        timeout=timeout,
    )
    elapsed = time.perf_counter() - start
    resp.raise_for_status()
    body = resp.json()
    peer_latencies = [c["latency_s"] for c in body.get("candidates", [])
                      if c.get("latency_s")]
    return {
        "reply": body["answer"],
        "latency_s": elapsed,
        "total_tokens": body.get("total_tokens", 0),
        "straggler_ratio": straggler_ratio(peer_latencies),
        "judge_invoked": body.get("judge_invoked", False),
        "selection": body.get("selection"),
        # Kept so the caller can score every candidate, not just the winner.
        # The gap between "some candidate was right" and "the selected one was
        # right" is the only number that says whether selection or the peers
        # are the thing to fix.
        "candidates": [{"peer": c.get("peer"), "answer": c.get("answer") or ""}
                       for c in body.get("candidates", [])],
    }


async def run_arm(arm, examples, args) -> list:
    """Run one arm over every example.

    An item the arm cannot answer is recorded as WRONG, never dropped. Dropping
    it would report a flattering number, and crashing the run would report no
    number at all -- but a mesh that fails to answer has, for benchmark
    purposes, got the item wrong. The failure reason is kept on the record so
    the rate is auditable rather than folded into the accuracy figure.
    """
    records = []
    instruction = instruction_for(examples)
    async with httpx.AsyncClient() as client:
        for example in examples:
            question = example["input"] + instruction
            attempt_start = time.perf_counter()
            try:
                if arm == "single":
                    result = await run_single(client, args.litellm, args.single_model,
                                              question, args.timeout, args.litellm_key,
                                              args.max_tokens)
                else:
                    result = await run_mesh(client, args.coordinator, question,
                                            args.skills, args.timeout)
            except (httpx.HTTPStatusError, httpx.TimeoutException,
                    httpx.ConnectError) as exc:
                # Real elapsed time, not the timeout budget. A 502 that comes
                # back in two seconds is a fast failure, and charging it the
                # full timeout would put a number in p95 that nobody waited.
                result = {"reply": "", "latency_s": time.perf_counter() - attempt_start,
                          "total_tokens": 0, "straggler_ratio": 0.0,
                          "judge_invoked": False, "selection": "failed",
                          "error": type(exc).__name__ + ": " + str(exc)[:120]}
            result["correct"] = is_correct(result["reply"], example["target"])
            result["target"] = example["target"]
            # Score every candidate the fan-out produced. `oracle` is the
            # ceiling a perfect selector would reach from the answers already
            # paid for; the per-peer rates say which node earned its slot.
            scored = {c["peer"]: is_correct(c["answer"], example["target"])
                      for c in result.get("candidates", []) if c.get("peer")}
            if scored:
                result["candidate_correct"] = scored
                result["oracle_correct"] = any(scored.values())
            result.pop("candidates", None)
            records.append(result)
            if args.verbose:
                mark = "OK " if result["correct"] else "XX "
                print(f"  {mark} {result['latency_s']:6.2f}s  {example['target']}",
                      flush=True)
    return records


def print_table(single: dict, mesh: dict, price: float):
    rows = [
        ("items", f"{single['n']}", f"{mesh['n']}", ""),
        # Reported next to accuracy on purpose: a failed item counts as wrong,
        # so a high failure rate makes accuracy look like a quality result when
        # it is really an availability one.
        ("failed to answer", f"{single.get('failed', 0)}",
         f"{mesh.get('failed', 0)}", ""),
        ("accuracy", f"{single['accuracy']:.3f}", f"{mesh['accuracy']:.3f}",
         f"{mesh['accuracy'] - single['accuracy']:+.3f}"),
        ("latency p50 (s)", f"{single['latency_p50_s']:.2f}",
         f"{mesh['latency_p50_s']:.2f}",
         f"{delta_pct(mesh['latency_p50_s'], single['latency_p50_s']):+.1f}%"),
        ("latency p95 (s)", f"{single['latency_p95_s']:.2f}",
         f"{mesh['latency_p95_s']:.2f}",
         f"{delta_pct(mesh['latency_p95_s'], single['latency_p95_s']):+.1f}%"),
        ("tokens/item", f"{single['tokens_per_item']:.0f}",
         f"{mesh['tokens_per_item']:.0f}",
         f"{delta_pct(mesh['tokens_per_item'], single['tokens_per_item']):+.1f}%"),
        ("cost (USD)", f"{single['cost_usd']:.4f}", f"{mesh['cost_usd']:.4f}",
         f"{delta_pct(mesh['cost_usd'], single['cost_usd']):+.1f}%"),
        ("straggler ratio", f"{single['mean_straggler_ratio']:.2f}",
         f"{mesh['mean_straggler_ratio']:.2f}", ""),
        ("judge calls", "0", f"{mesh['judge_invocations']}",
         f"{mesh['judge_invocations']}/{mesh['n']} items"),
    ]
    width = max(len(r[0]) for r in rows)
    print(f"\n{'metric'.ljust(width)}  {'single':>10}  {'mesh':>10}  {'delta':>12}")
    print("-" * (width + 38))
    for label, a, b, d in rows:
        print(f"{label.ljust(width)}  {a:>10}  {b:>10}  {d:>12}")
    if price == 0.0:
        print("\nCost is 0 by default: an all-local mesh has no per-token price.")
        print("Pass --price-per-mtok with a cloud baseline price to compare dollars.")
    print("\nTarget for cost reduction is ~32% (LLMRouterBench), not 90%.")

    # Where the mesh gained or lost, not merely that it did. Paths that return
    # the local answer cannot score below `single`; the ones that overrule it
    # can, and those are the only ones worth changing.
    print(f"\nmesh accuracy by selection path (single = {single['accuracy']:.3f})")
    for path, (items, accuracy) in mesh.get("by_selection", {}).items():
        verdict = "" if path in ("consensus", "sole-responder") else \
            ("  <- overruled local" if accuracy < single["accuracy"] else "")
        print(f"  {path:<16} {items:>3} items  {accuracy:.3f}{verdict}")

    # The ceiling, and who reached it. Without these a tie is unreadable: it
    # looks the same whether the peers had nothing to add or whether selection
    # threw away answers already paid for.
    oracle = mesh.get("oracle_accuracy")
    if oracle is not None:
        headroom = oracle - mesh["accuracy"]
        print(f"\noracle (any candidate correct) : {oracle:.3f}")
        print(f"mesh selected                  : {mesh['accuracy']:.3f}"
              f"   ({headroom:+.3f} left on the table by selection)")
        if oracle <= single["accuracy"]:
            print("  -> peers added no answer the local model did not already have;")
            print("     no selector can win here. Change the peers, not the judge.")
        elif headroom > 0.02:
            print("  -> the right answer was bought and then discarded.")
            print("     That is a selection problem and it is worth fixing.")

    by_peer = mesh.get("by_peer") or {}
    if by_peer:
        print("\naccuracy per candidate (declared skills are labels; this is the measurement)")
        for peer, (items, accuracy) in by_peer.items():
            print(f"  {peer:<18} {items:>3} answered  {accuracy:.3f}")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--task", required=True, type=Path)
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("--litellm", default="http://localhost:4000/v1")
    p.add_argument("--coordinator", default="http://localhost:9200")
    p.add_argument("--single-model", default="local")
    p.add_argument("--litellm-key", default=os.environ.get("LITELLM_KEY", ""),
                   help="LiteLLM master key; defaults to $LITELLM_KEY")
    p.add_argument("--max-tokens", type=int, default=512,
                   help="generation cap for the single arm; must equal the "
                        "coordinator's MESH_MAX_TOKENS or the arms are not "
                        "comparable. 0 disables, matching MESH_MAX_TOKENS=0")
    p.add_argument("--skills", nargs="*", default=["reasoning", "logic", "general"])
    p.add_argument("--price-per-mtok", type=float, default=0.0)
    p.add_argument("--timeout", type=float, default=300.0)
    p.add_argument("--arms", nargs="*", default=["single", "mesh"])
    p.add_argument("--json-out", type=Path)
    p.add_argument("--verbose", action="store_true")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    examples = load_task(args.task, args.limit)
    print(f"task={args.task.name} items={len(examples)} arms={args.arms}")

    results = {}
    for arm in args.arms:
        print(f"\n--- {arm} ---", flush=True)
        records = asyncio.run(run_arm(arm, examples, args))
        results[arm] = summarize(records, args.price_per_mtok)

    if "single" in results and "mesh" in results:
        print_table(results["single"], results["mesh"], args.price_per_mtok)

    if args.json_out:
        args.json_out.write_text(json.dumps(results, indent=2))
        print(f"\nwrote {args.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
