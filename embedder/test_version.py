"""Exercise the sidecar's wire identity without loading any model weights."""
import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient


def test_embed_labels_the_exact_loaded_version(monkeypatch):
    calls = []

    class FakeModel:
        def __init__(self, model_id, **options):
            calls.append((model_id, options))

        def get_sentence_embedding_dimension(self):
            return 3

        def encode(self, texts, *, normalize_embeddings):
            assert normalize_embeddings
            return SimpleNamespace(tolist=lambda: [[1.0, 0.0, 0.0] for _ in texts])

    model_id = "fixture/embedding-model"
    revision = "a" * 40
    monkeypatch.setenv("EMBED_MODEL", model_id)
    monkeypatch.setenv("EMBED_MODEL_REVISION", revision)
    monkeypatch.setitem(sys.modules, "sentence_transformers", SimpleNamespace(SentenceTransformer=FakeModel))
    spec = importlib.util.spec_from_file_location("fixture_embedder", Path(__file__).with_name("app.py"))
    sidecar = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sidecar)

    with TestClient(sidecar.app) as client:
        response = client.post("/embed", json={"texts": ["hello"]})

    assert response.status_code == 200
    assert calls[0][0] == model_id
    assert calls[0][1]["revision"] == revision
    assert response.json() == {
        "version": {"modelID": model_id, "dimension": 3, "revision": revision},
        "vectors": [[1.0, 0.0, 0.0]],
    }


def test_mutable_revision_is_rejected_before_loading_weights(monkeypatch):
    def unexpected_model_load(*args, **kwargs):
        pytest.fail("Sidecar tried to load weights for an unpinned revision")

    monkeypatch.setenv("EMBED_MODEL_REVISION", "main")
    monkeypatch.setitem(sys.modules, "sentence_transformers", SimpleNamespace(SentenceTransformer=unexpected_model_load))
    spec = importlib.util.spec_from_file_location("fixture_embedder", Path(__file__).with_name("app.py"))
    sidecar = importlib.util.module_from_spec(spec)
    with pytest.raises(ValueError, match="full model commit hash"):
        spec.loader.exec_module(sidecar)
