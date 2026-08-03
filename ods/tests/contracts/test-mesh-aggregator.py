#!/usr/bin/env python3
"""Contract: DreamReason aggregation.

Three research findings are encoded here as executable rules:

  1. the aggregator SELECTS, it never blends  (arXiv 2603.20324 / 2502.00674)
  2. consensus bypasses the judge entirely    (MOSAIC, arXiv 2606.03014)
  3. fan-out stays small                      (Ringelmann, arXiv 2606.02646)
"""

import importlib.util
import sys
from pathlib import Path

ODS_ROOT = Path(__file__).resolve().parents[2]
APP = ODS_ROOT / "extensions" / "services" / "dreamreason" / "app"
sys.path.insert(0, str(APP))

_spec = importlib.util.spec_from_file_location("aggregator", APP / "aggregator.py")
agg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(agg)

FAILURES = []


def check(label, condition):
    if condition:
        print(f"[PASS] {label}")
    else:
        print(f"[FAIL] {label}")
        FAILURES.append(label)


def candidates():
    return [
        {"peer": "peer-code", "answer": "Use a hash map for O(n) lookup."},
        {"peer": "peer-reasoning", "answer": "Sort the array, then binary search."},
        {"peer": "peer-general", "answer": "Loop over every pair and compare."},
    ]


def test_judge_prompt_forbids_blending():
    prompt = agg.build_judge_prompt("How do I find duplicates?", candidates())
    lowered = prompt.lower()
    check("judge told to choose", "choose one of the answers" in lowered)
    check("judge told not to merge", "do not merge" in lowered)
    check("judge told not to write a new answer", "do not write a new answer" in lowered)
    check("judge told not to edit the winner", "do not edit" in lowered)
    check("every candidate is offered", all(c["answer"] in prompt for c in candidates()))


def test_verdict_selects_an_existing_answer():
    index, reason = agg.parse_judge_verdict("CHOICE: 1\nREASON: it is O(n log n).", 3)
    check("selected index parsed", index == 1)
    check("justification captured", "O(n log n)" in reason)


def test_malformed_verdict_raises():
    for reply, label in [
        ("I think the second one is nice.", "no CHOICE line raises"),
        ("CHOICE: 7\nREASON: x", "out-of-range choice raises"),
        ("", "empty reply raises"),
    ]:
        try:
            agg.parse_judge_verdict(reply, 3)
            check(label, False)
        except ValueError:
            check(label, True)


def test_consensus_bypasses_the_judge():
    same = ["The answer is 42.", "The answer is 42.", "The answer is 42."]
    check("identical answers reach consensus", agg.has_consensus(same) is True)
    check("agreement is 1.0 when identical", agg.pairwise_agreement(same) == 1.0)


def test_disagreement_does_not_bypass():
    differing = [c["answer"] for c in candidates()]
    check("differing answers have no consensus", agg.has_consensus(differing) is False)
    check("agreement below threshold", agg.pairwise_agreement(differing) < 0.85)


def test_single_answer_is_not_consensus():
    # One peer agreeing with itself is not agreement between peers.
    check("one answer is not consensus", agg.has_consensus(["only one"]) is False)
    check("zero answers are not unanimous", agg.pairwise_agreement([]) == 0.0)


def test_near_identical_answers_still_agree():
    near = ["The capital is Paris.", "The capital is Paris!"]
    check("trivial punctuation difference still agrees", agg.has_consensus(near) is True)


def test_fanout_is_capped():
    import coordinator  # noqa: E402  (needs sys.path above)
    check("default fan-out is 3", coordinator.effective_fanout(None) == 3)
    check("request for 10 peers is capped", coordinator.effective_fanout(10) <= 5)
    check("cap is never all peers", coordinator.effective_fanout(1000) == 5)
    check("fan-out of 0 is raised to 1", coordinator.effective_fanout(0) == 1)


def test_fanout_never_queries_one_peer_twice():
    import coordinator  # noqa: E402
    models = coordinator.peer_models(["code", "reasoning", "general"],
                                     "Write a Python function to sort a list", 3)
    check(f"no duplicate peers in fan-out ({models})", len(models) == len(set(models)))
    check("best skill leads", models[0] == "peer-code")
    check("fan-out honours the cap", len(models) == 3)

    narrow = coordinator.peer_models(["code"], "Write a Python function", 3)
    check("one skill yields one peer, not padding", narrow == ["peer-code"])


def test_fixed_decomposition_is_three_way():
    parts = agg.decompose_fixed("What is 2+2?")
    check("decomposition yields 3 parts", len(parts) == 3)
    check("each part keeps the question", all("2+2" in p for p in parts))
    check("parts are distinct framings", len(set(parts)) == 3)


def main():
    print("=== DreamReason aggregator contract ===")
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\n[OK] aggregator contract holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
