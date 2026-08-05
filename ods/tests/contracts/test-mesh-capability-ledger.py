#!/usr/bin/env python3
"""Contract: the capability ledger routes on evidence, not on declarations.

MESH_NODE_SKILLS is a label somebody typed. On a live three-node mesh the node
advertising `logic` was the worst at it, and routing believed the label. The
property under test throughout: measurement outranks declaration, but only once
there is enough of it to outrank noise.
"""

import importlib.util
import json
import sys
import tempfile
from pathlib import Path

ODS_ROOT = Path(__file__).resolve().parents[2]
APP = ODS_ROOT / "extensions" / "services" / "dreamreason" / "app"
sys.path.insert(0, str(APP))

_spec = importlib.util.spec_from_file_location(
    "capability_ledger", APP / "capability_ledger.py")
cl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cl)

FAILURES = []


def check(label, condition):
    if condition:
        print(f"[PASS] {label}")
    else:
        print(f"[FAIL] {label}")
        FAILURES.append(label)


def ledger_with(peer, skill, wins, losses):
    led = cl.empty_ledger()
    for _ in range(wins):
        led = cl.record_outcome(led, peer, skill, True)
    for _ in range(losses):
        led = cl.record_outcome(led, peer, skill, False)
    return led


def test_unmeasured_peer_is_unknown_not_bad():
    # Starting a new peer at zero would mean it never earns the traffic that
    # would let it prove itself.
    led = cl.empty_ledger()
    check("unmeasured scores 0.5", cl.score(led, "peer-x", "logic") == 0.5)
    check("unmeasured is not confident", cl.is_confident(led, "peer-x", "logic") is False)


def test_wins_raise_the_score():
    led = ledger_with("peer-a", "logic", wins=4, losses=1)
    check("win rate is recorded", abs(cl.score(led, "peer-a", "logic") - 0.8) < 1e-9)


def test_losses_lower_the_score():
    led = ledger_with("peer-b", "logic", wins=1, losses=4)
    check("losing peer scores below unmeasured",
          cl.score(led, "peer-b", "logic") < 0.5)


def test_confidence_needs_observations():
    few = ledger_with("peer-a", "logic", wins=2, losses=0)
    many = ledger_with("peer-a", "logic", wins=3, losses=2)
    check("two observations is not confidence",
          cl.is_confident(few, "peer-a", "logic") is False)
    check("five observations is", cl.is_confident(many, "peer-a", "logic") is True)


def test_ranking_demotes_the_measured_loser():
    led = ledger_with("peer-bad", "logic", wins=0, losses=6)
    ranked = cl.rank_peers(led, ["peer-bad", "peer-new"], "logic")
    check(f"a peer that keeps losing stops leading ({ranked})",
          ranked[0] == "peer-new")


def test_ranking_promotes_the_measured_winner():
    led = ledger_with("peer-good", "logic", wins=6, losses=0)
    ranked = cl.rank_peers(led, ["peer-new", "peer-good"], "logic")
    check(f"a peer that keeps winning leads ({ranked})", ranked[0] == "peer-good")


def test_ranking_is_stable_without_evidence():
    # Only ever reorder on evidence: with none, the caller's order stands.
    led = cl.empty_ledger()
    order = ["peer-a", "peer-b", "peer-c"]
    check("no evidence means no reordering",
          cl.rank_peers(led, order, "logic") == order)


def test_skills_are_scored_separately():
    led = ledger_with("peer-a", "logic", wins=5, losses=0)
    check("a win at logic says nothing about code",
          cl.score(led, "peer-a", "code") == 0.5)


def test_record_does_not_mutate_the_input():
    # A failed write must not leave memory ahead of disk.
    led = cl.empty_ledger()
    cl.record_outcome(led, "peer-a", "logic", True)
    check("record_outcome returns a new ledger", led["entries"] == {})


def test_roundtrip_through_disk():
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "ledger.json"
        led = ledger_with("peer-a", "logic", wins=3, losses=1)
        cl.save_ledger(led, path)
        back = cl.load_ledger(path)
        check("survives a save/load roundtrip",
              abs(cl.score(back, "peer-a", "logic") - 0.75) < 1e-9)


def test_missing_file_is_the_normal_first_run():
    with tempfile.TemporaryDirectory() as d:
        check("absent ledger loads empty",
              cl.load_ledger(Path(d) / "none.json")["entries"] == {})


def test_corrupt_ledger_does_not_stop_answering():
    # Refusing to answer because the routing hints are unreadable would be
    # worse than routing without hints.
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "bad.json"
        path.write_text("{not json")
        check("corrupt ledger degrades to empty", cl.load_ledger(path)["entries"] == {})


def test_save_is_atomic():
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "ledger.json"
        cl.save_ledger(ledger_with("peer-a", "logic", 1, 0), path)
        cl.save_ledger(ledger_with("peer-a", "logic", 2, 0), path)
        check("no temp file left behind", not path.with_suffix(".tmp").exists())
        check("final write is readable", json.loads(path.read_text())["entries"])


def main():
    print("=== DreamReason capability ledger contract ===")
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\n[OK] capability ledger contract holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
