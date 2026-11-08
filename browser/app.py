"""Pasarela del navegador del agente. Es dueña del CLI `agent-browser` (y de su
Chromium) en el i3; la app de macOS lo invoca por HTTP en vez de lanzarlo en local.
/v1/browser/invoke valida el argv y lo ejecuta vía cli.py; el WebSocket de
streaming llega en la Tarea 4."""
import os
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field, StringConstraints

import cli

# Ruta del CLI (la misma que usa cli.py para lanzar el proceso).
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


class InvokeBody(BaseModel):
    # Topes: un cuerpo sin límite crecería sin freno en el servidor.
    arguments: list[Annotated[str, StringConstraints(max_length=8192)]] = Field(max_length=64)
    timeout: float = Field(default=30, gt=0, le=300)
    # Va al stdin del proceso, nunca a argv: `ps` lee el argv de cualquier proceso.
    stdin: str | None = Field(default=None, max_length=262144)


@app.post("/v1/browser/invoke", dependencies=[Depends(require_bearer)])
async def browser_invoke(body: InvokeBody):
    try:
        cli.validate(body.arguments, body.stdin)
    except ValueError as motivo:
        raise HTTPException(status_code=400, detail=str(motivo))
    return await cli.run(body.arguments, timeout=body.timeout, stdin=body.stdin)
