#!/usr/bin/env python3
"""Contract: semantic routing stays behind a flag and degrades loudly."""

import importlib.util
import os
import sys
from pathlib import Path

ODS_ROOT = Path(__file__).resolve().parents[2]
APP = ODS_ROOT / "extensions" / "services" / "dreamreason" / "app"
sys.path.insert(0, str(APP))

_spec = importlib.util.spec_from_file_location("semantic_router",
                                               APP / "semantic_router.py")
sem = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sem)

FAILURES = []


def check(label, condition):
    if condition:
        print(f"[PASS] {label}")
    else:
        print(f"[FAIL] {label}")
        FAILURES.append(label)


def test_keyword_is_the_default():
    # Semantic routing must be opt-in until it beats the baseline.
    import coordinator
    check("MESH_ROUTER defaults to keyword", coordinator.MESH_ROUTER == "keyword")
    check("no MESH_ROUTER in env for this run", os.environ.get("MESH_ROUTER") is None)


def test_low_similarity_does_not_route():
    # A weak nearest neighbour is worse than admitting we do not know.
    check("below threshold falls back to general",
          sem.apply_availability("algebra", 0.10, []) == sem.GENERAL_SKILL)
    check("above threshold routes",
          sem.apply_availability("algebra", 0.99, []) == "algebra")


def test_respects_what_peers_serve():
    check("unavailable skill degrades to general",
          sem.apply_availability("algebra", 0.99, ["code"]) == sem.GENERAL_SKILL)
    check("available skill is kept",
          sem.apply_availability("code", 0.99, ["code"]) == "code")


def test_both_routers_share_a_vocabulary():
    # Otherwise a comparison measures vocabulary, not routing quality.
    from skill_router import SKILL_RULES
    overlap = set(sem.CAPABILITY_EXEMPLARS) & set(SKILL_RULES)
    check(f"routers share skills ({len(overlap)})", len(overlap) >= 7)
    check("known_skills unions both", set(sem.known_skills()) >=
          set(SKILL_RULES) | set(sem.CAPABILITY_EXEMPLARS))


def test_exemplars_are_well_formed():
    points = sem.exemplar_points()
    check("every exemplar has a skill and text",
          all(p["skill"] and p["text"] for p in points))
    check("ids are unique", len({p["id"] for p in points}) == len(points))
    check("ids are stable across calls",
          [p["id"] for p in sem.exemplar_points()] == [p["id"] for p in points])


def test_failures_are_distinct_types():
    # TEI missing and Qdrant missing are different deployment problems.
    check("embedding failure has its own type",
          issubclass(sem.EmbeddingUnavailable, RuntimeError))
    check("index failure has its own type",
          issubclass(sem.CapabilityIndexUnavailable, RuntimeError))
    check("they are not the same exception",
          sem.EmbeddingUnavailable is not sem.CapabilityIndexUnavailable)


def main():
    print("=== DreamReason semantic router contract ===")
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\n[OK] semantic router contract holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
