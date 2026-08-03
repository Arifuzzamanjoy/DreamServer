#!/usr/bin/env python3
"""Contract: DreamReason skill routing.

The property that matters: routing happens at SKILL granularity, not task
granularity. `algebra` and `geometry` must be able to land on different peers
even though both are "math" (Symbolic-MoE, arXiv 2503.05641).
"""

import importlib.util
import sys
from pathlib import Path

ODS_ROOT = Path(__file__).resolve().parents[2]
MODULE = (ODS_ROOT / "extensions" / "services" / "dreamreason" / "app"
          / "skill_router.py")

_spec = importlib.util.spec_from_file_location("skill_router", MODULE)
sr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sr)

FAILURES = []


def check(label, condition):
    if condition:
        print(f"[PASS] {label}")
    else:
        print(f"[FAIL] {label}")
        FAILURES.append(label)


CODE_Q = "Write a Python function to reverse a linked list and debug the traceback"
ALGEBRA_Q = "Solve for x in the quadratic equation 2x^2 + 3x - 5 = 0"
GEOMETRY_Q = "Find the area of a triangle with hypotenuse 13 and perimeter 30"
WRITING_Q = "Rewrite this paragraph in a warmer tone for a blog post"
LOGIC_Q = "In this knights and knaves puzzle, deduce who is lying"


def test_code_and_algebra_land_on_different_peers():
    # The acceptance criterion for this step.
    code = sr.route(CODE_Q)
    algebra = sr.route(ALGEBRA_Q)
    check(f"code question -> {code}", code == "peer-code")
    check(f"algebra question -> {algebra}", algebra == "peer-algebra")
    check("code and algebra route to different peers", code != algebra)


def test_skill_granularity_beats_task_granularity():
    # Both are "math". A task-level router would collapse them.
    algebra = sr.select_skill(ALGEBRA_Q)
    geometry = sr.select_skill(GEOMETRY_Q)
    check(f"algebra vs geometry separate ({algebra} vs {geometry})",
          algebra == "algebra" and geometry == "geometry")


def test_other_skills_classify():
    check("writing question routes to writing", sr.select_skill(WRITING_Q) == "writing")
    check("logic question routes to logic", sr.select_skill(LOGIC_Q) == "logic")


def test_unmatched_prompt_falls_back():
    check("unmatched prompt -> general",
          sr.select_skill("hello there") == sr.GENERAL_SKILL)


def test_routing_is_deterministic():
    first = [sr.rank_skills(CODE_Q) for _ in range(5)]
    check("same prompt ranks identically every time",
          all(r == first[0] for r in first))


def test_respects_available_skills():
    # algebra scores highest, but no peer serves it.
    chosen = sr.select_skill(ALGEBRA_Q, available=["code", "general"])
    check("unavailable best skill is not selected", chosen != "algebra")
    check("falls back to an offered skill", chosen in ("code", "general"))


def test_available_empty_does_not_invent_a_peer():
    check("no peers -> general", sr.select_skill(CODE_Q, available=[]) == sr.GENERAL_SKILL)


def test_model_name_is_the_litellm_routing_key():
    # Must match the model_name mesh.yaml emits, or dispatch silently misses.
    check("model name matches mesh.yaml convention",
          sr.model_for_skill("algebra") == "peer-algebra")


def main():
    print("=== DreamReason skill router contract ===")
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\n[OK] skill router contract holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
