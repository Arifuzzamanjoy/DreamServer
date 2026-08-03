"""Semantic skill routing: TEI embeddings + Qdrant capability vectors.

The alternative to skill_router's regex table. Each skill is represented by a
set of exemplar phrasings, embedded once into a Qdrant collection; a prompt is
embedded at request time and routed to its nearest capability vector.

Behind a flag (MESH_ROUTER=semantic) on purpose. The keyword router is the
baseline this has to beat, and it is not obviously going to: regexes are free,
deterministic, and need no extra services on the critical path, while this adds
a TEI round trip and a Qdrant query to every request. If embeddings do not win
by enough to pay for that, keeping the regexes is the correct outcome and the
comparison is the deliverable, not the embedding.

Compare them with scripts/mesh-bench/compare-routers.py.
"""

import logging
import os

import httpx

from skill_router import GENERAL_SKILL, SKILL_RULES

logger = logging.getLogger("dreamreason.semantic")

TEI_URL = os.environ.get("MESH_TEI_URL", "http://embeddings:80")
QDRANT_URL = os.environ.get("MESH_QDRANT_URL", "http://qdrant:6333")
COLLECTION = os.environ.get("MESH_QDRANT_COLLECTION", "mesh_capabilities")
TIMEOUT = float(os.environ.get("MESH_ROUTER_TIMEOUT_SECONDS", "5"))
# Below this cosine score the nearest capability is not a real match, so
# routing on it would be worse than admitting we do not know.
MIN_SCORE = float(os.environ.get("MESH_ROUTER_MIN_SCORE", "0.55"))

# Exemplars per skill. Deliberately phrased as user requests rather than
# definitions -- the query at inference time is a user request, and embedding
# similarity is sensitive to that register mismatch.
CAPABILITY_EXEMPLARS = {
    "algebra": [
        "solve for x in this equation",
        "factor this polynomial",
        "simplify this algebraic expression",
        "find the roots of a quadratic",
    ],
    "geometry": [
        "find the area of a triangle",
        "what is the circumference of this circle",
        "calculate the angle between two lines",
        "compute the perimeter of a polygon",
    ],
    "arithmetic": [
        "what is 15 percent of 200",
        "add these numbers together",
        "compute the average of this list",
    ],
    "code": [
        "write a python function that does this",
        "debug this stack trace",
        "refactor this class",
        "why does this code throw an exception",
    ],
    "logic": [
        "is this argument valid or invalid",
        "solve this knights and knaves puzzle",
        "what follows from these premises",
    ],
    "reasoning": [
        "explain step by step why this happens",
        "what would happen if this changed",
        "justify this conclusion",
    ],
    "writing": [
        "rewrite this paragraph in a warmer tone",
        "summarise this article",
        "draft a blog post about this",
    ],
}


class EmbeddingUnavailable(RuntimeError):
    """TEI could not be reached or did not answer usefully."""


class CapabilityIndexUnavailable(RuntimeError):
    """Qdrant could not be reached or the collection is missing."""


async def embed(client: httpx.AsyncClient, texts: list) -> list:
    """Embed *texts* via TEI.

    Narrow exceptions only, each meaning something different: TEI being absent
    is a deployment problem, TEI being slow is a capacity problem, and they
    should not be reported as the same thing.
    """
    try:
        resp = await client.post(f"{TEI_URL}/embed", json={"inputs": texts},
                                 timeout=TIMEOUT)
    except httpx.ConnectError as exc:
        raise EmbeddingUnavailable(f"TEI unreachable at {TEI_URL}: {exc}") from exc
    except httpx.TimeoutException as exc:
        raise EmbeddingUnavailable(f"TEI timed out after {TIMEOUT}s") from exc

    if resp.status_code >= 400:
        raise EmbeddingUnavailable(f"TEI returned HTTP {resp.status_code}")
    return resp.json()


async def nearest_skill(client: httpx.AsyncClient, vector: list) -> tuple:
    """Nearest capability vector in Qdrant. Returns (skill, score)."""
    try:
        resp = await client.post(
            f"{QDRANT_URL}/collections/{COLLECTION}/points/search",
            json={"vector": vector, "limit": 1, "with_payload": True},
            timeout=TIMEOUT,
        )
    except httpx.ConnectError as exc:
        raise CapabilityIndexUnavailable(
            f"Qdrant unreachable at {QDRANT_URL}: {exc}") from exc
    except httpx.TimeoutException as exc:
        raise CapabilityIndexUnavailable(f"Qdrant timed out after {TIMEOUT}s") from exc

    if resp.status_code >= 400:
        raise CapabilityIndexUnavailable(
            f"Qdrant returned HTTP {resp.status_code} for {COLLECTION}")

    hits = resp.json().get("result") or []
    if not hits:
        return GENERAL_SKILL, 0.0
    best = hits[0]
    return best["payload"]["skill"], float(best.get("score", 0.0))


def apply_availability(skill: str, score: float, available: list) -> str:
    """Clamp a semantic hit to something a peer actually serves. Pure."""
    if score < MIN_SCORE:
        skill = GENERAL_SKILL
    if not available:
        return skill
    return skill if skill in available else GENERAL_SKILL


async def select_skill_semantic(client: httpx.AsyncClient, prompt: str,
                                available: list = None) -> str:
    """Route *prompt* by embedding similarity.

    Raises rather than silently falling back to keywords: a semantic router
    that quietly degrades is one whose comparison against the baseline is
    meaningless. The caller chooses the fallback policy.
    """
    vectors = await embed(client, [prompt])
    skill, score = await nearest_skill(client, vectors[0])
    logger.debug("semantic route %r -> %s (%.3f)", prompt[:60], skill, score)
    return apply_availability(skill, score, available or [])


def exemplar_points() -> list:
    """Flat (id, skill, text) triples for seeding Qdrant. Pure."""
    points = []
    for skill in sorted(CAPABILITY_EXEMPLARS):
        for text in CAPABILITY_EXEMPLARS[skill]:
            points.append({"id": len(points) + 1, "skill": skill, "text": text})
    return points


def known_skills() -> list:
    """Skills both routers can produce. Pure.

    They must agree, or a comparison between them is measuring vocabulary
    rather than routing quality.
    """
    return sorted(set(CAPABILITY_EXEMPLARS) | set(SKILL_RULES))
