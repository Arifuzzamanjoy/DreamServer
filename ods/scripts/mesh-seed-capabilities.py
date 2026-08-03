#!/usr/bin/env python3
"""Seed Qdrant with skill capability vectors for semantic routing.

Embeds each skill's exemplar phrasings via TEI and upserts them into the
capability collection. Run once after enabling embeddings and qdrant, and again
whenever CAPABILITY_EXEMPLARS changes.

    python3 scripts/mesh-seed-capabilities.py \
        --tei http://localhost:8081 --qdrant http://localhost:6333
"""

import argparse
import sys
from pathlib import Path

import httpx

APP = (Path(__file__).resolve().parent.parent
       / "extensions" / "services" / "dreamreason" / "app")
sys.path.insert(0, str(APP))

from semantic_router import COLLECTION, exemplar_points  # noqa: E402


def embed(tei: str, texts: list, timeout: float) -> list:
    """Embed via TEI. Lets failures crash: seeding is an operator action and a
    half-seeded collection routes silently wrong."""
    resp = httpx.post(f"{tei}/embed", json={"inputs": texts}, timeout=timeout)
    resp.raise_for_status()
    return resp.json()


def recreate_collection(qdrant: str, size: int, timeout: float):
    httpx.delete(f"{qdrant}/collections/{COLLECTION}", timeout=timeout)
    resp = httpx.put(
        f"{qdrant}/collections/{COLLECTION}",
        json={"vectors": {"size": size, "distance": "Cosine"}},
        timeout=timeout,
    )
    resp.raise_for_status()


def upsert(qdrant: str, points: list, vectors: list, timeout: float):
    payload = {
        "points": [
            {"id": point["id"],
             "vector": vector,
             "payload": {"skill": point["skill"], "text": point["text"]}}
            for point, vector in zip(points, vectors)
        ]
    }
    resp = httpx.put(f"{qdrant}/collections/{COLLECTION}/points?wait=true",
                     json=payload, timeout=timeout)
    resp.raise_for_status()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--tei", default="http://localhost:8081")
    p.add_argument("--qdrant", default="http://localhost:6333")
    p.add_argument("--timeout", type=float, default=60.0)
    args = p.parse_args()

    points = exemplar_points()
    vectors = embed(args.tei, [pt["text"] for pt in points], args.timeout)
    recreate_collection(args.qdrant, len(vectors[0]), args.timeout)
    upsert(args.qdrant, points, vectors, args.timeout)

    skills = sorted({pt["skill"] for pt in points})
    print(f"seeded {len(points)} exemplars across {len(skills)} skills "
          f"into '{COLLECTION}' (dim={len(vectors[0])})")
    print(f"skills: {', '.join(skills)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
