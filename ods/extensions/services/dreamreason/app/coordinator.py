"""DreamReason coordinator: fan out to peers, then select one answer.

Pipeline for one query:

  1. skill_router picks the skill, which is the LiteLLM model name
  2. fan out to at most MESH_FANOUT peers (default 3) via LiteLLM :4000
  3. if the answers agree, return the consensus and skip the judge
  4. otherwise a judge LLM selects the best answer and says why

Fan-out is capped at 3 on purpose. The Ringelmann Effect in Multi-Agent LLM
Systems (arXiv 2606.02646) finds modest degradation from 2 to 4 agents and a
significant accuracy drop from 5 to 10, with thirty dense debating agents
producing no more answer diversity than one on MMLU-Hard. Broadcasting to every
idle peer is the intuitive design and it is the wrong one.

All peer traffic goes through LiteLLM, never directly to a peer's llama-server
(ODS-RUNTIME-MESH-LLM-LOCAL-ROUTE).
"""

import asyncio
import logging
import os
import time

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from aggregator import (
    DEFAULT_CONSENSUS_THRESHOLD,
    build_judge_prompt,
    has_consensus,
    pairwise_agreement,
    parse_judge_verdict,
)
from skill_router import route, select_skill

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger("dreamreason")

LITELLM_URL = os.environ.get("MESH_LITELLM_URL", "http://litellm:4000/v1")
LITELLM_KEY = os.environ.get("LITELLM_KEY", "")
MESH_FANOUT = int(os.environ.get("MESH_FANOUT", "3"))
FANOUT_HARD_CAP = 5
JUDGE_MODEL = os.environ.get("MESH_JUDGE_MODEL", "local")
CONSENSUS_THRESHOLD = float(
    os.environ.get("MESH_CONSENSUS_THRESHOLD", DEFAULT_CONSENSUS_THRESHOLD)
)
PEER_TIMEOUT = float(os.environ.get("MESH_PEER_TIMEOUT_SECONDS", "120"))

app = FastAPI(title="DreamReason Coordinator", version="0.1.0")


class ReasonRequest(BaseModel):
    question: str
    fanout: int | None = None
    skills: list[str] | None = None


class ReasonResponse(BaseModel):
    answer: str
    selected_peer: str
    selection: str
    justification: str
    agreement: float
    candidates: list[dict]
    judge_invoked: bool
    total_tokens: int = 0


def effective_fanout(requested: int | None) -> int:
    """Clamp fan-out into [1, FANOUT_HARD_CAP]. Pure.

    The cap is a finding, not a config preference: accuracy drops materially
    from 5 to 10 agents, so the ceiling stays low even if someone asks for more.
    """
    value = MESH_FANOUT if requested is None else requested
    return max(1, min(value, FANOUT_HARD_CAP))


def peer_models(skills: list, question: str, fanout: int) -> list:
    """LiteLLM model names to query, best skill first. Pure.

    Deduplicated: querying one peer twice wastes a fan-out slot and hands the
    judge two identical candidates, which biases selection toward whichever
    peer happened to be duplicated.
    """
    if not skills:
        return [route(question)]
    best = select_skill(question, skills)
    ordered = [best] + [s for s in skills if s != best]
    models = []
    for skill in ordered:
        name = f"peer-{skill}"
        if name not in models:
            models.append(name)
        if len(models) == fanout:
            break
    return models


async def ask_peer(client: httpx.AsyncClient, model: str, question: str) -> dict:
    """One completion from *model* via LiteLLM.

    Narrow exceptions only, each mapped to a distinct outcome. A peer that
    times out and a peer that refuses are different states, and a failed peer
    is recorded rather than dropped -- silently shrinking the candidate pool
    would make the fan-out cap meaningless.
    """
    payload = {"model": model, "messages": [{"role": "user", "content": question}]}
    headers = {"Authorization": f"Bearer {LITELLM_KEY}"} if LITELLM_KEY else {}
    start = time.perf_counter()
    try:
        resp = await client.post(
            f"{LITELLM_URL}/chat/completions", json=payload, headers=headers,
            timeout=PEER_TIMEOUT,
        )
    except httpx.TimeoutException:
        return {"peer": model, "answer": None, "state": "timed-out",
                "latency_s": time.perf_counter() - start}
    except httpx.ConnectError as exc:
        return {"peer": model, "answer": None, "state": "unreachable",
                "detail": str(exc), "latency_s": time.perf_counter() - start}

    elapsed = time.perf_counter() - start
    if resp.status_code >= 400:
        return {"peer": model, "answer": None, "state": f"http-{resp.status_code}",
                "latency_s": elapsed}

    body = resp.json()
    usage = body.get("usage") or {}
    return {
        "peer": model,
        "answer": body["choices"][0]["message"]["content"],
        "state": "ok",
        "model": body.get("model"),
        # Per-peer timing is what makes the straggler effect measurable.
        "latency_s": elapsed,
        "total_tokens": usage.get("total_tokens", 0),
    }


async def run_judge(client: httpx.AsyncClient, question: str, candidates: list) -> tuple:
    """Ask the judge to select a candidate. Returns (index, reason, tokens)."""
    prompt = build_judge_prompt(question, candidates)
    verdict = await ask_peer(client, JUDGE_MODEL, prompt)
    if verdict["state"] != "ok":
        raise HTTPException(
            status_code=502,
            detail=f"judge model {JUDGE_MODEL} unavailable: {verdict['state']}",
        )
    index, reason = parse_judge_verdict(verdict["answer"], len(candidates))
    return index, reason, verdict.get("total_tokens", 0)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "fanout": MESH_FANOUT, "judge": JUDGE_MODEL}


@app.post("/v1/reason", response_model=ReasonResponse)
async def reason(request: ReasonRequest) -> ReasonResponse:
    """Fan out one question, then select the best answer.

    Returns 502 when no peer answered: an empty candidate pool is a failure,
    not an empty result to paper over.
    """
    fanout = effective_fanout(request.fanout)
    models = peer_models(request.skills or [], request.question, fanout)

    async with httpx.AsyncClient() as client:
        results = await asyncio.gather(
            *(ask_peer(client, model, request.question) for model in models)
        )
        answered = [r for r in results if r["state"] == "ok"]
        if not answered:
            raise HTTPException(
                status_code=502,
                detail=f"no peer answered; states={[r['state'] for r in results]}",
            )

        answers = [r["answer"] for r in answered]
        agreement = pairwise_agreement(answers)
        tokens = sum(r.get("total_tokens", 0) for r in results)

        # MOSAIC: on consensus the judge costs latency and buys nothing.
        if has_consensus(answers, CONSENSUS_THRESHOLD):
            return ReasonResponse(
                answer=answered[0]["answer"],
                selected_peer=answered[0]["peer"],
                selection="consensus",
                justification=(
                    f"{len(answers)} peers agreed at {agreement:.2f} "
                    f"(threshold {CONSENSUS_THRESHOLD}); judge skipped."
                ),
                agreement=agreement,
                candidates=results,
                judge_invoked=False,
                total_tokens=tokens,
            )

        if len(answered) == 1:
            return ReasonResponse(
                answer=answered[0]["answer"],
                selected_peer=answered[0]["peer"],
                selection="sole-responder",
                justification="Only one peer answered; nothing to select between.",
                agreement=agreement,
                candidates=results,
                judge_invoked=False,
                total_tokens=tokens,
            )

        index, reason_text, judge_tokens = await run_judge(
            client, request.question, answered)
        tokens += judge_tokens

    return ReasonResponse(
        answer=answered[index]["answer"],
        selected_peer=answered[index]["peer"],
        selection="judge",
        justification=reason_text,
        agreement=agreement,
        candidates=results,
        judge_invoked=True,
        total_tokens=tokens,
    )
