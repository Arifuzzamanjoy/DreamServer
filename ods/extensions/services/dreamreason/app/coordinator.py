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
import json
import logging
import os
import time

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
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
# Unbounded generation is the straggler mechanism MOSAIC describes: the
# whole fan-out waits on whichever peer decided to think longest, and a
# reasoning model will happily spend hundreds of tokens on a one-word
# question. 0 disables the cap.
MESH_MAX_TOKENS = int(os.environ.get("MESH_MAX_TOKENS", "512"))
# keyword until semantic routing is shown to beat it on a labelled set --
# see scripts/mesh-bench/compare-routers.py
MESH_ROUTER = os.environ.get("MESH_ROUTER", "keyword")

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


# LiteLLM's model list only changes on a config reload, so a short cache keeps
# discovery off the hot path without going stale in practice.
PEER_SKILL_TTL = 60.0
_peer_skills: dict = {"expires": 0.0, "skills": []}


async def discover_peer_skills(client: httpx.AsyncClient) -> list:
    """Skills LiteLLM currently serves, read from its model list.

    Without this the coordinator only fans out when the caller names skills --
    and a chat client never does, so every request would go to exactly one peer
    and selection would never run. That makes the whole system inert by
    default, which is worse than being wrong loudly.

    A failed lookup returns nothing rather than raising: discovery is an
    optimisation over keyword routing, and losing it should degrade fan-out,
    not break answering. It is logged so the degradation is visible.
    """
    now = time.monotonic()
    if now < _peer_skills["expires"]:
        return _peer_skills["skills"]

    headers = {"Authorization": f"Bearer {LITELLM_KEY}"} if LITELLM_KEY else {}
    try:
        resp = await client.get(f"{LITELLM_URL}/models", headers=headers, timeout=10.0)
    except httpx.TimeoutException:
        logger.warning("peer discovery timed out; falling back to keyword routing")
        return []
    except httpx.ConnectError as exc:
        logger.warning("peer discovery unreachable (%s); keyword routing", exc)
        return []

    if resp.status_code >= 400:
        logger.warning("peer discovery got HTTP %s; keyword routing", resp.status_code)
        return []

    skills = sorted(
        model["id"][len("peer-"):]
        for model in resp.json().get("data", [])
        if str(model.get("id", "")).startswith("peer-")
    )
    _peer_skills.update({"expires": now + PEER_SKILL_TTL, "skills": skills})
    logger.info("discovered %d peer skill(s): %s", len(skills), ", ".join(skills))
    return skills


def peer_models(skills: list, question: str, fanout: int,
                best: str = None) -> list:
    """LiteLLM model names to query, best skill first. Pure.

    Deduplicated: querying one peer twice wastes a fan-out slot and hands the
    judge two identical candidates, which biases selection toward whichever
    peer happened to be duplicated.
    """
    if not skills:
        return [route(question)] if best is None else [f"peer-{best}"]
    if best is None:
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


async def resolve_skill(client: httpx.AsyncClient, question: str,
                       skills: list) -> str:
    """Pick a skill using whichever router is configured.

    The semantic path is allowed to fail loudly. Falling back to keywords on
    error would make the two routers indistinguishable in production and would
    quietly hide a broken TEI or an unseeded Qdrant collection.
    """
    if MESH_ROUTER != "semantic":
        return select_skill(question, skills)
    from semantic_router import select_skill_semantic
    return await select_skill_semantic(client, question, skills)


async def ask_peer(client: httpx.AsyncClient, model: str, question: str) -> dict:
    """One completion from *model* via LiteLLM.

    Narrow exceptions only, each mapped to a distinct outcome. A peer that
    times out and a peer that refuses are different states, and a failed peer
    is recorded rather than dropped -- silently shrinking the candidate pool
    would make the fan-out cap meaningless.
    """
    payload = {"model": model, "messages": [{"role": "user", "content": question}]}
    if MESH_MAX_TOKENS > 0:
        payload["max_tokens"] = MESH_MAX_TOKENS
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


async def run_mesh(request: ReasonRequest) -> ReasonResponse:
    """Fan out one question, then select the best answer.

    Shared by /v1/reason and the OpenAI-compatible route so both go through
    exactly the same selection path.

    Raises 502 when no peer answered: an empty candidate pool is a failure,
    not an empty result to paper over.
    """
    fanout = effective_fanout(request.fanout)

    async with httpx.AsyncClient() as client:
        # Caller-supplied skills win; otherwise ask LiteLLM what it serves, so
        # a plain chat turn still fans out across every registered peer.
        skills = request.skills or await discover_peer_skills(client)
        best = await resolve_skill(client, request.question, skills)
        models = peer_models(skills, request.question, fanout, best=best)
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


@app.post("/v1/reason", response_model=ReasonResponse)
async def reason(request: ReasonRequest) -> ReasonResponse:
    """Native mesh entry point, returning the full selection audit trail."""
    return await run_mesh(request)


# ---------------------------------------------------------------------------
# OpenAI-compatible surface
#
# Without this the mesh is unreachable from any UI: Open WebUI, the dashboard
# and every other client in the stack speak OpenAI chat-completions to LiteLLM,
# and /v1/reason is not that shape. Registering this route as a model named
# MESH_MODEL_NAME in mesh.yaml puts "mesh" in the model dropdown, so selecting
# it routes a normal chat turn through fan-out and judge selection.
# ---------------------------------------------------------------------------

MESH_MODEL_NAME = os.environ.get("MESH_MODEL_NAME", "mesh")
# Peer skills advertised to the router when a client cannot say (a chat UI
# never will). Comma-separated.
DEFAULT_SKILLS = [
    s for s in os.environ.get("MESH_DEFAULT_SKILLS", "").split(",") if s
]
# Chat UIs show only the message, so the selection rationale would be lost.
SHOW_RATIONALE = os.environ.get("MESH_SHOW_RATIONALE", "false").lower() == "true"


def last_user_message(messages: list) -> str:
    """Text of the most recent user turn. Pure.

    Raises when there is none: answering the system prompt would look like a
    working mesh returning nonsense.
    """
    for message in reversed(messages or []):
        if message.get("role") == "user":
            content = message.get("content")
            if isinstance(content, str):
                return content
            # Multimodal content arrives as a list of parts.
            if isinstance(content, list):
                return " ".join(
                    part.get("text", "") for part in content
                    if isinstance(part, dict)
                )
    raise HTTPException(status_code=400, detail="no user message in request")


def to_openai_response(result: ReasonResponse, model: str) -> dict:
    """Map a mesh result onto an OpenAI chat.completion. Pure."""
    content = result.answer
    if SHOW_RATIONALE:
        content = f"{content}\n\n---\n*{result.selected_peer}* — {result.justification}"
    return {
        "id": f"chatcmpl-mesh-{int(time.time() * 1000)}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": content},
            "finish_reason": "stop",
        }],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0,
                  "total_tokens": result.total_tokens},
        # Non-standard; clients ignore unknown keys, but it keeps the audit
        # trail visible to anything that looks.
        "ods_mesh": {
            "selected_peer": result.selected_peer,
            "selection": result.selection,
            "justification": result.justification,
            "agreement": result.agreement,
            "judge_invoked": result.judge_invoked,
        },
    }


def to_sse_stream(payload: dict) -> str:
    """One-chunk SSE body for clients that asked to stream. Pure.

    The mesh cannot stream honestly: nothing can be emitted until every peer
    has answered and the judge has chosen. Sending the finished answer as a
    single chunk is truthful, where faking token-by-token output would not be.
    """
    content = payload["choices"][0]["message"]["content"]
    chunk = {
        "id": payload["id"], "object": "chat.completion.chunk",
        "created": payload["created"], "model": payload["model"],
        "choices": [{"index": 0, "delta": {"role": "assistant",
                                           "content": content},
                     "finish_reason": None}],
    }
    done = {
        "id": payload["id"], "object": "chat.completion.chunk",
        "created": payload["created"], "model": payload["model"],
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }
    return (f"data: {json.dumps(chunk)}\n\n"
            f"data: {json.dumps(done)}\n\n"
            "data: [DONE]\n\n")


@app.get("/v1/models")
async def list_models() -> dict:
    """Advertise the mesh as one model, so clients can discover it."""
    return {"object": "list", "data": [{
        "id": MESH_MODEL_NAME, "object": "model",
        "created": int(time.time()), "owned_by": "ods-dreamreason",
    }]}


@app.post("/v1/chat/completions")
async def chat_completions(body: dict):
    """OpenAI-compatible entry point onto the mesh.

    Guards against a routing loop: if this route is reached asking for a
    peer-* model, LiteLLM has been misconfigured to point a peer back at the
    coordinator, and fanning out again would recurse.
    """
    model = body.get("model") or MESH_MODEL_NAME
    if str(model).startswith("peer-"):
        raise HTTPException(
            status_code=400,
            detail=(f"model {model!r} routes back into the coordinator; "
                    "peer-* models must point at peers, not at dreamreason"),
        )

    question = last_user_message(body.get("messages"))
    result = await run_mesh(ReasonRequest(
        question=question,
        fanout=body.get("fanout"),
        skills=body.get("skills") or DEFAULT_SKILLS or None,
    ))
    payload = to_openai_response(result, str(model))

    if body.get("stream"):
        return StreamingResponse(iter([to_sse_stream(payload)]),
                                 media_type="text/event-stream")
    return payload
