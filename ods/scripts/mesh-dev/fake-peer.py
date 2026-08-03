#!/usr/bin/env python3
"""A dependency-free stand-in for one DreamReason mesh peer.

Serves the three endpoints peer discovery composes -- /api/node/capabilities,
/api/gpu/idle -- plus an OpenAI-compatible /v1/chat/completions, so the mesh
pipeline can be exercised on hosts without Docker, a GPU, or model weights.

This is development scaffolding, not an extension. It mimics response SHAPES
only; it does no inference.

    python3 fake-peer.py --port 8081 --name mesh-peer-code --skill code

--behavior controls the failure mode under test. Peer states must stay
distinguishable downstream, so each behavior maps to a distinct observable
outcome rather than a generic error:

    ok      answer normally
    busy    healthy, but GPU reported as not idle
    hang    accept the connection and never respond (drives a client timeout)
"""

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Long enough that any sane client timeout fires first.
HANG_SECONDS = 3600


def build_capabilities(cfg):
    """Shape-compatible with dashboard-api NodeCapabilities."""
    return {
        "ods_version": cfg.ods_version,
        "gpu": {
            "gpu_backend": cfg.backend,
            "gpu_name": cfg.gpu_name,
            "gpu_count": 1,
            "vram_mb": cfg.vram_mb,
        },
        "loaded_model": cfg.model,
        "services": [],
        "service_count": 0,
        "running_service_count": 0,
        # Not in NodeCapabilities upstream; the mesh router reads it for
        # skill-level routing (Symbolic-MoE routes on skills, not tasks).
        "skills": cfg.skills,
    }


def build_gpu_idle(cfg):
    """Shape-compatible with dashboard-api GpuIdleStatus."""
    utilization = cfg.utilization if cfg.behavior != "busy" else 95
    return {
        "idle": utilization <= cfg.threshold,
        "utilization_percent": utilization,
        "threshold_percent": cfg.threshold,
        "backend": cfg.backend,
    }


def build_completion(cfg, prompt):
    """Minimal OpenAI chat.completion naming the peer that answered."""
    answer = f"[{cfg.name}/{cfg.skill}] answering: {prompt[:160]}"
    return {
        "id": f"chatcmpl-{cfg.name}-{int(time.time() * 1000)}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": cfg.model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": answer},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": len(prompt.split()),
            "completion_tokens": len(answer.split()),
            "total_tokens": len(prompt.split()) + len(answer.split()),
        },
    }


def extract_prompt(payload):
    messages = payload.get("messages", [])
    if not messages:
        return ""
    return messages[-1].get("content", "")


class PeerHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    cfg = None

    def log_message(self, fmt, *args):
        print(f"[{self.cfg.name}] {fmt % args}", flush=True)

    def _send(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.cfg.behavior == "hang":
            time.sleep(HANG_SECONDS)
            return
        routes = {
            "/health": lambda: {"status": "ok", "peer": self.cfg.name},
            "/api/node/capabilities": lambda: build_capabilities(self.cfg),
            "/api/gpu/idle": lambda: build_gpu_idle(self.cfg),
            "/v1/models": lambda: {
                "object": "list",
                "data": [{"id": self.cfg.model, "object": "model"}],
            },
        }
        handler = routes.get(self.path.split("?")[0])
        if handler is None:
            self._send(404, {"detail": "not found"})
            return
        self._send(200, handler())

    def do_POST(self):
        if self.cfg.behavior == "hang":
            time.sleep(HANG_SECONDS)
            return
        if self.path.split("?")[0] != "/v1/chat/completions":
            self._send(404, {"detail": "not found"})
            return
        length = int(self.headers.get("Content-Length", 0))
        payload = json.loads(self.rfile.read(length) or b"{}")
        time.sleep(self.cfg.latency_ms / 1000.0)
        self._send(200, build_completion(self.cfg, extract_prompt(payload)))


def parse_args():
    p = argparse.ArgumentParser(description="Fake DreamReason mesh peer")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--skill", required=True, help="primary skill, e.g. code")
    p.add_argument(
        "--skills",
        default="",
        help="comma-separated skills; defaults to --skill",
    )
    p.add_argument("--model", default="Qwen3.5-2B-Q4_K_M.gguf")
    p.add_argument("--backend", default="nvidia")
    p.add_argument("--gpu-name", default="Fake RTX 4090")
    p.add_argument("--vram-mb", type=int, default=24576)
    p.add_argument("--utilization", type=int, default=3)
    p.add_argument("--threshold", type=int, default=10)
    p.add_argument("--latency-ms", type=int, default=0)
    p.add_argument("--ods-version", default="2.6.0")
    p.add_argument(
        "--behavior",
        default="ok",
        choices=["ok", "busy", "hang"],
    )
    cfg = p.parse_args()
    cfg.skills = [s for s in (cfg.skills or cfg.skill).split(",") if s]
    return cfg


def main():
    cfg = parse_args()
    handler = type("BoundPeerHandler", (PeerHandler,), {"cfg": cfg})
    server = ThreadingHTTPServer(("127.0.0.1", cfg.port), handler)
    print(
        f"[{cfg.name}] listening on 127.0.0.1:{cfg.port} "
        f"skill={cfg.skill} behavior={cfg.behavior}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
