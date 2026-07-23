# Low-VRAM and Low-RAM Tuning

ODS is meant to run on the machine you already own — a $200 laptop with no GPU
just as much as a 96GB workstation. This guide collects the knobs that let a
constrained machine hold a usable context window and stay inside its memory
budget. Everything here is opt-in; the defaults are unchanged.

All settings go in your `.env` (see `.env.example` for the annotated list).

## The knobs, at a glance

| Setting | Default | Low-VRAM value | Effect |
|---|---|---|---|
| `CTX_SIZE` | `16384` | `8192` or `4096` | Smaller context uses less KV-cache memory. |
| `LLAMA_ARG_CACHE_TYPE_K` | `f16` | `q8_0` | Quantizes the KV cache keys — roughly halves KV memory. |
| `LLAMA_ARG_CACHE_TYPE_V` | `f16` | `q8_0` | Quantizes the KV cache values — the other half. |
| `LLAMA_ARG_FLASH_ATTN` | `auto` | `on` | Flash attention; needed for quantized V-cache on CUDA/Metal/SYCL. |
| `LLAMA_SERVER_MEMORY_LIMIT` | `6G` | `4G` | Hard cap on the llama-server container (CPU overlay). |
| `EMBEDDING_MODEL` | `BAAI/bge-base-en-v1.5` | `BAAI/bge-small-en-v1.5` | Smaller embedding model for RAG on tight RAM. |

## KV cache quantization

The KV cache is where most of the "context costs VRAM" pressure comes from.
Quantizing it to `q8_0` roughly halves that cost for a negligible quality
change — `q8_0` is close to lossless in practice, which lets a low-VRAM machine
either hold a longer context or simply fit the model it could not before.

```dotenv
LLAMA_ARG_CACHE_TYPE_K=q8_0
LLAMA_ARG_CACHE_TYPE_V=q8_0
LLAMA_ARG_FLASH_ATTN=on
```

Note: a quantized **value** cache (`CACHE_TYPE_V`) requires flash attention on
CUDA/Metal/SYCL, so set `LLAMA_ARG_FLASH_ATTN=on` when you quantize V. If you
only quantize K you can leave flash attention on `auto`.

## Context size

Context memory scales with `CTX_SIZE`. If you are memory-bound before you are
quality-bound, drop it:

```dotenv
CTX_SIZE=8192
```

4096 is a reasonable floor for chat; long-document RAG benefits from more, which
is exactly where KV quantization earns its keep.

## Container memory limit

On the CPU overlay the llama-server container is capped by
`LLAMA_SERVER_MEMORY_LIMIT`. Lower it so the service fits alongside the rest of
the stack on a small machine:

```dotenv
LLAMA_SERVER_MEMORY_LIMIT=4G
```

## The Tier 0 overlay

For machines under 8GB RAM, ODS ships `docker-compose.tier0.yml`, which reduces
memory limits and reservations across the core services. It layers on top of the
base + GPU/CPU overlay:

```bash
docker compose -f docker-compose.base.yml -f docker-compose.cpu.yml -f docker-compose.tier0.yml up -d
```

## Lighter embeddings for RAG

The default embedding model, `BAAI/bge-base-en-v1.5`, is a good balance. On a
memory-tight machine a smaller model keeps RAG working with less RAM:

```dotenv
EMBEDDING_MODEL=BAAI/bge-small-en-v1.5
```

Changing the embedding model requires reindexing existing knowledge bases; see
[MODEL-MANAGEMENT.md](MODEL-MANAGEMENT.md).

## Example: 8GB laptop, no GPU

```dotenv
CTX_SIZE=8192
LLAMA_ARG_CACHE_TYPE_K=q8_0
LLAMA_ARG_CACHE_TYPE_V=q8_0
LLAMA_ARG_FLASH_ATTN=on
LLAMA_SERVER_MEMORY_LIMIT=4G
EMBEDDING_MODEL=BAAI/bge-small-en-v1.5
```

Bring the stack up with the CPU and Tier 0 overlays as shown above.

## Related

- [HARDWARE-GUIDE.md](HARDWARE-GUIDE.md) — hardware tiers and what runs where
- [MODEL-MANAGEMENT.md](MODEL-MANAGEMENT.md) — choosing and switching models
- [PROFILES.md](PROFILES.md) — service profiles
