"""
Tests for M4 Voice Classifier components.

Covers: KeywordClassifier, DeterministicRouter, FSMExecutor, entity extractors.
QwenClassifier and DistilBERTClassifier are tested with mocked HTTP/model calls.

Run from this directory:
    cd resources/products/voice-classifier
    python -m pytest test_voice_classifier.py -v
"""

import asyncio
import json
import os
import sys
import types
import unittest
from collections import defaultdict
from unittest.mock import MagicMock, patch, AsyncMock

# ── Import Setup ───────────────────────────────────────────────────────────────
# The voice-classifier is a Python package with relative imports.
# For standalone test execution we register it as a proper package first.
_this_dir = os.path.dirname(os.path.abspath(__file__))

# Create a synthetic package so relative imports in router.py resolve
_pkg_name = "voice_classifier"
if _pkg_name not in sys.modules:
    _pkg = types.ModuleType(_pkg_name)
    _pkg.__path__ = [_this_dir]
    _pkg.__package__ = _pkg_name
    sys.modules[_pkg_name] = _pkg

# Add directory to path for direct module imports
if _this_dir not in sys.path:
    sys.path.insert(0, _this_dir)

# Import modules that have NO relative imports (extractors, classifier, fsm)
from extractors import (
    extract_date,
    extract_email,
    extract_money,
    extract_name,
    extract_phone,
    extract_time,
    extract_time_preference,
    extract_url,
    extract_yes_no,
    extract_number,
    get_extractor,
    DEFAULT_EXTRACTORS,
)

from classifier import (
    ClassificationResult,
    KeywordClassifier,
    QwenClassifier,
)

from fsm import FSMExecutor, FlowContext, FlowResponse, FlowStatus, EXAMPLE_HVAC_FLOW

# Register these modules under the package name so router's relative imports work
import classifier as _classifier_mod
import fsm as _fsm_mod
import extractors as _extractors_mod
sys.modules[f"{_pkg_name}.classifier"] = _classifier_mod
sys.modules[f"{_pkg_name}.fsm"] = _fsm_mod
sys.modules[f"{_pkg_name}.extractors"] = _extractors_mod

# Load router with proper package context so its relative imports resolve
import importlib.util as _ilu
_router_spec = _ilu.spec_from_file_location(
    f"{_pkg_name}.router",
    os.path.join(_this_dir, "router.py"),
)
_router_mod = _ilu.module_from_spec(_router_spec)
_router_mod.__package__ = _pkg_name
sys.modules[f"{_pkg_name}.router"] = _router_mod
_router_spec.loader.exec_module(_router_mod)

DeterministicRouter = _router_mod.DeterministicRouter
RoutingDecision = _router_mod.RoutingDecision
RoutingTarget = _router_mod.RoutingTarget


# ── Extractor Tests ────────────────────────────────────────────────────────────


class TestExtractDate(unittest.TestCase):
    def test_tomorrow(self):
        self.assertEqual(extract_date("I'm free tomorrow"), "tomorrow")

    def test_today(self):
        self.assertEqual(extract_date("Can you come today?"), "today")

    def test_next_week(self):
        self.assertEqual(extract_date("How about next week?"), "next_week")

    def test_day_of_week(self):
        self.assertEqual(extract_date("Let's do Monday"), "monday")

    def test_no_date(self):
        self.assertIsNone(extract_date("I have a problem"))


class TestExtractName(unittest.TestCase):
    def test_my_name_is(self):
        self.assertEqual(extract_name("My name is John"), "John")

    def test_im_pattern(self):
        self.assertEqual(extract_name("I'm Sarah"), "Sarah")

    def test_this_is(self):
        self.assertEqual(extract_name("This is Mike"), "Mike")

    def test_no_name(self):
        self.assertIsNone(extract_name("I need help"))


class TestExtractPhone(unittest.TestCase):
    def test_dashed(self):
        self.assertIsNotNone(extract_phone("Call me at 555-123-4567"))

    def test_dotted(self):
        self.assertIsNotNone(extract_phone("My number is 555.123.4567"))

    def test_continuous(self):
        self.assertIsNotNone(extract_phone("5551234567 is my number"))

    def test_no_phone(self):
        self.assertIsNone(extract_phone("No phone here"))


class TestExtractEmail(unittest.TestCase):
    def test_simple_email(self):
        self.assertEqual(extract_email("email me at test@example.com"), "test@example.com")

    def test_no_email(self):
        self.assertIsNone(extract_email("no email here"))


class TestExtractYesNo(unittest.TestCase):
    def test_yes(self):
        self.assertTrue(extract_yes_no("yes"))

    def test_yeah(self):
        self.assertTrue(extract_yes_no("yeah"))

    def test_no(self):
        self.assertFalse(extract_yes_no("no"))

    def test_nope(self):
        self.assertFalse(extract_yes_no("nope"))

    def test_ambiguous(self):
        self.assertIsNone(extract_yes_no("maybe later"))


class TestExtractTime(unittest.TestCase):
    def test_morning(self):
        self.assertEqual(extract_time("I prefer morning"), "morning")

    def test_afternoon(self):
        self.assertEqual(extract_time("How about afternoon"), "afternoon")

    def test_no_time(self):
        self.assertIsNone(extract_time("Whenever works"))


class TestExtractMoney(unittest.TestCase):
    def test_dollar_sign(self):
        self.assertEqual(extract_money("That costs $150.00"), "150.00")

    def test_dollars_word(self):
        self.assertEqual(extract_money("About 200 dollars"), "200")

    def test_no_money(self):
        self.assertIsNone(extract_money("How much?"))


class TestExtractNumber(unittest.TestCase):
    def test_simple_number(self):
        self.assertEqual(extract_number("I need 3 units"), 3)

    def test_no_number(self):
        self.assertIsNone(extract_number("no numbers here"))


class TestExtractUrl(unittest.TestCase):
    def test_https(self):
        self.assertEqual(extract_url("Visit https://example.com"), "https://example.com")

    def test_no_url(self):
        self.assertIsNone(extract_url("no url here"))


class TestExtractorRegistry(unittest.TestCase):
    def test_get_extractor_returns_instances(self):
        for name in ["date", "name", "phone", "email", "yes_no", "time", "money"]:
            ext = get_extractor(name)
            self.assertIsNotNone(ext, f"Extractor '{name}' not found")
            self.assertTrue(hasattr(ext, "extract"), f"Extractor '{name}' missing .extract()")

    def test_default_extractors_dict(self):
        self.assertIn("date", DEFAULT_EXTRACTORS)
        self.assertIn("phone", DEFAULT_EXTRACTORS)
        self.assertTrue(callable(DEFAULT_EXTRACTORS["date"]))

    def test_unknown_extractor_returns_none(self):
        self.assertIsNone(get_extractor("nonexistent"))


# ── KeywordClassifier Tests ───────────────────────────────────────────────────


class TestKeywordClassifier(unittest.TestCase):
    def setUp(self):
        self.classifier = KeywordClassifier({
            "schedule_service": ["book", "schedule", "appointment", "service"],
            "emergency": ["urgent", "emergency", "broken", "not working"],
            "hours_location": ["hours", "open", "when", "location"],
        })

    def test_schedule_intent(self):
        # Matches 3/4 keywords: "book", "schedule", "appointment" → 0.75 confidence > 0.7 threshold
        result = self.classifier.predict("I want to book and schedule an appointment")
        self.assertEqual(result.intent, "schedule_service")
        self.assertGreater(result.confidence, 0)

    def test_emergency_intent(self):
        # Matches 3/4 keywords: "urgent", "emergency", "broken" → 0.75 confidence > 0.7 threshold
        result = self.classifier.predict("It's urgent, my heater is broken, this is an emergency!")
        self.assertEqual(result.intent, "emergency")

    def test_fallback_on_unknown(self):
        result = self.classifier.predict("What is the meaning of life?")
        self.assertEqual(result.intent, "fallback")

    def test_returns_classification_result(self):
        result = self.classifier.predict("book a service appointment")
        self.assertIsInstance(result, ClassificationResult)

    def test_predict_batch(self):
        results = self.classifier.predict_batch([
            "book schedule appointment",  # 3/4 match → above threshold
            "urgent emergency broken",     # 3/4 match → above threshold
        ])
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0].intent, "schedule_service")
        self.assertEqual(results[1].intent, "emergency")

    def test_predict_topk(self):
        topk = self.classifier.predict_topk("book appointment", k=2)
        self.assertIsInstance(topk, list)


# ── QwenClassifier Tests (Mocked) ─────────────────────────────────────────────


class TestQwenClassifier(unittest.TestCase):
    def setUp(self):
        self.classifier = QwenClassifier(
            base_url="http://localhost:8000/v1",
            threshold=0.85
        )

    @patch("classifier.QwenClassifier._get_session")
    def test_successful_classification(self, mock_session_fn):
        mock_session = MagicMock()
        mock_response = MagicMock()
        mock_response.json.return_value = {
            "choices": [{"message": {"content": '{"intent": "schedule_service", "confidence": 0.95}'}}]
        }
        mock_session.post.return_value = mock_response
        mock_session_fn.return_value = mock_session

        result = self.classifier.predict("I want to book an appointment")
        self.assertEqual(result.intent, "schedule_service")
        self.assertGreaterEqual(result.confidence, 0.85)

    @patch("classifier.QwenClassifier._get_session")
    def test_low_confidence_returns_fallback(self, mock_session_fn):
        mock_session = MagicMock()
        mock_response = MagicMock()
        mock_response.json.return_value = {
            "choices": [{"message": {"content": '{"intent": "schedule_service", "confidence": 0.50}'}}]
        }
        mock_session.post.return_value = mock_response
        mock_session_fn.return_value = mock_session

        result = self.classifier.predict("maybe something")
        self.assertEqual(result.intent, "fallback")

    @patch("classifier.QwenClassifier._get_session")
    def test_api_error_returns_fallback(self, mock_session_fn):
        mock_session = MagicMock()
        mock_session.post.side_effect = ConnectionError("Connection refused")
        mock_session_fn.return_value = mock_session

        result = self.classifier.predict("test")
        self.assertEqual(result.intent, "fallback")
        self.assertEqual(result.confidence, 0.0)

    @patch("classifier.QwenClassifier._get_session")
    def test_invalid_intent_returns_fallback(self, mock_session_fn):
        mock_session = MagicMock()
        mock_response = MagicMock()
        mock_response.json.return_value = {
            "choices": [{"message": {"content": '{"intent": "nonexistent_intent", "confidence": 0.99}'}}]
        }
        mock_session.post.return_value = mock_response
        mock_session_fn.return_value = mock_session

        result = self.classifier.predict("test")
        self.assertEqual(result.intent, "fallback")

    @patch("classifier.QwenClassifier._get_session")
    def test_markdown_code_block_parsing(self, mock_session_fn):
        mock_session = MagicMock()
        mock_response = MagicMock()
        mock_response.json.return_value = {
            "choices": [{"message": {"content": '```json\n{"intent": "emergency", "confidence": 0.92}\n```'}}]
        }
        mock_session.post.return_value = mock_response
        mock_session_fn.return_value = mock_session

        result = self.classifier.predict("My heater is broken!")
        self.assertEqual(result.intent, "emergency")


# ── FSMExecutor Tests ──────────────────────────────────────────────────────────


class TestFSMExecutor(unittest.TestCase):
    def setUp(self):
        self.fsm = FSMExecutor(extractors=DEFAULT_EXTRACTORS)
        self.fsm.flows["hvac_service"] = EXAMPLE_HVAC_FLOW

    def test_start_flow(self):
        response = self.fsm.start_flow("hvac_service", "session-1")
        self.assertEqual(response.status, FlowStatus.IN_PROGRESS)
        self.assertIn("Hello", response.text)

    def test_start_unknown_flow_raises(self):
        with self.assertRaises(ValueError):
            self.fsm.start_flow("nonexistent", "session-1")

    def test_state_transition(self):
        self.fsm.start_flow("hvac_service", "session-2")
        response = self.fsm.process_intent("session-2", "schedule_service", "I want to book")
        self.assertEqual(response.status, FlowStatus.IN_PROGRESS)
        # Should be in S2_gather_info now
        ctx = self.fsm.get_context("session-2")
        self.assertEqual(ctx.current_state, "S2_gather_info")

    def test_entity_capture_name(self):
        self.fsm.start_flow("hvac_service", "session-3")
        self.fsm.process_intent("session-3", "schedule_service", "Book please")
        response = self.fsm.process_intent("session-3", "provide_name", "My name is Alice")
        ctx = self.fsm.get_context("session-3")
        self.assertEqual(ctx.entities.get("customer_name"), "Alice")

    def test_unexpected_intent_returns_clarification(self):
        self.fsm.start_flow("hvac_service", "session-4")
        response = self.fsm.process_intent("session-4", "totally_random_intent", "blah")
        self.assertEqual(response.status, FlowStatus.CLARIFICATION_NEEDED)

    def test_final_state(self):
        self.fsm.start_flow("hvac_service", "session-5")
        self.fsm.process_intent("session-5", "schedule_service", "Book")
        self.fsm.process_intent("session-5", "provide_name", "My name is Bob")
        response = self.fsm.process_intent("session-5", "confirm", "Yes")
        self.assertEqual(response.status, FlowStatus.COMPLETED)

    def test_end_flow_clears_context(self):
        self.fsm.start_flow("hvac_service", "session-6")
        self.fsm.end_flow("session-6")
        self.assertIsNone(self.fsm.get_context("session-6"))

    def test_no_active_flow_raises(self):
        with self.assertRaises(ValueError):
            self.fsm.process_intent("nonexistent-session", "greet", "hello")

    def test_format_string_injection_safe(self):
        """Verify format_map(defaultdict) prevents __class__ injection."""
        self.fsm.start_flow("hvac_service", "session-7")
        self.fsm.process_intent("session-7", "schedule_service", "Book")
        # Inject malicious entity name
        ctx = self.fsm.get_context("session-7")
        ctx.entities["customer_name"] = "{__class__}"
        response = self.fsm.process_intent("session-7", "provide_name", "My name is {__class__}")
        # The template should render the literal string, not execute it
        self.assertNotIn("class", response.text.lower().replace("{__class__}", ""))

    def test_turn_count_increments(self):
        self.fsm.start_flow("hvac_service", "session-8")
        self.fsm.process_intent("session-8", "schedule_service", "Book")
        ctx = self.fsm.get_context("session-8")
        self.assertEqual(ctx.turn_count, 1)

    def test_history_tracking(self):
        self.fsm.start_flow("hvac_service", "session-9")
        self.fsm.process_intent("session-9", "schedule_service", "Book")
        ctx = self.fsm.get_context("session-9")
        self.assertEqual(len(ctx.history), 1)
        self.assertEqual(ctx.history[0]["intent"], "schedule_service")


# ── Router Tests ───────────────────────────────────────────────────────────────


class TestDeterministicRouter(unittest.TestCase):
    def setUp(self):
        self.classifier = KeywordClassifier({
            "schedule_service": ["book", "schedule", "appointment"],
            "emergency": ["urgent", "emergency", "broken"],
        })
        self.fsm = FSMExecutor(extractors=DEFAULT_EXTRACTORS)
        self.fsm.flows["hvac_service"] = EXAMPLE_HVAC_FLOW

        self.router = DeterministicRouter(
            classifier=self.classifier,
            fsm=self.fsm,
            fallback_threshold=0.85,
            clarification_threshold=0.70,
        )

    def _run(self, coro):
        """Run async coroutine in sync test. Compatible with Python 3.10+."""
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None
        if loop is None:
            return asyncio.run(coro)
        return loop.run_until_complete(coro)

    def test_high_confidence_routes_deterministic(self):
        # "book schedule appointment" matches 3/3 keywords = 1.0 confidence ≥ 0.85
        decision = self._run(self.router.route(
            "book schedule appointment", {}, "test-1"
        ))
        self.assertEqual(decision.target, RoutingTarget.DETERMINISTIC)
        self.assertIsNotNone(decision.response_text)

    def test_low_confidence_routes_fallback(self):
        decision = self._run(self.router.route(
            "What is the weather like today?", {}, "test-2"
        ))
        self.assertEqual(decision.target, RoutingTarget.FALLBACK)

    def test_medium_confidence_routes_fallback_with_intent(self):
        # "book" matches 1/3 keywords = 0.33 → below threshold → fallback
        # Need a phrase that hits 0.70-0.85 range
        classifier = KeywordClassifier(
            {"schedule_service": ["book", "appointment"]},
            fallback_threshold=0.3,  # Lower threshold so single keyword matches
        )
        router = DeterministicRouter(
            classifier=classifier,
            fsm=self.fsm,
            fallback_threshold=0.85,
            clarification_threshold=0.40,
        )
        decision = self._run(router.route("I want to book", {}, "test-3"))
        # 1/2 keywords = 0.5 confidence, above 0.40 clarification but below 0.85
        self.assertEqual(decision.target, RoutingTarget.FALLBACK)

    def test_metrics_tracking(self):
        self._run(self.router.route("book schedule appointment", {}, "test-4"))
        self._run(self.router.route("random gibberish", {}, "test-5"))
        metrics = self.router.get_metrics()
        self.assertEqual(metrics["total_routes"], 2)

    def test_metrics_reset(self):
        self._run(self.router.route("book appointment", {}, "test-6"))
        self.router.reset_metrics()
        metrics = self.router.get_metrics()
        self.assertEqual(metrics["total_routes"], 0)

    def test_routing_decision_to_dict(self):
        decision = self._run(self.router.route(
            "book schedule appointment", {}, "test-7"
        ))
        d = decision.to_dict()
        self.assertIn("target", d)
        self.assertIn("intent", d)
        self.assertIn("confidence", d)
        self.assertIn("latency_ms", d)


# ── Flow Context Tests ─────────────────────────────────────────────────────────


class TestFlowContext(unittest.TestCase):
    def test_capture_entity(self):
        ctx = FlowContext(flow_name="test", current_state="S1")
        ctx.capture_entity("name", "Alice")
        self.assertEqual(ctx.entities["name"], "Alice")

    def test_to_dict(self):
        ctx = FlowContext(flow_name="test", current_state="S1")
        ctx.capture_entity("phone", "555-1234")
        d = ctx.to_dict()
        self.assertEqual(d["flow_name"], "test")
        self.assertEqual(d["entities"]["phone"], "555-1234")


if __name__ == "__main__":
    unittest.main()
