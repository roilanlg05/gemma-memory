"""Embedder sidecar for the Gemma memory service. Loads BAAI/bge-m3
on startup, serves /embed and /healthz. CPU-only; ~1GB RAM."""
import os
from typing import List
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer

MODEL_ID = os.environ.get("EMBED_MODEL", "BAAI/bge-m3")
# In Docker, EMBED_MODEL_CACHE=/models (a mounted volume). On host (tests / dev),
# leave it unset and SentenceTransformer falls back to ~/.cache/huggingface.
_cache_env = os.environ.get("EMBED_MODEL_CACHE")
CACHE_DIR = _cache_env if _cache_env else None
EMBED_DIM = 1024  # bge-m3 dense dim

# Load eagerly at import time so /healthz reflects readiness.
_model = SentenceTransformer(MODEL_ID, cache_folder=CACHE_DIR, device="cpu")


class EmbedRequest(BaseModel):
    texts: List[str]


class EmbedResponse(BaseModel):
    vectors: List[List[float]]


app = FastAPI(title="Gemma Memory Embedder", version="1.0")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/embed", response_model=EmbedResponse)
def embed(req: EmbedRequest):
    if not req.texts:
        raise HTTPException(status_code=400, detail="texts must be non-empty")
    vectors = _model.encode(req.texts, normalize_embeddings=True).tolist()
    return EmbedResponse(vectors=vectors)
