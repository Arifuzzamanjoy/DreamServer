#!/usr/bin/env python3
"""Compare the keyword and semantic skill routers on a labelled set.

The keyword router needs nothing and always runs. The semantic arm needs TEI
and Qdrant, and is skipped with a clear message when they are absent rather
than silently reporting a number it did not measure.

If the semantic router does not beat the keyword baseline by enough to pay for
a TEI round trip and a Qdrant query on every request, keeping the regexes is
the correct outcome. That is a real finding, not a failure.

    python3 compare-routers.py --eval routing-eval.json
    python3 compare-routers.py --eval routing-eval.json --arms keyword semantic
"""

import argparse
import asyncio
import json
import sys
import time
from collections import Counter
from pathlib import Path

APP = (Path(__file__).resolve().parents[2]
       / "extensions" / "services" / "dreamreason" / "app")
sys.path.insert(0, str(APP))

from skill_router import select_skill  # noqa: E402


def load_items(path: Path) -> list:
    data = json.loads(path.read_text())
    return data["items"] if isinstance(data, dict) else data


def run_keyword(items: list) -> dict:
    start = time.perf_counter()
    predictions = [select_skill(item["prompt"]) for item in items]
    elapsed = time.perf_counter() - start
    return score(items, predictions, elapsed)


async def run_semantic(items: list) -> dict:
    import httpx
    from semantic_router import (
        CapabilityIndexUnavailable, EmbeddingUnavailable, select_skill_semantic,
    )

    start = time.perf_counter()
    predictions = []
    async with httpx.AsyncClient() as client:
        for item in items:
            predictions.append(await select_skill_semantic(client, item["prompt"]))
    elapsed = time.perf_counter() - start
    return score(items, predictions, elapsed)


def score(items: list, predictions: list, elapsed: float) -> dict:
    correct = sum(1 for item, pred in zip(items, predictions)
                  if pred == item["skill"])
    confusion = Counter(
        (item["skill"], pred) for item, pred in zip(items, predictions)
        if pred != item["skill"]
    )
    return {
        "n": len(items),
        "correct": correct,
        "accuracy": correct / len(items) if items else 0.0,
        "elapsed_s": elapsed,
        "ms_per_route": elapsed / len(items) * 1000 if items else 0.0,
        "confusions": confusion.most_common(8),
    }


def report(name: str, result: dict):
    print(f"\n--- {name} ---")
    print(f"  accuracy      : {result['accuracy']:.3f} "
          f"({result['correct']}/{result['n']})")
    print(f"  routing cost  : {result['ms_per_route']:.3f} ms/route")
    if result["confusions"]:
        print("  confusions (expected -> predicted):")
        for (want, got), count in result["confusions"]:
            print(f"      {want:11s} -> {got:11s}  x{count}")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--eval", type=Path,
                   default=Path(__file__).parent / "routing-eval.json")
    p.add_argument("--arms", nargs="*", default=["keyword", "semantic"])
    p.add_argument("--json-out", type=Path)
    args = p.parse_args()

    items = load_items(args.eval)
    print(f"routing eval: {len(items)} labelled prompts")

    results = {}
    if "keyword" in args.arms:
        results["keyword"] = run_keyword(items)
        report("keyword (baseline)", results["keyword"])

    if "semantic" in args.arms:
        try:
            results["semantic"] = asyncio.run(run_semantic(items))
            report("semantic (TEI + Qdrant)", results["semantic"])
        except (ImportError, OSError) as exc:
            print(f"\n--- semantic ---\n  SKIPPED: {exc}")
        else:
            k, s = results["keyword"]["accuracy"], results["semantic"]["accuracy"]
            delta = s - k
            print(f"\nsemantic - keyword = {delta:+.3f}")
            if delta <= 0:
                print("Keyword router wins. Keep MESH_ROUTER=keyword: the "
                      "embedding path costs a TEI round trip and a Qdrant "
                      "query per request and buys nothing here.")

    if args.json_out:
        args.json_out.write_text(json.dumps(results, indent=2, default=str))
        print(f"\nwrote {args.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
