"""Skill-level routing for DreamReason.

Routes on *skills* -- `algebra`, `geometry` -- rather than task categories like
`math`. Symbolic-MoE (arXiv 2503.05641) measures +8.15% absolute over the best
multi-agent baseline from that distinction alone: task-level expert selection
is too coarse, because the peer that is good at algebra is often not the peer
that is good at geometry.

Deliberately static keyword/regex rules, not embeddings. This is the baseline
that semantic routing has to beat; if TEI + Qdrant cannot beat a table of
regexes, that is a finding worth having rather than an assumption worth
shipping.

Pure module: no I/O, no state. Same prompt in, same ranking out.

Why not extend extensions/services/model-router (:9099)? That service resolves
one active endpoint from model-state.json through a read-only allowlist, and
rejects any upstream not on it (`endpoint_not_allowlisted`). Mesh peers are
dynamic upstreams discovered at runtime, so routing to them through that
allowlist would mean defeating the invariant it exists to enforce. It is an
alias indirection plane, not a content router -- it contains no
prompt-inspection logic at all. Skill routing belongs here, where the model
name it produces is the routing key LiteLLM already dispatches on.
"""

import re

GENERAL_SKILL = "general"

# Weight 2 = strongly diagnostic of the skill on its own.
# Weight 1 = suggestive; needs company to win.
SKILL_RULES = {
    "algebra": [
        (2, r"\bsolve for\b"),
        (2, r"\b(quadratic|polynomial|logarithm|inequalit(?:y|ies))\b"),
        (2, r"\bfactor(?:i[sz]e|ing)?\b.*\bexpression\b"),
        (1, r"\bequations?\b"),
        (1, r"\bvariables?\b"),
        (1, r"\b(simplify|expand)\b"),
        (1, r"\bx\s*[\+\-\*/=]\s*\d"),
    ],
    "geometry": [
        (2, r"\b(triangle|circle|polygon|hypotenuse|rhombus|trapezoid)\b"),
        (2, r"\b(perimeter|circumference)\b"),
        (1, r"\bangles?\b"),
        (1, r"\b(radius|diameter)\b"),
        (1, r"\bareas?\b"),
        (1, r"\b(parallel|perpendicular)\b"),
    ],
    "arithmetic": [
        (2, r"\bpercent(?:age)?\b"),
        (1, r"\b(add|subtract|multiply|divide)\b"),
        (1, r"\b(sum|product|average|mean)\b"),
        (1, r"\bhow much (?:is|does)\b"),
    ],
    "code": [
        (2, r"\b(python|javascript|typescript|rust|golang|java|c\+\+|sql)\b"),
        (2, r"\b(function|def|class|method|API|endpoint)\b"),
        (2, r"\b(debug|refactor|compile|stack ?trace|traceback)\b"),
        (1, r"\b(bug|error|exception)\b"),
        (1, r"\b(array|list|dict|hash ?map|linked list)\b"),
        (1, r"\b(implement|write|fix)\b.*\b(code|script|program)\b"),
    ],
    "logic": [
        (2, r"\b(syllogism|tautolog(?:y|ies)|contrapositive)\b"),
        (2, r"\bknights? and knaves\b"),
        (1, r"\bif .* then\b"),
        (1, r"\b(deduce|entails?|implies)\b"),
        (1, r"\b(valid|invalid)\b.*\bargument\b"),
        (1, r"\bpuzzle\b"),
    ],
    "reasoning": [
        (2, r"\bstep by step\b"),
        (1, r"\bwhy (?:does|do|is|are|would)\b"),
        (1, r"\b(explain|justify|reason(?:ing)?)\b"),
        (1, r"\b(cause|because|therefore|consequence)\b"),
        (1, r"\bwhat would happen\b"),
    ],
    "writing": [
        (2, r"\b(essay|paragraph|blog post|article)\b"),
        (2, r"\b(rewrite|paraphrase|proofread)\b"),
        (1, r"\b(summari[sz]e|draft|compose)\b"),
        (1, r"\b(tone|style|prose)\b"),
    ],
}

_COMPILED = {
    skill: [(weight, re.compile(pattern, re.IGNORECASE))
            for weight, pattern in rules]
    for skill, rules in SKILL_RULES.items()
}


def score_skill(prompt: str, skill: str) -> int:
    """Total weight of rules for *skill* that match *prompt*. Pure."""
    return sum(weight for weight, rx in _COMPILED[skill] if rx.search(prompt))


def rank_skills(prompt: str) -> list:
    """All scoring skills, best first. Pure and deterministic.

    Ties break alphabetically so the same prompt always routes the same way --
    a router that reshuffles under load is untestable.
    """
    scored = [(skill, score_skill(prompt, skill)) for skill in _COMPILED]
    ranked = [(skill, score) for skill, score in scored if score > 0]
    ranked.sort(key=lambda pair: (-pair[1], pair[0]))
    return ranked


def select_skill(prompt: str, available: list = None) -> str:
    """Best skill for *prompt*, restricted to *available* when given.

    Falls back to GENERAL_SKILL when nothing matches or no ranked skill is
    offered by any peer. Returning a skill nobody serves would be a routing
    decision that cannot be honoured.
    """
    ranked = rank_skills(prompt)
    if available is None:
        return ranked[0][0] if ranked else GENERAL_SKILL
    offered = set(available)
    for skill, _ in ranked:
        if skill in offered:
            return skill
    return GENERAL_SKILL if GENERAL_SKILL in offered or not offered else sorted(offered)[0]


def model_for_skill(skill: str) -> str:
    """LiteLLM model name for *skill* -- the routing key mesh.yaml declares."""
    return f"peer-{skill}"


def route(prompt: str, available: list = None) -> str:
    """Convenience: prompt straight to a LiteLLM model name. Pure."""
    return model_for_skill(select_skill(prompt, available))
