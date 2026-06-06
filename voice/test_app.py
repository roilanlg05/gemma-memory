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
