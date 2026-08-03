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
