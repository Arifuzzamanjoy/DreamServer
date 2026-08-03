#!/usr/bin/env python3
"""Contract: config/litellm/mesh.yaml generation and mesh config selection.

Two rules carry the mesh architecture and are easy to regress:
  1. peers are addressed at :4000 (their LiteLLM), never :8080
  2. mesh mode owns its routing -- the switchboard must not override it
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

ODS_ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ODS_ROOT / "scripts" / "generate-mesh-litellm-config.py"
SELECTOR = ODS_ROOT / "extensions" / "services" / "litellm" / "select-config.sh"

_spec = importlib.util.spec_from_file_location("mesh_cfg", GENERATOR)
mesh_cfg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mesh_cfg)

FAILURES = []


def check(label, condition):
    if condition:
        print(f"[PASS] {label}")
    else:
        print(f"[FAIL] {label}")
        FAILURES.append(label)


def peer(hostname="peer-a", host="100.64.0.2", skills=("code",),
         state="online-idle", model="qwen2.5-coder"):
    return {
        "hostname": hostname,
        "address": f"http://{host}:3002",
        "state": state,
        "skills": list(skills),
        "loaded_model": model,
    }


def by_name(config):
    result = {}
    for entry in config["model_list"]:
        result.setdefault(entry["model_name"], []).append(entry)
    return result


def test_peers_addressed_at_litellm_port():
    config = mesh_cfg.build_mesh_config([peer()], "http://llama-server:8080/v1", "k")
    entry = by_name(config)["peer-code"][0]
    base = entry["litellm_params"]["api_base"]
    check("peer addressed at :4000, not :8080", base == "http://100.64.0.2:4000/v1")
    check("no peer entry points at a raw llama-server port",
          all(":8080" not in e["litellm_params"]["api_base"]
              for e in config["model_list"]
              if e["model_name"].startswith("peer-")))


def test_named_by_skill_not_hostname():
    config = mesh_cfg.build_mesh_config(
        [peer(skills=("algebra", "geometry"))], "http://llama-server:8080/v1", "k")
    names = by_name(config)
    check("one model per skill", "peer-algebra" in names and "peer-geometry" in names)
    check("hostname is not a model name",
          not any(n.endswith("peer-a") for n in names))


def test_only_idle_peers_are_eligible():
    peers = [
        peer("a", "100.64.0.2", ("code",), "online-idle"),
        peer("b", "100.64.0.3", ("reasoning",), "online-busy"),
        peer("c", "100.64.0.4", ("logic",), "unreachable"),
        peer("d", "100.64.0.5", ("math",), "timed-out"),
    ]
    names = by_name(mesh_cfg.build_mesh_config(peers, "http://llama-server:8080/v1", "k"))
    check("idle peer included", "peer-code" in names)
    check("busy peer excluded", "peer-reasoning" not in names)
    check("unreachable peer excluded", "peer-logic" not in names)
    check("timed-out peer excluded", "peer-math" not in names)


def test_local_inference_always_present():
    # A mesh node contributes compute; it is not a thin client.
    names = by_name(mesh_cfg.build_mesh_config([], "http://llama-server:8080/v1", "k"))
    check("local entry present with no peers", "local" in names)
    check("default entry present with no peers", "default" in names)


def test_shared_skill_forms_a_load_balancing_group():
    peers = [peer("a", "100.64.0.2", ("code",)), peer("b", "100.64.0.3", ("code",))]
    entries = by_name(mesh_cfg.build_mesh_config(peers, "http://x:8080/v1", "k"))["peer-code"]
    bases = {e["litellm_params"]["api_base"] for e in entries}
    check("two peers share one model_name", len(entries) == 2)
    check("group spans distinct hosts", len(bases) == 2)


def test_peer_without_address_is_rejected_loudly():
    broken = {"hostname": "x", "address": "", "state": "online-idle", "skills": ["code"]}
    try:
        mesh_cfg.build_mesh_config([broken], "http://x:8080/v1", "k")
    except ValueError:
        check("unaddressable peer raises rather than emitting a broken route", True)
        return
    check("unaddressable peer raises rather than emitting a broken route", False)


def select(mode, switchboard):
    return subprocess.run(
        ["sh", str(SELECTOR), "/app/config.yaml", "/app/switchboard.yaml"],
        env={"ODS_MODE": mode, "ODS_MODEL_SWITCHBOARD": switchboard, "PATH": "/usr/bin:/bin"},
        capture_output=True, text=True, check=True,
    ).stdout.strip()


def test_mesh_routing_is_authoritative():
    check("mesh ignores switchboard", select("mesh", "enabled") == "/app/config.yaml")
    check("cloud ignores switchboard", select("cloud", "enabled") == "/app/config.yaml")
    check("local still honours switchboard",
          select("local", "enabled") == "/app/switchboard.yaml")
    check("hybrid still honours switchboard",
          select("hybrid", "enabled") == "/app/switchboard.yaml")
    check("mesh without switchboard uses mode config",
          select("mesh", "observe") == "/app/config.yaml")


def main():
    print("=== Mesh LiteLLM config contract ===")
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\n[OK] mesh LiteLLM config contract holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
