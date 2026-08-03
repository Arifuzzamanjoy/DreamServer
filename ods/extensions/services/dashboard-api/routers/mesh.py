"""DreamReason mesh — peer discovery.

Composes two endpoints that already exist on every ODS node:

  * ``/api/node/capabilities`` — what the peer is (GPU, loaded model, version)
  * ``/api/gpu/idle``         — whether the peer can take work right now

Tailscale supplies the peer list; this module fans out to each online peer and
merges both answers into one :class:`MeshPeer`.

Peer states stay distinct. A peer that refuses the connection, one that accepts
and then goes silent, and one that rejects the API key are three different
operational problems, so each maps to its own state rather than being swallowed
into a null. Only narrow, per-transport exceptions are caught, and every one of
them resolves to a specific, meaningful state.
"""

import asyncio
import logging
import os
from typing import Optional

import aiohttp
from fastapi import APIRouter, Depends, HTTPException

from host_agent_client import (
    AgentHTTPError,
    AgentProtocolError,
    AgentTimeout,
    AgentUnavailable,
    request_json as request_agent_json,
)
from models import MeshPeer, MeshPeerList
from security import verify_api_key

logger = logging.getLogger(__name__)

router = APIRouter(tags=["mesh"])

# A peer runs the same dashboard-api as this node, on the same port.
PEER_API_PORT = int(os.getenv("MESH_PEER_API_PORT", "3002"))
PEER_PROBE_TIMEOUT = aiohttp.ClientTimeout(
    total=float(os.getenv("MESH_PEER_TIMEOUT_SECONDS", "5"))
)


def peer_base_url(peer: dict) -> Optional[str]:
    """First Tailscale IP of *peer* as a dashboard-api base URL.

    Prefers the IP over the MagicDNS name: discovery must keep working when
    MagicDNS is disabled on the tailnet.
    """
    ips = peer.get("ips") or []
    if not ips:
        return None
    return f"http://{ips[0]}:{PEER_API_PORT}"


def parse_peers(status: dict) -> list:
    """Peer list out of the host-agent Tailscale payload.

    Pure. The host agent distils `tailscale status --json` into a `peers` key;
    older agents predate it, in which case there is simply nothing to discover.
    """
    peers = status.get("peers")
    if not isinstance(peers, list):
        return []
    return peers


def _merge_probe(peer: dict, capabilities: dict, idle: dict) -> MeshPeer:
    """Build a MeshPeer from two successful probe responses. Pure."""
    is_idle = idle.get("idle")
    gpu = capabilities.get("gpu") or None
    return MeshPeer(
        hostname=peer.get("hostname"),
        dns_name=peer.get("dns_name"),
        address=peer_base_url(peer),
        online=True,
        last_seen=peer.get("last_seen"),
        state="online-idle" if is_idle else "online-busy",
        idle=is_idle,
        utilization_percent=idle.get("utilization_percent"),
        threshold_percent=idle.get("threshold_percent"),
        gpu=gpu,
        loaded_model=capabilities.get("loaded_model"),
        skills=capabilities.get("skills") or [],
        ods_version=capabilities.get("ods_version"),
    )


def _unprobed(peer: dict, state: str, detail: Optional[str] = None) -> MeshPeer:
    """A MeshPeer carrying a discovery failure or an offline peer. Pure."""
    return MeshPeer(
        hostname=peer.get("hostname"),
        dns_name=peer.get("dns_name"),
        address=peer_base_url(peer),
        online=peer.get("online", False),
        last_seen=peer.get("last_seen"),
        state=state,
        detail=detail,
    )


async def _get_json(session: aiohttp.ClientSession, url: str, headers: dict) -> dict:
    """GET *url* expecting JSON. Raises PeerHTTPStatus on a non-2xx answer."""
    async with session.get(url, headers=headers, timeout=PEER_PROBE_TIMEOUT) as resp:
        if resp.status >= 400:
            raise PeerHTTPStatus(resp.status)
        return await resp.json()


class PeerHTTPStatus(Exception):
    """A peer answered, but with a non-2xx status."""

    def __init__(self, status: int):
        super().__init__(f"peer returned HTTP {status}")
        self.status = status


async def probe_peer(session: aiohttp.ClientSession, peer: dict, api_key: str) -> MeshPeer:
    """Fetch capabilities and idle state from one peer.

    Each caught exception maps to exactly one distinct, meaningful state.
    Nothing is swallowed: an unreachable peer is not the same as a slow one.
    """
    if not peer.get("online", False):
        return _unprobed(peer, "offline")

    base = peer_base_url(peer)
    if base is None:
        return _unprobed(peer, "unreachable", "peer has no Tailscale IP")

    headers = {"X-API-Key": api_key} if api_key else {}
    try:
        capabilities, idle = await asyncio.gather(
            _get_json(session, f"{base}/api/node/capabilities", headers),
            _get_json(session, f"{base}/api/gpu/idle", headers),
        )
    except asyncio.TimeoutError:
        return _unprobed(peer, "timed-out", f"no response within {PEER_PROBE_TIMEOUT.total}s")
    except aiohttp.ClientConnectorError as exc:
        return _unprobed(peer, "unreachable", str(exc))
    except PeerHTTPStatus as exc:
        if exc.status in (401, 403):
            return _unprobed(peer, "unauthorized", str(exc))
        return _unprobed(peer, "error", str(exc))
    except (aiohttp.ClientError, OSError) as exc:
        return _unprobed(peer, "unreachable", str(exc))

    return _merge_probe(peer, capabilities, idle)


def _tailscale_status() -> dict:
    """Tailscale state from the host agent. Mirrors routers/tailscale.py."""
    try:
        return request_agent_json("GET", "/v1/tailscale/status", timeout=15)
    except AgentHTTPError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail) from exc
    except AgentTimeout as exc:
        raise HTTPException(status_code=504, detail="ODS host agent request timed out.") from exc
    except AgentUnavailable as exc:
        raise HTTPException(status_code=503, detail="ODS host agent is not reachable.") from exc
    except AgentProtocolError as exc:
        logger.exception("host-agent tailscale status failed")
        raise HTTPException(status_code=500, detail=f"Host agent call failed: {exc}") from exc


@router.get(
    "/api/mesh/peers",
    response_model=MeshPeerList,
    dependencies=[Depends(verify_api_key)],
)
async def mesh_peers() -> MeshPeerList:
    """Every Tailscale peer, with live capability and idle state.

    Read-only. Offline peers are listed but never probed. Peers are returned
    even when discovery fails against them, carrying the reason in ``state``
    and ``detail`` — a mesh with an unreachable node is a fact worth
    reporting, not an error worth raising.
    """
    status = await asyncio.to_thread(_tailscale_status)
    if not status.get("running", False):
        return MeshPeerList(tailscale_running=False, tailscale_authenticated=False)

    peers = parse_peers(status)
    api_key = os.getenv("MESH_PEER_API_KEY", "") or os.getenv("DASHBOARD_API_KEY", "")

    async with aiohttp.ClientSession() as session:
        probed = await asyncio.gather(
            *(probe_peer(session, peer, api_key) for peer in peers)
        )

    return MeshPeerList(
        peers=list(probed),
        peer_count=len(probed),
        idle_count=sum(1 for p in probed if p.state == "online-idle"),
        tailscale_running=True,
        tailscale_authenticated=bool(status.get("authenticated", False)),
    )
