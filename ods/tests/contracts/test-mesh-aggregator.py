#!/usr/bin/env python3
"""Contract: DreamReason aggregation.

Three research findings are encoded here as executable rules:

  1. the aggregator SELECTS, it never blends  (arXiv 2603.20324 / 2502.00674)
  2. consensus bypasses the judge entirely    (MOSAIC, arXiv 2606.03014)
  3. fan-out stays small                      (Ringelmann, arXiv 2606.02646)
"""

import importlib.util
import sys
from pathlib import Path

ODS_ROOT = Path(__file__).resolve().parents[2]
APP = ODS_ROOT / "extensions" / "services" / "dreamreason" / "app"
sys.path.insert(0, str(APP))

_spec = importlib.util.spec_from_file_location("aggregator", APP / "aggregator.py")
agg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(agg)

FAILURES = []


def check(label, condition):
    if condition:
        print(f"[PASS] {label}")
    else:
        print(f"[FAIL] {label}")
        FAILURES.append(label)


def candidates():
    return [
        {"peer": "peer-code", "answer": "Use a hash map for O(n) lookup."},
        {"peer": "peer-reasoning", "answer": "Sort the array, then binary search."},
        {"peer": "peer-general", "answer": "Loop over every pair and compare."},
    ]


def test_judge_prompt_forbids_blending():
    prompt = agg.build_judge_prompt("How do I find duplicates?", candidates())
    lowered = prompt.lower()
    check("judge told to choose", "choose one of the answers" in lowered)
    check("judge told not to merge", "do not merge" in lowered)
    check("judge told not to write a new answer", "do not write a new answer" in lowered)
    check("judge told not to edit the winner", "do not edit" in lowered)
    check("every candidate is offered", all(c["answer"] in prompt for c in candidates()))


def test_verdict_selects_an_existing_answer():
    index, reason = agg.parse_judge_verdict("CHOICE: 1\nREASON: it is O(n log n).", 3)
    check("selected index parsed", index == 1)
    check("justification captured", "O(n log n)" in reason)


def test_malformed_verdict_raises():
    for reply, label in [
        ("I think the second one is nice.", "no CHOICE line raises"),
        ("CHOICE: 7\nREASON: x", "out-of-range choice raises"),
        ("", "empty reply raises"),
    ]:
        try:
            agg.parse_judge_verdict(reply, 3)
            check(label, False)
        except ValueError:
            check(label, True)


def test_consensus_bypasses_the_judge():
    same = ["The answer is 42.", "The answer is 42.", "The answer is 42."]
    check("identical answers reach consensus", agg.has_consensus(same) is True)
    check("agreement is 1.0 when identical", agg.pairwise_agreement(same) == 1.0)


def test_disagreement_does_not_bypass():
    differing = [c["answer"] for c in candidates()]
    check("differing answers have no consensus", agg.has_consensus(differing) is False)
    check("agreement below threshold", agg.pairwise_agreement(differing) < 0.85)


def test_disagreeing_multiple_choice_is_not_consensus():
    """Regression: measured on BBH, not hypothetical.

    Peers that reason aloud share nearly all their text and differ only in the
    final token. Judged on surface similarity, (A)/(B)/(C) scored 0.957 and
    bypassed the judge on 14 of 14 benchmark items -- silently disabling
    selection on exactly the task it was being evaluated on.
    """
    differing = ["Working through it.\n(A)",
                 "Working through it.\n(B)",
                 "Working through it.\n(C)"]
    check("surface similarity really is high", agg.pairwise_agreement(differing) > 0.9)
    check("but disagreeing choices are NOT consensus",
          agg.has_consensus(differing) is False)


def test_same_choice_different_prose_is_consensus():
    same = ["Long reasoning about objects.\n(B)",
            "Completely different wording here.\n(B)"]
    check("same answer through different prose is consensus",
          agg.has_consensus(same) is True)


def test_short_form_answers_compare_on_the_answer():
    check("differing yes/no is not consensus",
          agg.has_consensus(["I think yes", "I think no"]) is False)
    check("matching true/false is consensus",
          agg.has_consensus(["Therefore true", "So, true"]) is True)


def test_single_answer_is_not_consensus():
    # One peer agreeing with itself is not agreement between peers.
    check("one answer is not consensus", agg.has_consensus(["only one"]) is False)
    check("zero answers are not unanimous", agg.pairwise_agreement([]) == 0.0)


def test_near_identical_answers_still_agree():
    near = ["The capital is Paris.", "The capital is Paris!"]
    check("trivial punctuation difference still agrees", agg.has_consensus(near) is True)


def test_fanout_is_capped():
    import coordinator  # noqa: E402  (needs sys.path above)
    check("default fan-out is 3", coordinator.effective_fanout(None) == 3)
    check("request for 10 peers is capped", coordinator.effective_fanout(10) <= 5)
    check("cap is never all peers", coordinator.effective_fanout(1000) == 5)
    check("fan-out of 0 is raised to 1", coordinator.effective_fanout(0) == 1)


def test_fanout_never_queries_one_peer_twice():
    import coordinator  # noqa: E402
    models = coordinator.peer_models(["code", "reasoning", "general"],
                                     "Write a Python function to sort a list", 3)
    check(f"no duplicate peers in fan-out ({models})", len(models) == len(set(models)))
    check("best skill leads", models[0] == "peer-code")
    # A ceiling, not a quota. Screening is allowed to come in under budget --
    # spending the full cap on a prompt that is plainly about code is the cost
    # RouteMoA removes.
    check("fan-out never exceeds the cap", len(models) <= 3)
    check("confident prompt comes in under budget", len(models) < 3)

    narrow = coordinator.peer_models(["code"], "Write a Python function", 3)
    check("one skill yields one peer, not padding", narrow == ["peer-code"])


def test_fanout_needs_no_skills_from_the_caller():
    """Regression caught on a live node: a chat client never sends skills, and
    without them peer_models returned a single model. Fan-out and selection
    were inert by default -- 'sole-responder' on every request."""
    import asyncio
    import coordinator  # noqa: E402

    class FakeResp:
        status_code = 200
        @staticmethod
        def json():
            return {"data": [{"id": "local"}, {"id": "peer-code"},
                             {"id": "peer-reasoning"}, {"id": "mesh"}]}

    class FakeClient:
        async def get(self, *a, **k):
            return FakeResp()

    coordinator._peer_skills.update({"expires": 0.0, "skills": []})
    skills = asyncio.run(coordinator.discover_peer_skills(FakeClient()))
    check(f"peer skills discovered from LiteLLM ({skills})",
          skills == ["code", "reasoning"])
    check("non-peer models ignored", "local" not in skills and "mesh" not in skills)

    # The regression this test exists for is fan-out going inert without
    # caller-supplied skills, so what matters is that discovery feeds routing
    # at all. The count is the screener's call, not this test's: "write a
    # python function" is diagnostic of code, so paying for reasoning too is
    # the waste RouteMoA screening removes.
    models = coordinator.peer_models(skills, "write a python function", 3)
    check(f"fan-out is driven by discovered skills ({models})",
          models and all(m[len("peer-"):] in skills for m in models))
    check("confidently-routed prompt reaches its skill", "peer-code" in models)

    # And with nothing to go on, breadth is restored.
    vague = coordinator.peer_models(skills, "what about it", 3)
    check(f"ambiguous prompt still spans the pool ({vague})", len(vague) == 2)


def test_discovery_failure_degrades_instead_of_breaking():
    import asyncio
    import httpx
    import coordinator  # noqa: E402

    class DeadClient:
        async def get(self, *a, **k):
            raise httpx.ConnectError("refused")

    coordinator._peer_skills.update({"expires": 0.0, "skills": []})
    got = asyncio.run(coordinator.discover_peer_skills(DeadClient()))
    check("unreachable gateway yields no skills rather than raising", got == [])


def test_generation_is_bounded():
    """Measured on a live node: a reasoning model spent ~300 tokens answering
    "hi", and three peers doing that ahead of a judge exceeded the timeout."""
    import coordinator  # noqa: E402
    check("a cap is set by default", coordinator.MESH_MAX_TOKENS > 0)
    check("cap is not absurdly large", coordinator.MESH_MAX_TOKENS <= 4096)


def test_fixed_decomposition_is_three_way():
    parts = agg.decompose_fixed("What is 2+2?")
    check("decomposition yields 3 parts", len(parts) == 3)
    check("each part keeps the question", all("2+2" in p for p in parts))
    check("parts are distinct framings", len(set(parts)) == 3)


def test_openai_surface_exists():
    """Without this the mesh is unreachable from Open WebUI and every other
    client in the stack, since they all speak OpenAI chat-completions."""
    import coordinator  # noqa: E402
    routes = {r.path for r in coordinator.app.routes}
    check("chat-completions route exists", "/v1/chat/completions" in routes)
    check("models route exists", "/v1/models" in routes)
    check("native reason route kept", "/v1/reason" in routes)


def test_extracts_the_user_turn_not_the_system_prompt():
    import coordinator  # noqa: E402
    text = coordinator.last_user_message([
        {"role": "system", "content": "You are helpful."},
        {"role": "user", "content": "first"},
        {"role": "assistant", "content": "reply"},
        {"role": "user", "content": "most recent"},
    ])
    check("takes the latest user turn", text == "most recent")

    parts = coordinator.last_user_message([
        {"role": "user", "content": [{"type": "text", "text": "multimodal"}]},
    ])
    check("handles multimodal content parts", "multimodal" in parts)


def test_answer_is_returned_verbatim_by_default():
    # Selection, not synthesis -- the UI must show the peer's answer as-is.
    import coordinator  # noqa: E402
    from models_stub import result
    payload = coordinator.to_openai_response(result(), "mesh")
    check("content is the selected answer unmodified",
          payload["choices"][0]["message"]["content"] == "the answer")
    check("audit trail attached", payload["ods_mesh"]["selected_peer"] == "peer-code")
    check("openai object type", payload["object"] == "chat.completion")


def test_stream_is_one_honest_chunk():
    # Nothing can be emitted until every peer answers and the judge chooses,
    # so faking token-by-token output would be a lie.
    import coordinator  # noqa: E402
    from models_stub import result
    body = coordinator.to_sse_stream(coordinator.to_openai_response(result(), "mesh"))
    check("sse chunks present", body.count("data: ") == 3)
    check("terminates with DONE", body.strip().endswith("[DONE]"))
    check("carries the answer", "the answer" in body)


def test_idle_peers_are_preferred_over_busy_ones():
    """mesh.yaml records idleness as of config generation. A peer that went
    busy afterwards still gets dispatched work unless availability is checked
    per request, and the request then queues behind whatever it is doing."""
    import coordinator  # noqa: E402

    ordered = coordinator.order_by_availability(
        ["code", "reasoning", "general"], ["general"])
    check(f"idle skill promoted ({ordered})", ordered[0] == "general")
    check("busy peers kept, not dropped", set(ordered) == {"code", "reasoning", "general"})


def test_no_idle_information_changes_nothing():
    import coordinator  # noqa: E402
    candidates = ["code", "reasoning", "general"]
    check("empty idle list is a no-op",
          coordinator.order_by_availability(candidates, []) == candidates)


def test_all_busy_still_answers():
    """Dropping busy peers would mean a mesh where everyone is momentarily
    busy answers nothing. A queued answer beats no answer."""
    import coordinator  # noqa: E402
    ordered = coordinator.order_by_availability(["code", "reasoning"], ["writing"])
    check("no idle match still returns candidates", len(ordered) == 2)


def test_availability_decides_who_makes_the_budget():
    """Ordering must run before the budget is applied, or a busy peer keeps a
    slot an idle one should have had."""
    import coordinator  # noqa: E402
    models = coordinator.peer_models(
        ["code", "reasoning", "general"], "what about it", 1,
        idle_skills=["general"])
    check(f"single slot goes to the idle peer ({models})", models == ["peer-general"])


def main():
    print("=== DreamReason aggregator contract ===")
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\n[OK] aggregator contract holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
