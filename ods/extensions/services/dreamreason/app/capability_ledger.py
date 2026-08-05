"""Measured per-peer, per-skill performance — the capability ledger.

`MESH_NODE_SKILLS=writing,logic` is a label somebody typed. Nothing checks it,
and on a live three-node mesh the node advertising `logic` was the worst at
logic — routing sent work to a peer that merely claimed competence, and the
mesh scored 24/30 against a single node's 30/30.

Symphony (arXiv 2508.20019) records capabilities in a ledger and selects on it
rather than on declarations. This is that idea at the smallest size that is
still honest: every selection outcome is one observation, and a peer's score
for a skill is the share of contests it won.

Deliberately not a rating system. Elo and its relatives need far more games
than a small mesh will ever play, and would put a precise-looking number on
five observations. A win rate with the count beside it cannot pretend to more
confidence than it has, and `is_confident` is what stops the router acting on
noise.

Pure functions over an explicit state dict, plus one impure load/save pair at
the edge. The state is small and rewritten whole; a mesh has a handful of
peers and skills, not a table worth indexing.
"""

import json
import logging
import os
from pathlib import Path

logger = logging.getLogger("dreamreason")

LEDGER_PATH = Path(os.environ.get("MESH_LEDGER_PATH", "/data/mesh-capability.json"))
# Below this many observations a win rate is noise. Five is not a statistical
# claim, it is a floor low enough to be reachable on a small mesh and high
# enough that one lucky answer cannot promote a peer.
MIN_OBSERVATIONS = int(os.environ.get("MESH_LEDGER_MIN_OBSERVATIONS", "5"))


def empty_ledger() -> dict:
    """A ledger with nothing recorded. Pure."""
    return {"version": 1, "entries": {}}


def _key(peer: str, skill: str) -> str:
    return f"{peer}::{skill}"


def record_outcome(ledger: dict, peer: str, skill: str, won: bool) -> dict:
    """Ledger with one more observation for (*peer*, *skill*). Pure.

    Returns a new dict rather than mutating, so a failed write cannot leave
    the in-memory ledger ahead of the one on disk.
    """
    entries = dict(ledger.get("entries", {}))
    key = _key(peer, skill)
    entry = dict(entries.get(key, {"wins": 0, "total": 0}))
    entry["total"] += 1
    if won:
        entry["wins"] += 1
    entries[key] = entry
    return {"version": ledger.get("version", 1), "entries": entries}


def score(ledger: dict, peer: str, skill: str) -> float:
    """Share of contests *peer* won for *skill*, or 0.5 when unmeasured. Pure.

    0.5 rather than 0 for the unmeasured case: a peer nobody has observed is
    unknown, not bad, and starting it at zero would mean a new node never gets
    the traffic that would let it prove itself.
    """
    entry = ledger.get("entries", {}).get(_key(peer, skill))
    if not entry or not entry["total"]:
        return 0.5
    return entry["wins"] / entry["total"]


def is_confident(ledger: dict, peer: str, skill: str) -> bool:
    """Whether (*peer*, *skill*) has enough observations to act on. Pure."""
    entry = ledger.get("entries", {}).get(_key(peer, skill))
    return bool(entry) and entry["total"] >= MIN_OBSERVATIONS


def rank_peers(ledger: dict, peers: list, skill: str) -> list:
    """*peers* ordered best-measured first for *skill*. Pure and stable.

    Unmeasured peers sit at 0.5, so they outrank peers measured as bad and
    fall behind peers measured as good. That is the exploration the mesh needs:
    a peer that has lost repeatedly stops being asked, and a peer nobody has
    tried still gets a turn.

    Ties keep the caller's order, so this only ever reorders on evidence.
    """
    return sorted(peers, key=lambda p: -score(ledger, p, skill))


def load_ledger(path: Path = LEDGER_PATH) -> dict:
    """Read the ledger, or an empty one when there is nothing yet.

    A missing file is the normal first-run state. A corrupt file is not
    silently discarded -- it is logged and treated as empty, because refusing
    to answer because the routing hints are unreadable would be worse than
    routing without hints.
    """
    if not path.is_file():
        return empty_ledger()
    try:
        payload = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        logger.warning("capability ledger at %s unreadable (%s); starting empty",
                       path, exc)
        return empty_ledger()
    if not isinstance(payload, dict) or "entries" not in payload:
        logger.warning("capability ledger at %s has no entries; starting empty", path)
        return empty_ledger()
    return payload


def save_ledger(ledger: dict, path: Path = LEDGER_PATH) -> None:
    """Write the ledger. Atomic, so a crash mid-write cannot corrupt it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(ledger, indent=2, sort_keys=True))
    tmp.replace(path)
