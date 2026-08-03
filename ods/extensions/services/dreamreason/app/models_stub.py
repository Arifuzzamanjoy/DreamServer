"""Test helper: a canned ReasonResponse. Not imported by the service."""

from coordinator import ReasonResponse


def result() -> ReasonResponse:
    return ReasonResponse(
        answer="the answer",
        selected_peer="peer-code",
        selection="judge",
        justification="clearest reasoning",
        agreement=0.4,
        candidates=[],
        judge_invoked=True,
        total_tokens=42,
    )
