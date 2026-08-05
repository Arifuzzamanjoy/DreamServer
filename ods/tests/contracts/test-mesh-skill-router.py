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


ALL_SKILLS = ["algebra", "code", "general", "geometry", "logic", "reasoning",
              "writing"]


def test_confident_prompt_narrows_the_pool():
    # RouteMoA's premise: screen from the query and stop paying for peers the
    # scorer already predicts are a poor fit.
    picked = sr.select_candidates(CODE_Q, ALL_SKILLS, 3)
    check("confident prompt spends less than the budget", len(picked) < 3)
    check("confident prompt keeps its own skill", "code" in picked)
    check("confident prompt drops unrelated skills",
          "writing" not in picked and "geometry" not in picked)


def test_ambiguous_prompt_still_spends_the_budget():
    # Breadth is the hedge exactly when the scorer has no opinion; narrowing
    # here would remove the second opinion fan-out exists to buy.
    picked = sr.select_candidates("What do you think?", ALL_SKILLS, 3)
    check("ambiguous prompt fills the budget", len(picked) == 3)


def test_never_exceeds_the_budget():
    for prompt in (CODE_Q, ALGEBRA_Q, GEOMETRY_Q, WRITING_Q, LOGIC_Q, "hello"):
        check(f"budget respected for {prompt[:20]!r}",
              len(sr.select_candidates(prompt, ALL_SKILLS, 2)) <= 2)


def test_only_offered_skills_are_returned():
    picked = sr.select_candidates(CODE_Q, ["writing", "general"], 3)
    check("never returns a skill no peer serves",
          all(skill in ("writing", "general") for skill in picked))


def test_screening_is_deterministic():
    check("same prompt screens the same way",
          sr.select_candidates(ALGEBRA_Q, ALL_SKILLS, 3)
          == sr.select_candidates(ALGEBRA_Q, ALL_SKILLS, 3))


def test_empty_pool_returns_nothing():
    check("no peers means no candidates", sr.select_candidates(CODE_Q, [], 3) == [])
    check("zero budget means no candidates",
          sr.select_candidates(CODE_Q, ALL_SKILLS, 0) == [])


def test_best_skill_survives_screening():
    # The screened set must still contain what select_skill would have picked,
    # or narrowing would silently overrule the router.
    for prompt in (CODE_Q, ALGEBRA_Q, GEOMETRY_Q, WRITING_Q, LOGIC_Q):
        best = sr.select_skill(prompt, ALL_SKILLS)
        check(f"top pick kept for {prompt[:20]!r}",
              best in sr.select_candidates(prompt, ALL_SKILLS, 3))


def test_prose_about_a_topic_is_not_a_writing_task():
    """Regression, measured on a live three-node mesh.

    BBH's logical-deduction preamble opens "The following paragraphs each
    describe a set of three objects". `paragraph` was a weight-2 rule -- the
    table's own definition of "strongly diagnostic on its own" -- so every item
    on the benchmark scored 2 for `writing`. That met CONFIDENT_SCORE, so
    select_candidates narrowed the pool to `['writing']`: a logic puzzle was
    confidently routed to the writing node, the logic node was never asked, and
    the mesh lost the benchmark being used to evaluate it.

    The property: a noun naming a body of text is not a writing task. Only a
    verb acting on one is.
    """
    bbh = ("The following paragraphs each describe a set of three objects "
           "arranged in a fixed order. The statements are logically consistent "
           "within each paragraph. In a golf tournament there were three "
           "golfers. Eve finished above Amy. Eli finished below Amy.")
    scored = dict(sr.rank_skills(bbh))
    check(f"a logic puzzle does not score as writing ({scored})",
          scored.get("writing", 0) < sr.CONFIDENT_SCORE)

    # The live mesh's peer set, which is what made the misroute reachable.
    served = ["reasoning", "logic", "general", "writing"]
    picked = sr.select_candidates(bbh, served, 3)
    check(f"the pool is not narrowed to the writing node ({picked})",
          picked != ["writing"] and picked[0] != "writing")
    check(f"an unrouted prompt still spends its budget on breadth ({picked})",
          len(picked) == 3)
    check(f"the logic peer is reachable again ({picked})", "logic" in picked)

    # The other half of the property: acting on a paragraph still routes to
    # writing, so the fix narrows the rule rather than deleting the signal.
    for prompt in ("Rewrite this paragraph in a warmer tone",
                   "Summarise this article in three sentences",
                   "Shorten the second paragraph"):
        check(f"{prompt[:34]!r} still routes to writing",
              sr.select_skill(prompt, ALL_SKILLS) == "writing")


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
