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


from engines import FakeSTT, FasterWhisperSTT  # noqa: E402


def test_fake_stt_returns_configured_text():
    stt = FakeSTT(text="hola mundo", lang="es")
    text, lang = stt.transcribe(b"ignored")
    assert text == "hola mundo"
    assert lang == "es"


def test_faster_whisper_stt_is_constructible_symbol():
    # The real class must exist and expose .transcribe; we do NOT load the model here.
    assert hasattr(FasterWhisperSTT, "transcribe")


from engines import FakeTTS, KokoroTTS, LANG_VOICE  # noqa: E402


def test_fake_tts_returns_valid_wav():
    out = FakeTTS().synthesize("hola", "es")
    # Valid WAV header ("RIFF"...."WAVE") and non-trivial length.
    assert out[:4] == b"RIFF"
    assert out[8:12] == b"WAVE"
    assert len(out) > 44


def test_lang_voice_map_has_es_and_en():
    assert "es" in LANG_VOICE and "en" in LANG_VOICE
    # Each entry is (kokoro_lang_code, voice_name).
    assert len(LANG_VOICE["es"]) == 2 and len(LANG_VOICE["en"]) == 2


def test_kokoro_tts_is_constructible_symbol():
    assert hasattr(KokoroTTS, "synthesize")


import io, wave  # noqa: E402
from urllib.parse import unquote  # noqa: E402
from engines import FakeSTT  # noqa: E402

AUTH = {"Authorization": "Bearer test-token"}


def _wav_16k(seconds: float = 0.5) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\x01\x00" * int(16000 * seconds))
    return buf.getvalue()


def test_voice_turn_returns_audio_and_headers(monkeypatch):
    monkeypatch.setattr(appmod, "call_agent", lambda text, tid, tz, lang=None: "hola Roilan")
    r = client.post(
        "/v1/voice/turn", headers=AUTH,
        files={"audio": ("u.wav", _wav_16k(), "audio/wav")},
        data={"threadId": "T", "timezone": "America/Havana"},
    )
    assert r.status_code == 200
    assert r.headers["content-type"] == "audio/wav"
    assert unquote(r.headers["x-stt-text"]) == "hola"          # FakeSTT default
    assert unquote(r.headers["x-reply-text"]) == "hola Roilan"
    assert len(r.content) > 44                                  # real audio body


def test_voice_turn_forwards_stt_language_to_agent(monkeypatch):
    # The STT-detected language must reach the agent so it can pin the reply language.
    monkeypatch.setattr(appmod, "_stt", FakeSTT(text="hello", lang="en"))
    captured = {}

    def fake_agent(text, tid, tz, language=None):
        captured["language"] = language
        return "hi Roilan"

    monkeypatch.setattr(appmod, "call_agent", fake_agent)
    r = client.post("/v1/voice/turn", headers=AUTH,
                    files={"audio": ("u.wav", _wav_16k(), "audio/wav")})
    assert r.status_code == 200
    assert captured["language"] == "en"


def test_call_agent_includes_language_in_body(monkeypatch):
    captured = {}

    class FakeResp:
        def raise_for_status(self): pass
        def json(self): return {"reply": "ok"}

    def fake_post(url, json, headers, timeout):
        captured["body"] = json
        return FakeResp()

    monkeypatch.setattr(appmod.httpx, "post", fake_post)
    appmod.call_agent("hi", "T", "America/Havana", "en")
    assert captured["body"]["language"] == "en"
    # Omitted entirely when no language is known (typed callers).
    appmod.call_agent("hi", "T", None, None)
    assert "language" not in captured["body"]


def test_voice_turn_requires_bearer():
    r = client.post("/v1/voice/turn", files={"audio": ("u.wav", _wav_16k(), "audio/wav")})
    assert r.status_code == 401


def test_voice_turn_empty_transcript_is_400(monkeypatch):
    monkeypatch.setattr(appmod, "_stt", FakeSTT(text="", lang="es"))
    called = {"agent": False}
    monkeypatch.setattr(appmod, "call_agent", lambda *a: called.__setitem__("agent", True) or "x")
    r = client.post("/v1/voice/turn", headers=AUTH,
                    files={"audio": ("u.wav", _wav_16k(), "audio/wav")})
    assert r.status_code == 400
    assert r.headers.get("x-stt-text", "") == ""
    assert called["agent"] is False                             # never reached the agent


def test_voice_turn_missing_audio_is_400():
    r = client.post("/v1/voice/turn", headers=AUTH, data={"threadId": "T"})
    assert r.status_code in (400, 422)                          # FastAPI 422 if field absent


def test_voice_turn_agent_error_speaks_fallback(monkeypatch):
    import httpx

    def boom(text, tid, tz, lang=None):
        raise httpx.ConnectError("memory down")  # transport failure -> spoken fallback, 200
    monkeypatch.setattr(appmod, "call_agent", boom)
    r = client.post("/v1/voice/turn", headers=AUTH,
                    files={"audio": ("u.wav", _wav_16k(), "audio/wav")})
    assert r.status_code == 200
    assert "cerebro" in unquote(r.headers["x-reply-text"]).lower()
    assert len(r.content) > 44                                  # the fallback was spoken


def test_voice_turn_stt_failure_is_502(monkeypatch):
    class BoomSTT:
        def transcribe(self, wav_bytes):
            raise RuntimeError("model crashed")
    monkeypatch.setattr(appmod, "_stt", BoomSTT())
    r = client.post("/v1/voice/turn", headers=AUTH,
                    files={"audio": ("u.wav", _wav_16k(), "audio/wav")})
    assert r.status_code == 502


def test_voice_turn_tts_failure_is_502(monkeypatch):
    class BoomTTS:
        def synthesize(self, text, lang):
            raise RuntimeError("tts down")
    monkeypatch.setattr(appmod, "call_agent", lambda text, tid, tz, lang=None: "una respuesta")
    monkeypatch.setattr(appmod, "_tts", BoomTTS())
    r = client.post("/v1/voice/turn", headers=AUTH,
                    files={"audio": ("u.wav", _wav_16k(), "audio/wav")})
    assert r.status_code == 502
    assert unquote(r.headers["x-reply-text"]) == "una respuesta"  # unspoken text surfaced


import httpx  # noqa: E402
import pytest  # noqa: E402
from engines import ElevenLabsScribeSTT  # noqa: E402


def test_elevenlabs_stt_parses_text_and_forces_language(monkeypatch):
    captured = {}

    class FakeResp:
        def raise_for_status(self): pass
        def json(self): return {"text": " hello world ", "language_code": "es"}  # detected es

    def fake_post(url, **kw):
        captured["url"] = url
        captured["headers"] = kw.get("headers")
        captured["data"] = kw.get("data")
        captured["files"] = kw.get("files")
        return FakeResp()

    monkeypatch.setattr(httpx, "post", fake_post)
    stt = ElevenLabsScribeSTT(api_key="k", model="scribe_v1", language="en")
    text, lang = stt.transcribe(b"RIFF....")
    assert text == "hello world"          # trimmed
    assert lang == "en"                   # forced, ignores detected "es"
    assert captured["url"] == "https://api.elevenlabs.io/v1/speech-to-text"
    assert captured["headers"]["xi-api-key"] == "k"
    assert captured["data"]["model_id"] == "scribe_v1"
    assert captured["data"]["language_code"] == "en"
    assert captured["files"]["file"][0] == "audio.wav"


def test_elevenlabs_stt_autodetect_when_language_none(monkeypatch):
    class FakeResp:
        def raise_for_status(self): pass
        def json(self): return {"text": "hola", "language_code": "es"}

    monkeypatch.setattr(httpx, "post", lambda url, **kw: FakeResp())
    stt = ElevenLabsScribeSTT(api_key="k", language=None)
    text, lang = stt.transcribe(b"x")
    assert (text, lang) == ("hola", "es")  # returns detected language


def test_elevenlabs_stt_raises_on_http_error(monkeypatch):
    class FakeResp:
        def raise_for_status(self):
            raise httpx.HTTPStatusError("boom", request=None, response=None)
        def json(self): return {}

    monkeypatch.setattr(httpx, "post", lambda url, **kw: FakeResp())
    stt = ElevenLabsScribeSTT(api_key="k")
    with pytest.raises(httpx.HTTPStatusError):
        stt.transcribe(b"x")


def test_elevenlabs_stt_requires_api_key():
    with pytest.raises(RuntimeError):
        ElevenLabsScribeSTT(api_key="")
