"""Voice gateway for the Gemma assistant. Chains STT -> the agent (/v1/agent/turn)
-> TTS, exposing POST /v1/voice/turn (audio in -> audio out). CPU-only; runs on the i3.
All audio processing lives here; devices are thin clients."""
import os
import time
from urllib.parse import quote

import httpx
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Response, UploadFile

# NOTE (Phase 1b): this is a single-user, turn-based home service, so the sync `httpx.post`
# in call_agent and the sync STT/TTS calls inside the async handler (which briefly block the
# event loop) are acceptable. For a future multi-user/concurrent phase, switch to httpx.AsyncClient
# and run the CPU-bound engine calls via run_in_threadpool.
AGENT_FALLBACK = "No pude contactar el cerebro ahora."
MEMORY_URL = os.environ.get("MEMORY_URL", "http://memory:8081")
MEMORY_BEARER = os.environ.get("MEMORY_BEARER_TOKEN", "")


def _make_stt():
    if os.environ.get("VOICE_FAKE_ENGINES") == "1":
        from engines import FakeSTT
        return FakeSTT()
    from engines import FasterWhisperSTT
    return FasterWhisperSTT(os.environ.get("WHISPER_MODEL", "small"))


def _make_tts():
    if os.environ.get("VOICE_FAKE_ENGINES") == "1":
        from engines import FakeTTS
        return FakeTTS()
    from engines import KokoroTTS
    return KokoroTTS(os.environ.get("KOKORO_VOICE", ""))


# Built once at import (engines load their models once); fakes when VOICE_FAKE_ENGINES=1.
_stt = _make_stt()
_tts = _make_tts()


def call_agent(text: str, thread_id: str, timezone: str | None, language: str | None = None) -> str:
    """POST to the Swift agent gateway and return its reply text. Raises on transport/HTTP error."""
    body = {"text": text, "threadId": thread_id}
    if timezone:
        body["timezone"] = timezone
    if language:  # STT-detected language -> agent pins the reply to the language the user spoke
        body["language"] = language
    headers = {"Authorization": f"Bearer {MEMORY_BEARER}", "Content-Type": "application/json"}
    r = httpx.post(f"{MEMORY_URL}/v1/agent/turn", json=body, headers=headers, timeout=180)
    r.raise_for_status()
    return r.json().get("reply", "")


def require_bearer(authorization: str = Header(default="")):
    # Read the token from live env on each call (fail-closed: unset token → always 401).
    expected = os.environ.get("VOICE_BEARER_TOKEN", "")
    if not expected or authorization != f"Bearer {expected}":
        raise HTTPException(status_code=401, detail="unauthorized")


app = FastAPI(title="Gemma Voice Gateway", version="1.0")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/v1/voice/turn", dependencies=[Depends(require_bearer)])
async def voice_turn(
    audio: UploadFile = File(...),
    threadId: str = Form(default="voice"),
    timezone: str | None = Form(default=None),
):
    wav = await audio.read()
    if not wav or len(wav) < 200:  # WAV header is 44 bytes; under 200 is never a real utterance
        raise HTTPException(status_code=400, detail="audio required")

    t0 = time.perf_counter()
    try:
        text, lang = _stt.transcribe(wav)
    except Exception as exc:  # STT failure
        raise HTTPException(status_code=502, detail=f"stt failed: {exc}")
    t_stt = time.perf_counter()

    if not text.strip():  # silence/noise -> client just re-listens
        return Response(status_code=400, headers={"X-STT-Text": ""})

    try:
        reply = call_agent(text, threadId, timezone, lang)
    except httpx.HTTPError:  # transport error or non-2xx from the agent
        reply = AGENT_FALLBACK  # agent unreachable -> speak the failure, still 200
    t_agent = time.perf_counter()

    try:
        out = _tts.synthesize(reply, lang)
        t_tts = time.perf_counter()
        print(f"[voice] timing: stt={t_stt-t0:.2f}s agent={t_agent-t_stt:.2f}s "
              f"tts={t_tts-t_agent:.2f}s total={t_tts-t0:.2f}s reply_chars={len(reply)}", flush=True)
    except Exception as exc:  # TTS failure -> 502, but surface the (unspoken) text
        print(f"[voice] tts failed: {exc!r}")  # full detail in the server log only
        return Response(
            status_code=502,
            # Header carries the exception TYPE, not the message (avoid leaking paths/model names).
            headers={"X-STT-Text": quote(text), "X-Reply-Text": quote(reply), "X-Error": f"tts: {type(exc).__name__}"},
        )

    return Response(
        content=out,
        media_type="audio/wav",
        headers={"X-STT-Text": quote(text), "X-Reply-Text": quote(reply)},
    )
