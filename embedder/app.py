"""Embedder sidecar for the Gemma memory service. Loads BAAI/bge-m3
on startup, serves /embed and /healthz. CPU-only; ~1GB RAM."""
import os
import re
from typing import List
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer

DEFAULT_MODEL_ID = "BAAI/bge-m3"
DEFAULT_MODEL_REVISION = "5617a9f61b028005a4858fdac845db406aefb181"
MODEL_ID = os.environ.get("EMBED_MODEL", DEFAULT_MODEL_ID)
MODEL_REVISION = os.environ.get("EMBED_MODEL_REVISION", DEFAULT_MODEL_REVISION if MODEL_ID == DEFAULT_MODEL_ID else "")
if not re.fullmatch(r"[0-9a-f]{40}", MODEL_REVISION):
    raise ValueError("EMBED_MODEL_REVISION must be the full model commit hash")
# In Docker, EMBED_MODEL_CACHE=/models (a mounted volume). On host (tests / dev),
# leave it unset and SentenceTransformer falls back to ~/.cache/huggingface.
_cache_env = os.environ.get("EMBED_MODEL_CACHE")
CACHE_DIR = _cache_env if _cache_env else None
# Load eagerly at import time so /healthz reflects readiness.
_model = SentenceTransformer(MODEL_ID, revision=MODEL_REVISION, cache_folder=CACHE_DIR, device="cpu")
EMBED_DIM = _model.get_sentence_embedding_dimension()
if not EMBED_DIM:
    raise ValueError("Embedding model must declare its output dimension")


class EmbedRequest(BaseModel):
    texts: List[str]


class EmbedVersion(BaseModel):
    modelID: str
    dimension: int
    revision: str


class EmbedResponse(BaseModel):
    version: EmbedVersion
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
    version = EmbedVersion(modelID=MODEL_ID, dimension=EMBED_DIM, revision=MODEL_REVISION)
    return EmbedResponse(version=version, vectors=vectors)
