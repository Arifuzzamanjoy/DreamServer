"""Aggregation for DreamReason: judge-and-select, never blend.

The aggregation strategy -- not the peers -- decides whether a heterogeneous
mesh helps or hurts.

Self-MoA (Princeton, ICML 2025, arXiv 2502.00674) found that mixing different
LLMs *reduces* average quality, because weak models drag the pool down;
repeatedly sampling one good model beat mixed ensembles by 6.6% on AlpacaEval
2.0. Taken alone that is an argument against DreamReason, whose mesh is
heterogeneous by construction.

"When Agents Disagree" (arXiv 2603.20324) resolves it: the aggregation
strategy is the deciding variable. Across 42 tasks, diverse teams under
judge-based *selection* win 0.810 against a single model, while homogeneous
teams under selection sit at 0.512 -- near chance. Synthesis is what makes
heterogeneity lose.

So this module SELECTS one peer's answer and explains why. It never merges
text from several answers. Blending is the failure mode, not the goal.

MOSAIC (arXiv 2606.03014) supplies the second rule: when peers already agree,
the judge adds latency and no accuracy, so consensus bypasses it entirely --
up to 4.23x faster at the aggregator stage for equal accuracy.

Pure module: no I/O.
"""

import re
from difflib import SequenceMatcher

# Default from MOSAIC's consensus regime. Tuned by MESH_CONSENSUS_THRESHOLD.
DEFAULT_CONSENSUS_THRESHOLD = 0.85

_WHITESPACE = re.compile(r"\s+")
_JUDGE_CHOICE = re.compile(r"CHOICE:\s*(\d+)", re.IGNORECASE)
_CHOICE_MARKER = re.compile(r"\(([A-Za-z])\)")
_SHORT_FORM_ANSWERS = frozenset({
    "yes", "no", "true", "false", "valid", "invalid",
})
_JUDGE_REASON = re.compile(r"REASON:\s*(.+)", re.IGNORECASE | re.DOTALL)


def normalize(text: str) -> str:
    """Lowercase, collapse whitespace. Pure."""
    return _WHITESPACE.sub(" ", (text or "").strip().lower())


def pairwise_agreement(answers: list) -> float:
    """Mean pairwise similarity of *answers*, in [0, 1]. Pure.

    One answer trivially agrees with itself; zero answers have no agreement to
    measure and must not be reported as unanimous.
    """
    if not answers:
        return 0.0
    if len(answers) == 1:
        return 1.0
    normalized = [normalize(a) for a in answers]
    scores = []
    for i in range(len(normalized)):
        for j in range(i + 1, len(normalized)):
            scores.append(SequenceMatcher(None, normalized[i], normalized[j]).ratio())
    return sum(scores) / len(scores)


def consensus_key(text: str) -> str:
    """The operative answer inside *text*, or "" if it is free-form. Pure.

    Structured answers -- multiple choice, yes/no, true/false -- are compared on
    the answer itself rather than the prose around it.
    """
    if not text:
        return ""
    markers = _CHOICE_MARKER.findall(text)
    if markers:
        return markers[-1].upper()
    last_line = normalize(text).split("\n")[-1].strip(" .!")
    tokens = last_line.replace(",", " ").split()
    if tokens and tokens[-1] in _SHORT_FORM_ANSWERS:
        return tokens[-1]
    return ""


def has_consensus(answers: list, threshold: float = DEFAULT_CONSENSUS_THRESHOLD) -> bool:
    """Whether peers agree closely enough to skip the judge. Pure.

    Surface similarity alone is not safe here. Peers that reason aloud share
    almost all of their text and differ only in the final token, so three
    answers of (A), (B) and (C) score ~0.96 similar and would bypass the judge
    while completely disagreeing -- silently disabling selection on exactly the
    multiple-choice benchmarks used to evaluate it. Measured, not hypothetical.

    So when the answers are structured, consensus means the extracted answers
    are identical. Similarity is only consulted for genuinely free-form text.
    """
    if len(answers) < 2:
        return False
    keys = [consensus_key(a) for a in answers]
    if all(keys):
        return len(set(keys)) == 1
    return pairwise_agreement(answers) >= threshold


def build_judge_prompt(question: str, candidates: list) -> str:
    """Prompt asking the judge to SELECT one candidate, not to write one.

    The instruction to copy rather than improve is load-bearing: a judge that
    edits the winner is a synthesizer wearing a judge's hat, and synthesis is
    the regime where diverse teams lose.
    """
    blocks = []
    for index, candidate in enumerate(candidates):
        blocks.append(
            f"--- ANSWER {index} (from {candidate['peer']}) ---\n{candidate['answer']}"
        )
    joined = "\n\n".join(blocks)
    return (
        "You are selecting the single best answer to a question. "
        "You must CHOOSE one of the answers below verbatim. "
        "Do not write a new answer, do not merge answers, and do not edit "
        "the one you choose.\n\n"
        f"QUESTION:\n{question}\n\n"
        f"{joined}\n\n"
        "Reply in exactly this format:\n"
        "CHOICE: <the number of the best answer>\n"
        "REASON: <one or two sentences on why it beats the others>"
    )


def parse_judge_verdict(text: str, candidate_count: int) -> tuple:
    """Extract (index, reason) from a judge reply. Pure.

    Raises ValueError when the judge did not answer in the required format or
    named an answer that does not exist. A malformed verdict is a real failure
    and the caller decides what to do -- silently defaulting to answer 0 would
    turn a broken judge into a plausible-looking result.
    """
    match = _JUDGE_CHOICE.search(text or "")
    if not match:
        raise ValueError("judge reply contained no CHOICE line")
    index = int(match.group(1))
    if not 0 <= index < candidate_count:
        raise ValueError(
            f"judge chose answer {index}, but only 0..{candidate_count - 1} exist"
        )
    reason_match = _JUDGE_REASON.search(text)
    reason = reason_match.group(1).strip() if reason_match else ""
    return index, reason


def decompose_fixed(question: str) -> list:
    """A fixed 3-way split of *question*. Pure.

    Deliberately hardcoded. LLM-driven decomposition is a research problem and
    must not block a working pipeline; this exists so the shape is in place.
    Not used by the default fan-out path, where the judge needs N answers to
    the SAME question in order to compare them.
    """
    return [
        f"{question}\n\nAnswer directly and concisely.",
        f"{question}\n\nWork through this step by step before answering.",
        f"{question}\n\nIdentify the likely mistakes, then give the answer.",
    ]
