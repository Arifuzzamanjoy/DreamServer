"""DreamReason mesh — Vast.ai as the peer roster.

Instead of every node being told who its peers are, each node asks Vast.ai
which instances the account is running and derives the roster from that. That
removes the hand-edited ``config/mesh-peers.json`` step, which is the step that
breaks when an instance is preempted.

The output of this module is deliberately identical to what
``normalize_static_peer`` produces, so ``probe_peer`` and everything downstream
cannot tell the two sources apart. The API says who *might* be a peer; the
probe decides who actually is. A stale or wrong roster therefore degrades to
``unreachable``, never to a peer that gets dispatched work.

Scope, stated plainly: this discovers instances inside **one Vast.ai account**.
It is testbed scaffolding. It does not serve the volunteer-mesh premise, which
needs peer identity that does not come from a cloud vendor's billing API.

Security: the per-instance ``CONTAINER_API_KEY`` cannot enumerate siblings — it
only manages its own instance — so this needs an account-level key on the node.
See installers/p2p-gpu/research/vastai-discovery.md §4 and MESH.md.
"""

import logging
import os
import time
from typing import Optional

import aiohttp

logger = logging.getLogger(__name__)

API_URL = os.getenv("MESH_VAST_API_URL", "https://console.vast.ai/api/v1/instances/")
API_KEY = os.getenv("ODS_VAST_API_KEY", "")

# Only instances whose label starts with this join the mesh. It is what keeps
# unrelated rentals in the same account out. An empty prefix would match every
# instance on the account, so it is rejected rather than honoured.
LABEL_PREFIX = os.getenv("MESH_VAST_LABEL_PREFIX", "dreamreason-mesh")

# Vast reports a lot of states; only this one means "can take work".
RUNNING_STATUS = "running"

# The roster changes on the timescale of instance churn, not requests. 30s
# keeps a preempted node out of the routing table quickly without turning every
# dashboard poll into a Vast API call.
POLL_TTL_SECONDS = float(os.getenv("MESH_VAST_POLL_TTL_SECONDS", "30"))

REQUEST_TIMEOUT = aiohttp.ClientTimeout(
    total=float(os.getenv("MESH_VAST_TIMEOUT_SECONDS", "10"))
)

# Internal ports to resolve external mappings for. Both are required: a peer
# whose dashboard-api is reachable but whose LiteLLM is not would probe as
# online-idle and then be handed work it cannot serve.
INTERNAL_API_PORT = int(os.getenv("MESH_VAST_INTERNAL_API_PORT", "3002"))
INTERNAL_LITELLM_PORT = int(os.getenv("MESH_VAST_INTERNAL_LITELLM_PORT", "4000"))

# Vast injects the instance's own id as CONTAINER_ID. Overridable so the value
# can be set on a host that is not itself a Vast container.
SELF_INSTANCE_ID = os.getenv("MESH_VAST_SELF_INSTANCE_ID") or os.getenv("CONTAINER_ID", "")

# limit is documented as "default 25, max 25", so a roster larger than one page
# must be walked with the keyset cursor. Not paginating would show only the
# first 25 instances, and a missing node would look exactly like a node that
# was never rented.
PAGE_LIMIT = 25
MAX_PAGES = 40


class VastConfigError(Exception):
    """Vast discovery is selected but not configured to run."""


class VastAPIError(Exception):
    """Vast.ai answered, but not with a usable roster."""

    def __init__(self, status: int, detail: str):
        super().__init__(f"vast.ai API returned HTTP {status}: {detail}")
        self.status = status
        self.detail = detail


def external_port(instance: dict, internal_port: int) -> Optional[int]:
    """External TCP port Vast published for *internal_port*. Pure.

    The mapping is Docker-shaped and ``HostPort`` is a string::

        "ports": {"3002/tcp": [{"HostIp": "0.0.0.0", "HostPort": "41287"}]}

    Returns None when the port was never published. On Vast.ai ports must be
    requested when the instance is CREATED and cannot be opened afterwards, so
    that is the single most common mesh misconfiguration rather than a rare
    edge case.

    The v0 single-instance endpoint documents this field as a list of ints
    instead (see the research note). A non-mapping shape resolves to None, so a
    contract change skips the peer rather than inventing a port for it.
    """
    ports = instance.get("ports")
    if not isinstance(ports, dict):
        return None
    bindings = ports.get(f"{internal_port}/tcp")
    if not bindings:
        return None
    host_port = bindings[0].get("HostPort")
    if not host_port:
        return None
    return int(host_port)


def is_mesh_member(instance: dict, label_prefix: str, self_id: str) -> bool:
    """Whether *instance* is a peer this node should try to reach. Pure.

    Three independent reasons to say no: it is not running, it is somebody
    else's rental in the same account, or it is this node.
    """
    if instance.get("actual_status") != RUNNING_STATUS:
        return False
    if not str(instance.get("label") or "").startswith(label_prefix):
        return False
    return str(instance.get("id")) != str(self_id)


def normalize_vast_instance(instance: dict, api_port: int, litellm_port: int) -> dict:
    """One Vast instance in the shape probing expects. Pure.

    The same keys ``normalize_static_peer`` emits, and for the same reason:
    ``online`` is asserted rather than known, because the roster only says the
    instance is billed and running, not that ODS inside it is answering. Raises
    on an instance with no public address — Vast reported a peer nobody can
    address, which is a broken roster entry, not a peer.
    """
    host = instance.get("public_ipaddr")
    if not host:
        raise ValueError(f"vast instance {instance.get('id')!r} has no public_ipaddr")
    return {
        "hostname": instance.get("label") or f"vast-{instance.get('id')}",
        "dns_name": None,
        "ips": [host],
        "online": True,
        "last_seen": None,
        "api_port": api_port,
        "litellm_port": litellm_port,
    }


def select_mesh_peers(instances: list, label_prefix: str, self_id: str) -> list:
    """Roster entries that are usable peers, in the probe's shape.

    Impure only in that it logs. An instance that belongs to the mesh but never
    published 3002 or 4000 is dropped with a warning naming the port, because
    including it would produce a peer stuck at ``unreachable`` whose detail
    reads "connection refused" — which names the wrong cause and sends the
    operator looking at the network instead of at instance creation.
    """
    if not label_prefix:
        raise VastConfigError(
            "MESH_VAST_LABEL_PREFIX is empty, which would admit every instance "
            "on the account into the mesh."
        )
    if not self_id:
        logger.warning(
            "no CONTAINER_ID or MESH_VAST_SELF_INSTANCE_ID; this node cannot "
            "exclude itself from its own peer list"
        )

    peers = []
    for instance in instances:
        if not is_mesh_member(instance, label_prefix, self_id):
            continue
        api_port = external_port(instance, INTERNAL_API_PORT)
        litellm_port = external_port(instance, INTERNAL_LITELLM_PORT)
        if api_port is None or litellm_port is None:
            missing = INTERNAL_API_PORT if api_port is None else INTERNAL_LITELLM_PORT
            logger.warning(
                "vast instance %s (%s) publishes no external port for %s; "
                "ports must be requested at instance creation — skipping",
                instance.get("id"), instance.get("label"), missing,
            )
            continue
        peers.append(normalize_vast_instance(instance, api_port, litellm_port))
    return peers


async def _get_page(session: aiohttp.ClientSession, params: dict) -> dict:
    """One page of the instance roster.

    Auth and rate-limit failures raise. They are not retried and they do not
    resolve to an empty roster: an empty roster is a mesh with no peers, and a
    401 is a mesh whose key is wrong. Collapsing the second into the first is
    how a misconfigured node quietly stops doing any work.
    """
    headers = {"Authorization": f"Bearer {API_KEY}", "Accept": "application/json"}
    async with session.get(
        API_URL, params=params, headers=headers, timeout=REQUEST_TIMEOUT
    ) as resp:
        if resp.status >= 400:
            # Truncated: this ends up in an HTTP detail, and an error page can
            # be a whole document.
            raise VastAPIError(resp.status, (await resp.text())[:200])
        return await resp.json()


async def fetch_instances(session: aiohttp.ClientSession) -> list:
    """Every instance on the account, following the keyset cursor."""
    instances: list = []
    params = {"limit": str(PAGE_LIMIT)}
    for _ in range(MAX_PAGES):
        payload = await _get_page(session, params)
        instances.extend(payload.get("instances") or [])
        token = payload.get("next_token")
        if not token:
            return instances
        params = {"limit": str(PAGE_LIMIT), "after_token": token}
    # Either the account is larger than this walk allows or the cursor is not
    # advancing. Both are worth a stack trace; neither is worth a partial
    # roster presented as a whole one.
    raise VastAPIError(200, f"roster did not terminate within {MAX_PAGES} pages")


_roster_cache: dict = {"expires": 0.0, "peers": []}


def reset_cache() -> None:
    """Drop the cached roster. For tests and for a forced refresh."""
    _roster_cache.update({"expires": 0.0, "peers": []})


async def load_vastai_peers() -> list:
    """Mesh peers from the Vast.ai roster, cached for POLL_TTL_SECONDS.

    The cache is only written on success, so a failed poll surfaces as a
    failure on this call and is retried on the next one rather than being
    papered over with a stale answer.
    """
    if not API_KEY:
        raise VastConfigError(
            "MESH_PEER_SOURCE=vastai but ODS_VAST_API_KEY is not set."
        )

    now = time.monotonic()
    if now < _roster_cache["expires"]:
        return _roster_cache["peers"]

    async with aiohttp.ClientSession() as session:
        instances = await fetch_instances(session)

    peers = select_mesh_peers(instances, LABEL_PREFIX, SELF_INSTANCE_ID)
    _roster_cache.update({"expires": now + POLL_TTL_SECONDS, "peers": peers})
    logger.info(
        "vast.ai roster: %d instance(s), %d mesh peer(s) with prefix %r",
        len(instances), len(peers), LABEL_PREFIX,
    )
    return peers


__all__ = [
    "VastAPIError",
    "VastConfigError",
    "external_port",
    "fetch_instances",
    "is_mesh_member",
    "load_vastai_peers",
    "normalize_vast_instance",
    "reset_cache",
    "select_mesh_peers",
]
