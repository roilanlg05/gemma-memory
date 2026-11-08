"""Pruebas del servicio de navegador. Correr con:
    python3 -m pytest browser/test_app.py -v
Usa BROWSER_FAKE_CLI=1 para no lanzar el binario de verdad."""
import os, sys
os.environ["BROWSER_FAKE_CLI"] = "1"
os.environ["BROWSER_BEARER_TOKEN"] = "test-token"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi.testclient import TestClient
import app as appmod

client = TestClient(appmod.app)
AUTH = {"Authorization": "Bearer test-token"}


def test_healthz_no_pide_token():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_invoke_sin_token_devuelve_401():
    r = client.post("/v1/browser/invoke", json={"arguments": ["stream", "status"]})
    assert r.status_code == 401


def test_invoke_con_token_malo_devuelve_401():
    r = client.post("/v1/browser/invoke",
                    json={"arguments": ["stream", "status"]},
                    headers={"Authorization": "Bearer otro"})
    assert r.status_code == 401


def test_invoke_con_token_bueno_devuelve_501_hasta_la_tarea_2():
    r = client.post("/v1/browser/invoke",
                    json={"arguments": ["stream", "status"]}, headers=AUTH)
    assert r.status_code == 501
