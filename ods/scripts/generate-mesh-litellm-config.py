#!/usr/bin/env python3
"""Render config/litellm/mesh.yaml from /api/mesh/peers.

This is where the DreamReason mesh becomes real. Every ODS service already
talks to LiteLLM on :4000, so adding a peer here makes that peer reachable to
all of them at once -- no client changes, no new networking layer. The model
name is the routing key.

Two rules that are easy to get wrong:

* Peers are addressed at their **:4000** (their LiteLLM), never :8080 (their
  llama-server). Going straight to a peer's llama-server would bypass the
  gateway that owns auth, routing policy and observability. This is what
  ods-doctor's ODS-RUNTIME-MESH-LLM-LOCAL-ROUTE enforces.

* Models are named by **skill**, not hostname. Symbolic-MoE (arXiv 2503.05641)
  measures +8.15% absolute for skill-level over task-level expert selection,
  and hostnames carry no routing signal.

Only peers reporting ``online-idle`` are emitted: DreamReason is about
borrowing idle GPUs, and a busy peer would just add queueing latency.

Usage:
    python3 generate-mesh-litellm-config.py --peers-json peers.json -o mesh.yaml
    curl -s -H "Authorization: Bearer $KEY" localhost:3002/api/mesh/peers \
        | python3 generate-mesh-litellm-config.py -o config/litellm/mesh.yaml
"""

import argparse
import json
import sys
from urllib.parse import urlparse

import yaml

PEER_LITELLM_PORT = 4000
ELIGIBLE_STATE = "online-idle"


def peer_host(peer: dict) -> str:
    """Hostname/IP of a peer, from the dashboard-api address discovery returned."""
    address = peer.get("address") or ""
    host = urlparse(address).hostname
    if host:
        return host
    raise ValueError(f"peer {peer.get('hostname')!r} has no usable address")


def peer_litellm_port(peer: dict) -> int:
    """Port of *peer*'s LiteLLM. Pure.

    Defaults to 4000, which holds on a tailnet where every node is identical.
    Providers that remap ports must say so per peer: on Vast.ai the external
    port is published as VAST_TCP_PORT_4000 and is not 4000.
    """
    return int(peer.get("litellm_port") or PEER_LITELLM_PORT)


def peer_entries(peer: dict, peer_key_env: str) -> list:
    """One LiteLLM model_list entry per skill this peer advertises.

    Several peers may advertise the same skill; LiteLLM treats duplicate
    model_name entries as a load-balancing group, which is what we want.
    """
    host = peer_host(peer)
    api_base = f"http://{host}:{peer_litellm_port(peer)}/v1"
    upstream = peer.get("loaded_model") or "default"
    entries = []
    for skill in peer.get("skills") or []:
        entries.append({
            "model_name": f"peer-{skill}",
            "litellm_params": {
                "model": f"openai/{upstream}",
                "api_base": api_base,
                "api_key": peer_key_env,
            },
            "model_info": {
                "ods_peer": peer.get("hostname"),
                "ods_skill": skill,
            },
        })
    return entries


def build_mesh_config(peers: list, local_api_base: str, peer_key_env: str) -> dict:
    """Full LiteLLM config for mesh mode. Pure.

    Always includes this node's own llama-server. A mesh node runs local
    inference and contributes compute -- it is not a thin client
    (ODS-RUNTIME-MESH-LOCAL-OVERLAY-MISSING).
    """
    model_list = [
        {
            "model_name": "local",
            "litellm_params": {
                "model": "openai/default",
                "api_base": local_api_base,
                "api_key": "not-needed",
            },
        },
        {
            "model_name": "default",
            "litellm_params": {
                "model": "openai/default",
                "api_base": local_api_base,
                "api_key": "not-needed",
            },
        },
    ]
    for peer in peers:
        if peer.get("state") == ELIGIBLE_STATE:
            model_list.extend(peer_entries(peer, peer_key_env))

    return {
        "model_list": model_list,
        "general_settings": {"master_key": "os.environ/LITELLM_MASTER_KEY"},
        "litellm_settings": {
            "drop_params": True,
            "set_verbose": False,
            "request_timeout": 120,
            "stream_timeout": 60,
        },
    }


def load_peers(source) -> list:
    payload = json.load(source)
    peers = payload.get("peers")
    if not isinstance(peers, list):
        raise ValueError("payload has no 'peers' list")
    return peers


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--peers-json", help="file with /api/mesh/peers output; default stdin")
    p.add_argument("-o", "--output", required=True)
    p.add_argument("--local-api-base", default="http://llama-server:8080/v1")
    p.add_argument("--peer-key-env", default="os.environ/MESH_PEER_KEY")
    args = p.parse_args()

    if args.peers_json:
        with open(args.peers_json) as fh:
            peers = load_peers(fh)
    else:
        peers = load_peers(sys.stdin)

    config = build_mesh_config(peers, args.local_api_base, args.peer_key_env)
    with open(args.output, "w") as fh:
        yaml.dump(config, fh, default_flow_style=False, sort_keys=False)

    eligible = sum(1 for peer in peers if peer.get("state") == ELIGIBLE_STATE)
    print(f"wrote {args.output}: {eligible}/{len(peers)} peers eligible, "
          f"{len(config['model_list'])} model entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
