"""Tests for /api/mesh/peers — DreamReason peer discovery.

The property under test throughout: peer states stay distinguishable. A peer
that refuses a connection, one that accepts and never answers, and one that
rejects the API key are three different operational problems and must never
collapse into a single failure value.
"""

import asyncio
import json

import aiohttp
import pytest
from aiohttp.client_reqrep import ConnectionKey

import mesh_vastai
import routers.mesh as mesh_mod
from routers.mesh import PeerHTTPStatus, parse_peers, peer_base_url, probe_peer


def _peer(hostname="peer-a", ip="100.64.0.2", online=True):
    return {
        "hostname": hostname,
        "dns_name": f"{hostname}.tail.ts.net",
        "ips": [ip] if ip else [],
        "online": online,
        "last_seen": "2026-08-03T12:00:00Z",
    }


def _capabilities(model="Qwen3.5-9B-Q4_K_M.gguf", skills=("reasoning",)):
    return {
        "ods_version": "2.6.0",
        "gpu": {"gpu_backend": "nvidia", "gpu_name": "RTX 4090", "vram_mb": 24576},
        "loaded_model": model,
        "skills": list(skills),
    }


def _idle(idle=True, utilization=3):
    return {
        "idle": idle,
        "utilization_percent": utilization,
        "threshold_percent": 10,
        "backend": "nvidia",
    }


class _FakeSession:
    """Maps a URL substring to a response payload or an exception to raise."""

    def __init__(self, routes):
        self._routes = routes

    def get(self, url, **kwargs):
        outcome = next(
            (v for k, v in self._routes.items() if k in url),
            PeerHTTPStatus(404),
        )
        return _FakeRequest(outcome)


class _FakeRequest:
    def __init__(self, outcome):
        self._outcome = outcome

    async def __aenter__(self):
        if isinstance(self._outcome, BaseException):
            raise self._outcome
        return _FakeResponse(self._outcome)

    async def __aexit__(self, *args):
        return False


class _FakeResponse:
    def __init__(self, payload):
        self._payload = payload
        self.status = 200

    async def json(self):
        return self._payload


def _connector_error(message="connection refused"):
    """A genuine ClientConnectorError -- the router catches that exact type."""
    key = ConnectionKey(
        host="100.64.0.2", port=3002, is_ssl=False, ssl=None, proxy=None,
        proxy_auth=None, proxy_headers_hash=None, server_hostname=None,
    )
    return aiohttp.ClientConnectorError(connection_key=key, os_error=OSError(message))


def _probe(routes, peer=None):
    session = _FakeSession(routes)
    return asyncio.run(probe_peer(session, peer or _peer(), "key"))


class TestParsePeers:
    def test_extracts_peer_list(self):
        peers = parse_peers({"peers": [_peer()]})
        assert len(peers) == 1
        assert peers[0]["hostname"] == "peer-a"

    def test_missing_peers_key_yields_nothing(self):
        # An older host agent predates the peers key; there is simply
        # nothing to discover, which is not an error.
        assert parse_peers({"running": True}) == []

    def test_non_list_peers_yields_nothing(self):
        assert parse_peers({"peers": {"a": 1}}) == []


class TestPeerBaseUrl:
    def test_prefers_tailscale_ip(self, monkeypatch):
        monkeypatch.setattr(mesh_mod, "PEER_API_PORT", 3002)
        assert peer_base_url(_peer(ip="100.64.0.9")) == "http://100.64.0.9:3002"

    def test_no_ip_is_unaddressable(self):
        assert peer_base_url(_peer(ip=None)) is None


class TestPeerStatesAreDistinct:
    def test_idle_peer(self):
        result = _probe({
            "/api/node/capabilities": _capabilities(),
            "/api/gpu/idle": _idle(idle=True),
        })
        assert result.state == "online-idle"
        assert result.idle is True
        assert result.loaded_model == "Qwen3.5-9B-Q4_K_M.gguf"
        assert result.skills == ["reasoning"]

    def test_busy_peer_is_not_idle(self):
        result = _probe({
            "/api/node/capabilities": _capabilities(),
            "/api/gpu/idle": _idle(idle=False, utilization=95),
        })
        assert result.state == "online-busy"
        assert result.utilization_percent == 95

    def test_timeout_is_its_own_state(self):
        result = _probe({"/api": asyncio.TimeoutError()})
        assert result.state == "timed-out"
        assert result.detail

    def test_connection_refused_is_unreachable(self):
        result = _probe({"/api": _connector_error()})
        assert result.state == "unreachable"

    def test_timeout_and_refusal_are_different_states(self):
        timed_out = _probe({"/api": asyncio.TimeoutError()})
        refused = _probe({"/api": _connector_error()})
        assert timed_out.state != refused.state

    def test_rejected_api_key_is_unauthorized(self):
        result = _probe({"/api": PeerHTTPStatus(401)})
        assert result.state == "unauthorized"

    def test_forbidden_is_unauthorized(self):
        assert _probe({"/api": PeerHTTPStatus(403)}).state == "unauthorized"

    def test_other_http_status_is_error(self):
        result = _probe({"/api": PeerHTTPStatus(500)})
        assert result.state == "error"

    def test_offline_peer_is_never_probed(self):
        def _explode(*args, **kwargs):
            raise AssertionError("offline peers must not be probed")

        session = _FakeSession({})
        session.get = _explode
        result = asyncio.run(probe_peer(session, _peer(online=False), "key"))
        assert result.state == "offline"

    def test_peer_without_ip_is_unreachable(self):
        result = _probe({}, peer=_peer(ip=None))
        assert result.state == "unreachable"
        assert "no Tailscale IP" in result.detail

    def test_failed_peer_keeps_its_identity(self):
        # A peer we cannot reach is still a peer worth reporting.
        result = _probe({"/api": asyncio.TimeoutError()})
        assert result.hostname == "peer-a"
        assert result.dns_name == "peer-a.tail.ts.net"


class TestProbeAuthHeader:
    """The probe must present the header the peer actually validates.

    dashboard-api guards every protected route with HTTPBearer, so a probe
    sent with X-API-Key authenticates nothing and comes back 401 -- which
    reads as `unauthorized`, indistinguishable from a genuine key mismatch.
    """

    @staticmethod
    def _headers_sent(api_key):
        seen = {}
        session = _FakeSession({
            "/api/node/capabilities": _capabilities(),
            "/api/gpu/idle": _idle(),
        })
        inner = session.get

        def _capture(url, **kwargs):
            seen.update(kwargs.get("headers") or {})
            return inner(url, **kwargs)

        session.get = _capture
        asyncio.run(probe_peer(session, _peer(), api_key))
        return seen

    def test_sends_bearer(self):
        assert self._headers_sent("shared")["Authorization"] == "Bearer shared"

    def test_does_not_send_x_api_key(self):
        assert "X-API-Key" not in self._headers_sent("shared")

    def test_no_key_sends_no_auth_header(self):
        assert self._headers_sent("") == {}


class TestMeshPeersEndpoint:
    def test_requires_auth(self, test_client):
        assert test_client.get("/api/mesh/peers").status_code in (401, 403)

    def test_tailscale_down_returns_empty_mesh(self, monkeypatch, test_client):
        monkeypatch.setattr(mesh_mod, "_tailscale_status", lambda: {"running": False})
        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 200
        body = r.json()
        assert body["tailscale_running"] is False
        assert body["peers"] == []

    def test_counts_only_idle_peers(self, monkeypatch, test_client):
        monkeypatch.setattr(mesh_mod, "_tailscale_status", lambda: {
            "running": True,
            "authenticated": True,
            "peers": [_peer("a", "100.64.0.2"), _peer("b", "100.64.0.3"),
                      _peer("c", "100.64.0.4", online=False)],
        })

        async def _fake_probe(session, peer, api_key):
            states = {"a": "online-idle", "b": "online-busy", "c": "offline"}
            return mesh_mod._unprobed(peer, states[peer["hostname"]])

        monkeypatch.setattr(mesh_mod, "probe_peer", _fake_probe)

        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 200
        body = r.json()
        assert body["peer_count"] == 3
        assert body["idle_count"] == 1
        assert body["tailscale_authenticated"] is True

    def test_host_agent_failure_propagates_as_http_error(self, monkeypatch, test_client):
        from fastapi import HTTPException

        def _boom():
            raise HTTPException(status_code=503, detail="ODS host agent is not reachable.")

        monkeypatch.setattr(mesh_mod, "_tailscale_status", _boom)
        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 503


class TestHostAgentPeerDistillation:
    """The host agent must stop discarding the Peer map."""

    def test_distills_peer_map(self):
        import importlib.util
        from pathlib import Path

        agent = Path(__file__).resolve().parents[4] / "bin" / "ods-host-agent.py"
        spec = importlib.util.spec_from_file_location("ods_host_agent", agent)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        peers = mod.distill_tailscale_peers({
            "Peer": {
                "nodekey:2": {"HostName": "beta", "TailscaleIPs": ["100.64.0.3"],
                              "Online": False, "DNSName": "beta.tail.ts.net."},
                "nodekey:1": {"HostName": "alpha", "TailscaleIPs": ["100.64.0.2"],
                              "Online": True, "DNSName": "alpha.tail.ts.net.",
                              "LastSeen": "2026-08-03T12:00:00Z"},
            }
        })

        assert [p["hostname"] for p in peers] == ["alpha", "beta"]  # stable order
        assert peers[0]["ips"] == ["100.64.0.2"]
        assert peers[0]["online"] is True
        assert peers[0]["dns_name"] == "alpha.tail.ts.net"  # trailing dot stripped
        assert peers[1]["online"] is False

    def test_no_peers_is_empty_not_an_error(self):
        import importlib.util
        from pathlib import Path

        agent = Path(__file__).resolve().parents[4] / "bin" / "ods-host-agent.py"
        spec = importlib.util.spec_from_file_location("ods_host_agent", agent)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        assert mod.distill_tailscale_peers({}) == []


class TestStaticPeering:
    """Peering without a tailnet, for rented GPU hosts (Vast.ai)."""

    def test_normalizes_a_declared_peer(self):
        peer = mesh_mod.normalize_static_peer({
            "hostname": "vast-a", "host": "203.0.113.10",
            "api_port": 41287, "litellm_port": 41288,
        })
        assert peer["ips"] == ["203.0.113.10"]
        assert peer["online"] is True  # declared; the probe decides the truth
        assert peer["api_port"] == 41287
        assert peer["litellm_port"] == 41288

    def test_peer_without_host_is_a_config_error(self):
        # A peer nobody can address is a mistake, not a peer.
        with pytest.raises(ValueError):
            mesh_mod.normalize_static_peer({"hostname": "nowhere"})

    def test_remapped_port_is_honoured(self):
        # The whole point on Vast.ai: external port != internal port.
        url = mesh_mod.peer_base_url({"ips": ["203.0.113.10"], "api_port": 41287})
        assert url == "http://203.0.113.10:41287"

    def test_missing_port_falls_back_to_the_local_convention(self, monkeypatch):
        monkeypatch.setattr(mesh_mod, "PEER_API_PORT", 3002)
        url = mesh_mod.peer_base_url({"ips": ["100.64.0.2"]})
        assert url == "http://100.64.0.2:3002"

    def test_loads_a_peer_file(self, tmp_path):
        path = tmp_path / "mesh-peers.json"
        path.write_text(json.dumps({"peers": [
            {"hostname": "a", "host": "203.0.113.10", "api_port": 1},
            {"hostname": "b", "host": "198.51.100.22", "api_port": 2},
        ]}))
        peers = mesh_mod.load_static_peers(path)
        assert [p["hostname"] for p in peers] == ["a", "b"]

    def test_malformed_peer_file_raises(self, tmp_path):
        # Silently ignoring it looks identical to "no peers", which is the
        # most confusing failure this feature can have.
        path = tmp_path / "bad.json"
        path.write_text("{not json")
        with pytest.raises(json.JSONDecodeError):
            mesh_mod.load_static_peers(path)

    def test_peer_file_without_peers_list_raises(self, tmp_path):
        path = tmp_path / "bad.json"
        path.write_text(json.dumps({"nodes": []}))
        with pytest.raises(ValueError):
            mesh_mod.load_static_peers(path)

    def test_static_source_bypasses_tailscale(self, monkeypatch, tmp_path, test_client):
        path = tmp_path / "mesh-peers.json"
        path.write_text(json.dumps({"peers": [
            {"hostname": "vast-a", "host": "203.0.113.10", "api_port": 41287},
        ]}))
        monkeypatch.setattr(mesh_mod, "PEER_FILE", path)
        monkeypatch.setattr(mesh_mod, "PEER_SOURCE", "static")

        def _explode():
            raise AssertionError("static peering must not call Tailscale")

        monkeypatch.setattr(mesh_mod, "_tailscale_status", _explode)

        async def _fake_probe(session, peer, api_key):
            return mesh_mod._unprobed(peer, "online-idle")

        monkeypatch.setattr(mesh_mod, "probe_peer", _fake_probe)

        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 200
        body = r.json()
        assert body["peer_source"] == "static"
        assert body["peer_count"] == 1
        assert body["peers"][0]["api_port"] == 41287

    def test_static_source_without_a_file_fails_loudly(self, monkeypatch, tmp_path,
                                                       test_client):
        monkeypatch.setattr(mesh_mod, "PEER_FILE", tmp_path / "absent.json")
        monkeypatch.setattr(mesh_mod, "PEER_SOURCE", "static")
        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 503

    def test_auto_prefers_tailscale_when_no_file(self, monkeypatch, tmp_path,
                                                 test_client):
        monkeypatch.setattr(mesh_mod, "PEER_FILE", tmp_path / "absent.json")
        monkeypatch.setattr(mesh_mod, "PEER_SOURCE", "auto")
        monkeypatch.setattr(mesh_mod, "_tailscale_status",
                            lambda: {"running": True, "authenticated": True, "peers": []})
        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 200
        assert r.json()["peer_source"] == "tailscale"


# ---------------------------------------------------------------------------
# Vast.ai peer source
# ---------------------------------------------------------------------------


def _instance(instance_id=312, label="dreamreason-mesh-b", status="running",
              ip="203.0.113.10", api_external="41287", litellm_external="41288"):
    """One entry as /api/v1/instances/ documents it.

    ports is the Docker-shaped map the live endpoint returns, with HostPort a
    string -- not the list of ints the v0 single-instance page documents.
    """
    ports = {"22/tcp": [{"HostIp": "0.0.0.0", "HostPort": "20000"}]}
    if api_external is not None:
        ports["3002/tcp"] = [{"HostIp": "0.0.0.0", "HostPort": api_external}]
    if litellm_external is not None:
        ports["4000/tcp"] = [{"HostIp": "0.0.0.0", "HostPort": litellm_external}]
    return {
        "id": instance_id,
        "label": label,
        "actual_status": status,
        "public_ipaddr": ip,
        "ports": ports,
    }


def _select(instances, label_prefix="dreamreason-mesh", self_id="999"):
    return mesh_vastai.select_mesh_peers(instances, label_prefix, self_id)


class _FakeVastResponse:
    def __init__(self, status, payload):
        self.status = status
        self._payload = payload

    async def json(self):
        return self._payload

    async def text(self):
        return json.dumps(self._payload)


class _FakeVastSession:
    """Serves a queued list of responses, or raises a queued exception."""

    def __init__(self, outcomes):
        self._outcomes = list(outcomes)
        self.calls = []

    def get(self, url, **kwargs):
        self.calls.append(kwargs.get("params", {}))
        return _FakeVastRequest(self._outcomes.pop(0))


class _FakeVastRequest:
    def __init__(self, outcome):
        self._outcome = outcome

    async def __aenter__(self):
        if isinstance(self._outcome, BaseException):
            raise self._outcome
        return self._outcome

    async def __aexit__(self, *args):
        return False


@pytest.fixture(autouse=True)
def _clear_vast_cache():
    """The roster cache is module state; no test may inherit another's."""
    mesh_vastai.reset_cache()
    yield
    mesh_vastai.reset_cache()


class TestVastPortResolution:
    """External ports come from the mapping, never from an assumption."""

    def test_resolves_the_external_port(self):
        assert mesh_vastai.external_port(_instance(), 3002) == 41287
        assert mesh_vastai.external_port(_instance(), 4000) == 41288

    def test_unpublished_port_resolves_to_nothing(self):
        # Ports must be requested when the instance is CREATED. This is what
        # that mistake looks like from the API side.
        assert mesh_vastai.external_port(_instance(api_external=None), 3002) is None

    def test_identity_mapping_is_honoured(self):
        # Vast's own example maps 8888 to 8888 while mapping 22 to 20000, so
        # "external differs from internal" is not a safe assumption either way.
        instance = _instance(api_external="3002")
        assert mesh_vastai.external_port(instance, 3002) == 3002

    def test_missing_ports_field_resolves_to_nothing(self):
        assert mesh_vastai.external_port({"id": 1}, 3002) is None

    def test_list_shaped_ports_field_resolves_to_nothing(self):
        # The v0 endpoint documents ports as [8080, 8081]. If that shape ever
        # arrives here, skip the peer rather than invent a port for it.
        assert mesh_vastai.external_port({"ports": [3002, 4000]}, 3002) is None


class TestVastMembership:
    def test_running_labelled_sibling_is_a_member(self):
        assert mesh_vastai.is_mesh_member(_instance(), "dreamreason-mesh", "999")

    def test_non_running_instance_is_not_a_member(self):
        assert not mesh_vastai.is_mesh_member(
            _instance(status="exited"), "dreamreason-mesh", "999")

    def test_unrelated_rental_is_not_a_member(self):
        # The label filter is what keeps someone else's training job in the
        # same account out of the mesh.
        assert not mesh_vastai.is_mesh_member(
            _instance(label="stable-diffusion-batch"), "dreamreason-mesh", "999")

    def test_self_is_not_a_member(self):
        assert not mesh_vastai.is_mesh_member(_instance(312), "dreamreason-mesh", "312")

    def test_self_matches_across_int_and_str_ids(self):
        # CONTAINER_ID arrives as a string; the API returns an int.
        assert not mesh_vastai.is_mesh_member(_instance(312), "dreamreason-mesh", 312)


class TestVastRosterSelection:
    def test_happy_path(self):
        peers = _select([_instance(312, "dreamreason-mesh-b")])
        assert len(peers) == 1
        assert peers[0]["hostname"] == "dreamreason-mesh-b"
        assert peers[0]["ips"] == ["203.0.113.10"]
        assert peers[0]["api_port"] == 41287
        assert peers[0]["litellm_port"] == 41288
        assert peers[0]["online"] is True  # asserted; the probe decides

    def test_output_matches_the_static_peer_shape(self):
        # probe_peer must not be able to tell the two sources apart.
        static = mesh_mod.normalize_static_peer({
            "hostname": "vast-a", "host": "203.0.113.10",
            "api_port": 41287, "litellm_port": 41288,
        })
        assert set(_select([_instance()])[0]) == set(static)

    def test_empty_instance_list(self):
        assert _select([]) == []

    def test_non_running_instances_are_dropped(self):
        assert _select([_instance(1, status="loading"),
                        _instance(2, status="exited")]) == []

    def test_self_is_excluded(self):
        peers = _select([_instance(312), _instance(313)], self_id="312")
        assert [p["hostname"] for p in peers] == ["dreamreason-mesh-b"]
        assert len(peers) == 1

    def test_instance_without_the_api_port_is_dropped(self):
        assert _select([_instance(api_external=None)]) == []

    def test_instance_without_the_litellm_port_is_dropped(self):
        # It would probe as online-idle and then be handed work it cannot
        # serve, which is worse than being absent.
        assert _select([_instance(litellm_external=None)]) == []

    def test_unaddressable_instance_is_a_roster_error(self):
        with pytest.raises(ValueError):
            mesh_vastai.normalize_vast_instance(_instance(ip=None), 41287, 41288)

    def test_empty_label_prefix_is_rejected(self):
        # An empty prefix admits every instance on the account.
        with pytest.raises(mesh_vastai.VastConfigError):
            _select([_instance()], label_prefix="")

    def test_mixed_roster(self):
        peers = _select([
            _instance(1, "dreamreason-mesh-a"),
            _instance(2, "someone-elses-job"),
            _instance(3, "dreamreason-mesh-c", status="exited"),
            _instance(4, "dreamreason-mesh-d", api_external=None),
            _instance(999, "dreamreason-mesh-self"),
        ])
        assert [p["hostname"] for p in peers] == ["dreamreason-mesh-a"]


class TestVastAPITransport:
    def _fetch(self, outcomes):
        session = _FakeVastSession(outcomes)
        return asyncio.run(mesh_vastai.fetch_instances(session)), session

    def test_reads_one_page(self):
        instances, _ = self._fetch([
            _FakeVastResponse(200, {"instances": [_instance()], "next_token": None}),
        ])
        assert len(instances) == 1

    def test_follows_the_keyset_cursor(self):
        # limit is capped at 25, so a roster past one page must be walked or
        # a missing node looks exactly like a node that was never rented.
        instances, session = self._fetch([
            _FakeVastResponse(200, {"instances": [_instance(1)], "next_token": "tok"}),
            _FakeVastResponse(200, {"instances": [_instance(2)], "next_token": None}),
        ])
        assert [i["id"] for i in instances] == [1, 2]
        assert session.calls[1]["after_token"] == "tok"

    def test_endless_cursor_raises(self):
        page = {"instances": [_instance()], "next_token": "tok"}
        with pytest.raises(mesh_vastai.VastAPIError):
            self._fetch([_FakeVastResponse(200, page)] * (mesh_vastai.MAX_PAGES + 1))

    def test_rejected_key_raises_rather_than_returning_no_peers(self):
        # An empty roster is a mesh with no peers. A 401 is a mesh with a wrong
        # key. Collapsing the second into the first is how a node silently
        # stops taking part.
        with pytest.raises(mesh_vastai.VastAPIError) as exc:
            self._fetch([_FakeVastResponse(401, {"error": "unauthorized"})])
        assert exc.value.status == 401

    def test_rate_limit_raises_and_is_not_retried(self):
        session = _FakeVastSession([_FakeVastResponse(429, {"error": "too frequent"})])
        with pytest.raises(mesh_vastai.VastAPIError) as exc:
            asyncio.run(mesh_vastai.fetch_instances(session))
        assert exc.value.status == 429
        assert len(session.calls) == 1  # retrying would add load to a refusal

    def test_timeout_propagates(self):
        with pytest.raises(asyncio.TimeoutError):
            self._fetch([asyncio.TimeoutError()])

    def test_unset_key_is_a_configuration_error(self, monkeypatch):
        monkeypatch.setattr(mesh_vastai, "API_KEY", "")
        with pytest.raises(mesh_vastai.VastConfigError):
            asyncio.run(mesh_vastai.load_vastai_peers())


class TestVastRosterCache:
    def _load(self, monkeypatch, calls):
        async def _fetch(session):
            calls.append(1)
            return [_instance()]

        monkeypatch.setattr(mesh_vastai, "API_KEY", "k")
        monkeypatch.setattr(mesh_vastai, "SELF_INSTANCE_ID", "999")
        monkeypatch.setattr(mesh_vastai, "fetch_instances", _fetch)
        return asyncio.run(mesh_vastai.load_vastai_peers())

    def test_second_read_inside_the_ttl_does_not_poll(self, monkeypatch):
        calls = []
        monkeypatch.setattr(mesh_vastai, "POLL_TTL_SECONDS", 30.0)
        self._load(monkeypatch, calls)
        self._load(monkeypatch, calls)
        assert len(calls) == 1

    def test_expired_ttl_polls_again(self, monkeypatch):
        calls = []
        monkeypatch.setattr(mesh_vastai, "POLL_TTL_SECONDS", 0.0)
        self._load(monkeypatch, calls)
        self._load(monkeypatch, calls)
        assert len(calls) == 2

    def test_a_failed_poll_does_not_populate_the_cache(self, monkeypatch):
        async def _boom(session):
            raise mesh_vastai.VastAPIError(500, "upstream")

        monkeypatch.setattr(mesh_vastai, "API_KEY", "k")
        monkeypatch.setattr(mesh_vastai, "fetch_instances", _boom)
        with pytest.raises(mesh_vastai.VastAPIError):
            asyncio.run(mesh_vastai.load_vastai_peers())
        assert mesh_vastai._roster_cache["expires"] == 0.0


class TestVastPeerSourceEndpoint:
    """The endpoint's contract with the vastai source."""

    def _use_vastai(self, monkeypatch):
        monkeypatch.setattr(mesh_mod, "PEER_SOURCE", "vastai")

        def _explode():
            raise AssertionError("vastai peering must not call Tailscale")

        monkeypatch.setattr(mesh_mod, "_tailscale_status", _explode)

    def _roster(self, monkeypatch, outcome):
        async def _load():
            if isinstance(outcome, BaseException):
                raise outcome
            return outcome

        monkeypatch.setattr(mesh_vastai, "load_vastai_peers", _load)

    def test_reports_its_own_source(self, monkeypatch, test_client):
        self._use_vastai(monkeypatch)
        self._roster(monkeypatch, _select([_instance()]))

        async def _fake_probe(session, peer, api_key):
            return mesh_mod._unprobed(peer, "online-idle")

        monkeypatch.setattr(mesh_mod, "probe_peer", _fake_probe)

        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 200
        body = r.json()
        assert body["peer_source"] == "vastai"
        assert body["peer_count"] == 1
        assert body["peers"][0]["api_port"] == 41287
        assert body["peers"][0]["litellm_port"] == 41288

    def test_a_wrong_roster_still_has_to_pass_the_probe(self, monkeypatch, test_client):
        # The API is not the trust boundary. An instance Vast reports as
        # running that does not answer is unreachable, not eligible.
        self._use_vastai(monkeypatch)
        self._roster(monkeypatch, _select([_instance()]))

        async def _refused(session, peer, api_key):
            return mesh_mod._unprobed(peer, "unreachable", "connection refused")

        monkeypatch.setattr(mesh_mod, "probe_peer", _refused)

        body = test_client.get("/api/mesh/peers",
                               headers=test_client.auth_headers).json()
        assert body["peer_count"] == 1
        assert body["idle_count"] == 0
        assert body["peers"][0]["state"] == "unreachable"

    def test_empty_roster_is_a_mesh_with_no_peers(self, monkeypatch, test_client):
        self._use_vastai(monkeypatch)
        self._roster(monkeypatch, [])
        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 200
        assert r.json()["peer_count"] == 0

    def test_rejected_key_is_not_an_empty_mesh(self, monkeypatch, test_client):
        self._use_vastai(monkeypatch)
        self._roster(monkeypatch, mesh_vastai.VastAPIError(401, "unauthorized"))
        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 502
        assert "ODS_VAST_API_KEY" in r.json()["detail"]

    def test_rate_limit_names_the_knob(self, monkeypatch, test_client):
        self._use_vastai(monkeypatch)
        self._roster(monkeypatch, mesh_vastai.VastAPIError(429, "too frequent"))
        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 502
        assert "MESH_VAST_POLL_TTL_SECONDS" in r.json()["detail"]

    def test_timeout_is_a_gateway_timeout(self, monkeypatch, test_client):
        self._use_vastai(monkeypatch)
        self._roster(monkeypatch, asyncio.TimeoutError())
        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 504

    def test_unconfigured_node_fails_loudly(self, monkeypatch, test_client):
        self._use_vastai(monkeypatch)
        self._roster(monkeypatch, mesh_vastai.VastConfigError("no key"))
        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 503

    def test_still_requires_auth(self, monkeypatch, test_client):
        # A discovery source must never be a way around the API key.
        self._use_vastai(monkeypatch)
        self._roster(monkeypatch, [])
        assert test_client.get("/api/mesh/peers").status_code in (401, 403)


class TestPeerSourceDispatch:
    """Adding a source must not have moved the existing ones."""

    def test_static_output_is_unchanged(self, monkeypatch, tmp_path, test_client):
        # Byte-for-byte, against the shape recorded before vastai existed.
        path = tmp_path / "mesh-peers.json"
        path.write_text(json.dumps({"peers": [
            {"hostname": "vast-a", "host": "203.0.113.10",
             "api_port": 41287, "litellm_port": 41288},
        ]}))
        monkeypatch.setattr(mesh_mod, "PEER_FILE", path)
        monkeypatch.setattr(mesh_mod, "PEER_SOURCE", "static")

        async def _fake_probe(session, peer, api_key):
            return mesh_mod._unprobed(peer, "online-idle")

        monkeypatch.setattr(mesh_mod, "probe_peer", _fake_probe)

        body = test_client.get("/api/mesh/peers",
                               headers=test_client.auth_headers).json()
        assert body == {
            "peers": [{
                "hostname": "vast-a",
                "dns_name": None,
                "address": "http://203.0.113.10:41287",
                "online": True,
                "last_seen": None,
                "state": "online-idle",
                "api_port": 41287,
                "litellm_port": 41288,
                "idle": None,
                "utilization_percent": None,
                "threshold_percent": None,
                "gpu": None,
                "loaded_model": None,
                "skills": [],
                "ods_version": None,
                "detail": None,
            }],
            "peer_count": 1,
            "idle_count": 1,
            "tailscale_running": True,
            "tailscale_authenticated": True,
            "peer_source": "static",
        }

    def test_tailscale_down_still_returns_an_empty_mesh(self, monkeypatch, test_client):
        monkeypatch.setattr(mesh_mod, "PEER_SOURCE", "tailscale")
        monkeypatch.setattr(mesh_mod, "_tailscale_status", lambda: {"running": False})
        body = test_client.get("/api/mesh/peers",
                               headers=test_client.auth_headers).json()
        assert body["tailscale_running"] is False
        assert body["tailscale_authenticated"] is False
        assert body["peers"] == []
        assert body["peer_source"] == "tailscale"

    def test_vastai_is_not_reachable_through_auto(self, monkeypatch, tmp_path,
                                                  test_client):
        # auto must not start calling an external API with an account
        # credential because a file happened to be missing.
        monkeypatch.setattr(mesh_mod, "PEER_FILE", tmp_path / "absent.json")
        monkeypatch.setattr(mesh_mod, "PEER_SOURCE", "auto")
        monkeypatch.setattr(mesh_mod, "_tailscale_status",
                            lambda: {"running": True, "authenticated": True, "peers": []})

        async def _explode():
            raise AssertionError("auto must not reach the vastai source")

        monkeypatch.setattr(mesh_vastai, "load_vastai_peers", _explode)

        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.json()["peer_source"] == "tailscale"

    def test_unknown_source_fails_loudly(self, monkeypatch, test_client):
        # A typo used to fall through to the tailnet, which is indistinguishable
        # from a working config until you read the peer list.
        monkeypatch.setattr(mesh_mod, "PEER_SOURCE", "vast-ai")
        r = test_client.get("/api/mesh/peers", headers=test_client.auth_headers)
        assert r.status_code == 503
        assert "vastai" in r.json()["detail"]
