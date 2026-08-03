#!/usr/bin/env python3
"""Contract: benchmark scoring and metrics.

A benchmark that scores itself wrongly is worse than no benchmark, so the pure
scoring path is tested independently of any running stack.
"""

import importlib.util
import sys
from pathlib import Path

ODS_ROOT = Path(__file__).resolve().parents[2]
LIB = ODS_ROOT / "scripts" / "mesh-bench" / "bench_lib.py"
_spec = importlib.util.spec_from_file_location("bench_lib", LIB)
bl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bl)

FAILURES = []


def check(label, condition):
    if condition:
        print(f"[PASS] {label}")
    else:
        print(f"[FAIL] {label}")
        FAILURES.append(label)


def test_multiple_choice_scoring():
    check("plain choice scores", bl.is_correct("(B)", "(B)"))
    check("wrong choice fails", not bl.is_correct("(A)", "(B)"))
    check("case insensitive", bl.is_correct("(b)", "(B)"))


def test_takes_the_last_choice_not_the_first():
    # A model reasoning aloud mentions options before committing. Taking the
    # first marker would score the reasoning instead of the answer.
    reply = "Option (A) looks plausible, but (C) contradicts it.\nAnswer: (C)"
    check("last choice marker wins", bl.is_correct(reply, "(C)"))
    check("first mention does not win", not bl.is_correct(reply, "(A)"))


def test_free_form_scoring():
    check("free-form last line matches", bl.is_correct("thinking\nvalid", "valid"))
    check("free-form mismatch fails", not bl.is_correct("thinking\ninvalid", "valid"))


def test_empty_reply_is_wrong_not_an_error():
    check("empty reply scores wrong", not bl.is_correct("", "(A)"))
    check("None reply scores wrong", not bl.is_correct(None, "(A)"))


def test_straggler_ratio():
    check("balanced peers ratio 1.0", bl.straggler_ratio([1.0, 1.0, 1.0]) == 1.0)
    check("one slow peer shows up", bl.straggler_ratio([1.0, 1.0, 3.0]) == 3.0)
    check("single peer has no straggler", bl.straggler_ratio([2.0]) == 1.0)
    check("empty is 1.0", bl.straggler_ratio([]) == 1.0)


def test_summary_is_honest_about_empty_runs():
    check("no records reports n=0", bl.summarize([])["n"] == 0)


def test_summary_metrics():
    records = [
        {"latency_s": 1.0, "total_tokens": 100, "correct": True,
         "straggler_ratio": 1.0, "judge_invoked": True},
        {"latency_s": 3.0, "total_tokens": 200, "correct": False,
         "straggler_ratio": 2.0, "judge_invoked": False},
    ]
    s = bl.summarize(records, price_per_mtok=10.0)
    check("accuracy averaged", s["accuracy"] == 0.5)
    check("tokens summed", s["total_tokens"] == 300)
    check("cost derived from tokens", abs(s["cost_usd"] - 0.003) < 1e-9)
    check("judge invocations counted", s["judge_invocations"] == 1)


def test_delta_is_signed_correctly():
    check("increase is positive", bl.delta_pct(200, 100) == 100.0)
    check("reduction is negative", bl.delta_pct(50, 100) == -50.0)
    check("zero baseline does not divide by zero", bl.delta_pct(5, 0) == 0.0)


def main():
    print("=== DreamReason benchmark contract ===")
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\n[OK] benchmark contract holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
