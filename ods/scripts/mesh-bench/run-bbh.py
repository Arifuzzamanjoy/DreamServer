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
import sys
import time
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bench_lib import delta_pct, is_correct, straggler_ratio, summarize  # noqa: E402

INSTRUCTION = (
    "\n\nAnswer with the option letter in parentheses, e.g. (A). "
    "Give the answer on the last line."
)


def load_task(path: Path, limit: int) -> list:
    """Load a BBH task file. Standard shape: {'examples': [{input, target}]}."""
    data = json.loads(path.read_text())
    examples = data["examples"] if isinstance(data, dict) else data
    return examples[:limit] if limit else examples


async def run_single(client, litellm, model, question, timeout):
    """One completion straight from one model."""
    start = time.perf_counter()
    resp = await client.post(
        f"{litellm}/chat/completions",
        json={"model": model, "messages": [{"role": "user", "content": question}]},
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
    }


async def run_arm(arm, examples, args) -> list:
    """Run one arm over every example. Failures crash -- a benchmark that
    quietly drops hard items reports a flattering number."""
    records = []
    async with httpx.AsyncClient() as client:
        for example in examples:
            question = example["input"] + INSTRUCTION
            if arm == "single":
                result = await run_single(client, args.litellm, args.single_model,
                                          question, args.timeout)
            else:
                result = await run_mesh(client, args.coordinator, question,
                                        args.skills, args.timeout)
            result["correct"] = is_correct(result["reply"], example["target"])
            result["target"] = example["target"]
            records.append(result)
            if args.verbose:
                mark = "OK " if result["correct"] else "XX "
                print(f"  {mark} {result['latency_s']:6.2f}s  {example['target']}",
                      flush=True)
    return records


def print_table(single: dict, mesh: dict, price: float):
    rows = [
        ("items", f"{single['n']}", f"{mesh['n']}", ""),
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


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--task", required=True, type=Path)
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("--litellm", default="http://localhost:4000/v1")
    p.add_argument("--coordinator", default="http://localhost:9200")
    p.add_argument("--single-model", default="local")
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
