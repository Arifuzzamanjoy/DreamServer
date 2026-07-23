# TEI Reranker

Cross-encoder reranker powered by [Text Embeddings Inference](https://github.com/huggingface/text-embeddings-inference). It re-scores the top candidates returned by vector search so the most relevant chunks are passed to the model, which measurably improves RAG answer quality.

## Requirements

- **GPU:** Optional (runs on CPU; NVIDIA/AMD/Apple accelerate it)
- **Dependencies:** None. Pairs naturally with `embeddings` + `qdrant`.

## Enable / Disable

```bash
ods enable reranker
ods disable reranker
```

Your data is preserved when disabling. To re-enable later: `ods enable reranker`

## Access

- **URL:** `http://localhost:8091`
- **Model:** `BAAI/bge-reranker-base` by default. Override with `RERANKER_MODEL` in `.env`.

## First-Time Setup

1. Enable the service: `ods enable reranker`
2. Rerank a query against candidate passages:

```bash
curl -X POST http://localhost:8091/rerank \
  -H "Content-Type: application/json" \
  -d '{"query": "what is ODS?", "texts": ["ODS is a local AI stack", "unrelated text"]}'
```

The response returns each passage with a relevance score, highest first.
