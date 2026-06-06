"""Voice gateway for the Gemma assistant. Chains STT -> the agent (/v1/agent/turn)
-> TTS, exposing POST /v1/voice/turn (audio in -> audio out). CPU-only; runs on the i3.
All audio processing lives here; devices are thin clients."""
import os
from fastapi import FastAPI

app = FastAPI(title="Gemma Voice Gateway", version="1.0")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}
