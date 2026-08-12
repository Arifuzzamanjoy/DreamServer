"""RouteMoA SLM Scorer router.

Implements routing using an external Small Language Model (SLM) trained with Contrastive Loss
to score how well a prompt fits various skill candidates, as described in arXiv 2601.18130.
"""

import logging
import os
import httpx

from skill_router import GENERAL_SKILL, ROUTE_MARGIN, CONFIDENT_SCORE

logger = logging.getLogger("dreamreason.routemoa")

ROUTEMOA_URL = os.environ.get("MESH_ROUTEMOA_URL", "http://routemoa-scorer:8000")
TIMEOUT = float(os.environ.get("MESH_ROUTEMOA_TIMEOUT_SECONDS", "5"))


class ScorerUnavailable(RuntimeError):
    """RouteMoA Scorer could not be reached or did not answer usefully."""


async def rank_skills_routemoa(client: httpx.AsyncClient, prompt: str, candidates: list) -> list:
    """Ask the SLM scorer to score the prompt against the given candidates.
    Returns [(skill, score), ...], best first.
    """
    if not candidates:
        return []

    try:
        resp = await client.post(
            f"{ROUTEMOA_URL}/score",
            json={"prompt": prompt, "candidates": candidates},
            timeout=TIMEOUT,
        )
    except httpx.ConnectError as exc:
        raise ScorerUnavailable(f"RouteMoA Scorer unreachable at {ROUTEMOA_URL}: {exc}") from exc
    except httpx.TimeoutException as exc:
        raise ScorerUnavailable(f"RouteMoA Scorer timed out after {TIMEOUT}s") from exc

    if resp.status_code >= 400:
        raise ScorerUnavailable(f"RouteMoA Scorer returned HTTP {resp.status_code}")

    scores = resp.json().get("scores", {})
    # Expected format: {"algebra": 2.5, "geometry": 0.8, ...}
    
    ranked = [(skill, float(scores.get(skill, 0.0))) for skill in candidates]
    ranked.sort(key=lambda pair: (-pair[1], pair[0]))
    return ranked


async def select_skill_routemoa(client: httpx.AsyncClient, prompt: str, available: list = None) -> str:
    """Best skill for *prompt* based on RouteMoA SLM scores, restricted to *available*."""
    offered = list(dict.fromkeys(available or []))
    if not offered:
        return GENERAL_SKILL

    ranked = await rank_skills_routemoa(client, prompt, offered)
    if not ranked:
        return GENERAL_SKILL

    best = ranked[0][0]
    logger.debug("routemoa route %r -> %s (%.3f)", prompt[:60], best, ranked[0][1])
    return best


async def select_candidates_routemoa(client: httpx.AsyncClient, prompt: str, available: list, limit: int,
                                     threshold: float = 0.2) -> list:
    """Skills worth querying for *prompt*, best first, at most *limit*.
    
    Applies RouteMoA thresholding: Maps probabilities through a piecewise power function
    and keeps candidates whose mapped score is within *threshold* of the best score.
    """
    offered = list(dict.fromkeys(available or []))
    if not offered or limit <= 0:
        return []

    ranked = await rank_skills_routemoa(client, prompt, offered)

    if not ranked:
        best = offered[0]
        ordered = [best] + [skill for skill in offered if skill != best]
        return ordered[:limit]

    def map_score(x: float, a=0.8, b=1.5, c=0.8, d=1.5) -> float:
        # RouteMoA power function mapping for probabilities in [0, 1]
        x = max(0.0, min(1.0, x))
        if x < 0.5:
            return a * (x ** b)
        else:
            return 1 - c * ((1 - x) ** d)

    mapped_scores = {skill: map_score(score) for skill, score in ranked}
    best_mapped = mapped_scores[ranked[0][0]]

    selected = [skill for skill, _ in ranked if (best_mapped - mapped_scores[skill]) <= threshold]
    
    return selected[:limit]
