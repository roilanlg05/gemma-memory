"""Pasarela del navegador del agente. Es dueña del CLI `agent-browser` (y de su
Chromium) en el i3; la app de macOS lo invoca por HTTP en vez de lanzarlo en local.
Esta tarea entrega el esqueleto autenticado: el cuerpo de /v1/browser/invoke llega
en la Tarea 2 y el WebSocket de streaming en la Tarea 4."""
import os

from fastapi import Depends, FastAPI, Header, HTTPException

# Ruta del CLI; la Tarea 2 lo usa para lanzar el proceso.
BROWSER_BIN = os.environ.get("AGENT_BROWSER_BIN", "agent-browser")


def require_bearer(authorization: str = Header(default="")) -> None:
    # Se lee el token del entorno en cada llamada (falla cerrado: sin token → siempre 401).
    expected = os.environ.get("BROWSER_BEARER_TOKEN", "")
    if not expected or authorization != f"Bearer {expected}":
        raise HTTPException(status_code=401, detail="unauthorized")


app = FastAPI(title="Gemma Browser Gateway", version="1.0")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/v1/browser/invoke", dependencies=[Depends(require_bearer)])
def browser_invoke():
    # Temporal: la Tarea 2 implementa la invocación del CLI.
    raise HTTPException(status_code=501, detail="not implemented")
