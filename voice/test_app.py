"""Voice gateway tests. Run with:
    python3 -m pytest voice/test_app.py -v
Uses fake engines (VOICE_FAKE_ENGINES=1) so no models load."""
import os, sys
os.environ["VOICE_FAKE_ENGINES"] = "1"
os.environ["VOICE_BEARER_TOKEN"] = "test-token"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi.testclient import TestClient
import app as appmod

client = TestClient(appmod.app)


def test_healthz_returns_200():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}
