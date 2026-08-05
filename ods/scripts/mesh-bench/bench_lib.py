"""Pure helpers for the DreamReason BBH benchmark.

Separated from the runner so scoring and metrics are testable without a GPU,
a network, or a running stack.
"""

import re
import statistics

# BBH targets are mostly "(A)"-style multiple choice, with some free text
# ("valid"/"invalid", "True"/"False", a word, or a number).
_CHOICE = re.compile(r"\(([A-Za-z])\)")


def extract_answer(text: str, target: str) -> str:
    """Best-effort answer extraction from a model reply. Pure.

    Multiple-choice targets are matched on the LAST choice marker in the reply:
    a model that reasons aloud usually restates its final pick at the end, and
    taking the first marker would score the reasoning rather than the answer.
    """
    if text is None:
        return ""
    text = text.strip()
    if _CHOICE.fullmatch(target.strip()):
        found = _CHOICE.findall(text)
        return f"({found[-1].upper()})" if found else ""
    return text.split("\n")[-1].strip()


def is_correct(reply: str, target: str) -> bool:
    """Exact match after normalisation. Pure."""
    extracted = extract_answer(reply, target).strip().lower()
    return extracted == target.strip().lower()


def percentile(values: list, pct: float) -> float:
    """Nearest-rank percentile. Pure. Returns 0.0 for an empty sample."""
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round(pct / 100.0 * len(ordered) + 0.5)) - 1)
    return ordered[max(0, index)]


def straggler_ratio(latencies: list) -> float:
    """Slowest peer over the median peer, within one fan-out. Pure.

    MOSAIC (arXiv 2606.03014) documents this failure mode: mixing
    instruction-tuned with long-reasoning models produces extreme
    generation-length variance, so the whole fan-out waits on one peer. A ratio
    near 1.0 means balanced peers; large values mean the cap on fan-out is
    doing less good than the straggler is doing harm.
    """
    if len(latencies) < 2:
        return 1.0
    median = statistics.median(latencies)
    if median <= 0:
        return 1.0
    return max(latencies) / median


def summarize(records: list, price_per_mtok: float = 0.0) -> dict:
    """Aggregate per-item records into one arm's result row. Pure."""
    if not records:
        return {"n": 0}
    latencies = [r["latency_s"] for r in records]
    tokens = sum(r["total_tokens"] for r in records)
    correct = sum(1 for r in records if r["correct"])
    stragglers = [r["straggler_ratio"] for r in records if r.get("straggler_ratio")]
    return {
        "n": len(records),
        # Counted, not excluded. A failed item is scored wrong, so accuracy
        # already carries the penalty; this says how much of the gap is
        # availability rather than reasoning.
        "failed": sum(1 for r in records if r.get("error")),
        "accuracy": correct / len(records),
        "latency_p50_s": percentile(latencies, 50),
        "latency_p95_s": percentile(latencies, 95),
        "latency_mean_s": statistics.fmean(latencies),
        "total_tokens": tokens,
        "tokens_per_item": tokens / len(records),
        "cost_usd": tokens / 1_000_000 * price_per_mtok,
        "mean_straggler_ratio": statistics.fmean(stragglers) if stragglers else 1.0,
        "judge_invocations": sum(1 for r in records if r.get("judge_invoked")),
        "by_selection": accuracy_by_selection(records),
        "oracle_accuracy": oracle_accuracy(records),
        "by_peer": accuracy_by_peer(records),
    }


def oracle_accuracy(records: list):
    """Share of items where SOME candidate was right, or None. Pure.

    The ceiling selection could reach without buying another token, so it
    splits one question into two answerable ones. Oracle at the single arm's
    accuracy means the peers contributed no answer the local model lacked, and
    no selector can help. Oracle above it means the right answer was bought and
    then discarded, which is a selection problem and worth fixing.
    """
    scored = [r for r in records if "oracle_correct" in r]
    if not scored:
        return None
    return sum(1 for r in scored if r["oracle_correct"]) / len(scored)


def accuracy_by_peer(records: list) -> dict:
    """{peer: (items, accuracy)} over every candidate answer. Pure.

    Declared skills are labels; this is the measurement. It answers the
    question the whole fan-out rests on -- whether any peer actually beats the
    node that was already answering -- and it is the same quantity the
    capability ledger accumulates from live traffic.
    """
    peers = {}
    for record in records:
        for peer, correct in (record.get("candidate_correct") or {}).items():
            items, hits = peers.get(peer, (0, 0))
            peers[peer] = (items + 1, hits + (1 if correct else 0))
    return {k: (n, c / n) for k, (n, c) in sorted(peers.items())}


def accuracy_by_selection(records: list) -> dict:
    """{selection path: (items, accuracy)} for one arm. Pure.

    An aggregate accuracy says the mesh lost but not where, and the paths fail
    for opposite reasons: consensus and majority-with-local return the local
    answer and cannot score below the single arm, while a majority that
    overrules local, or a judge, can. Without this split a run says "worse" and
    leaves the cause to guesswork -- which is how the first three fixes were
    found by reading code rather than by measuring.
    """
    paths = {}
    for record in records:
        key = record.get("selection") or "single"
        items, correct = paths.get(key, (0, 0))
        paths[key] = (items + 1, correct + (1 if record["correct"] else 0))
    return {k: (n, c / n) for k, (n, c) in sorted(paths.items())}


def delta_pct(mesh_value: float, single_value: float) -> float:
    """Percent change of mesh relative to single. Pure. Negative = reduction."""
    if single_value == 0:
        return 0.0
    return (mesh_value - single_value) / single_value * 100.0
