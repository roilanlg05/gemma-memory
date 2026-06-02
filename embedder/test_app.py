"""Smoke test for the embedder. Run with:
    python3 -m pytest embedder/test_app.py -v
or inside the container:
    docker compose run --rm embedder python -m pytest test_app.py -v
Self-contained — no network requirement; uses FastAPI TestClient against the app."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi.testclient import TestClient
from app import app, EMBED_DIM

client = TestClient(app)


def test_healthz_returns_200():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_embed_returns_vectors_of_expected_dim():
    r = client.post("/embed", json={"texts": ["hola mundo", "hello world"]})
    assert r.status_code == 200
    data = r.json()
    assert "vectors" in data
    assert len(data["vectors"]) == 2
    assert all(len(v) == EMBED_DIM for v in data["vectors"])
    # Vectors must be non-trivial (not all zeros)
    assert any(abs(x) > 1e-6 for x in data["vectors"][0])


def test_embed_rejects_empty_texts():
    r = client.post("/embed", json={"texts": []})
    assert r.status_code == 400


def test_embed_es_en_similarity_is_high():
    """Cross-lingual sanity: 'hola mundo' and 'hello world' should be reasonably close."""
    r = client.post("/embed", json={"texts": ["hola mundo", "hello world"]})
    v1, v2 = r.json()["vectors"]
    # cosine similarity
    dot = sum(a*b for a, b in zip(v1, v2))
    n1 = sum(a*a for a in v1) ** 0.5
    n2 = sum(b*b for b in v2) ** 0.5
    cos = dot / (n1 * n2)
    assert cos > 0.5, f"expected ES↔EN cosine > 0.5, got {cos}"
