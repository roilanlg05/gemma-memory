"""STT/TTS engine interfaces + concrete (faster-whisper, Kokoro) and fake impls.
The handler depends only on the protocols, so engines are swappable (VibeVoice/Piper/cloud later)."""
import io
import os
import wave
from typing import Protocol, Tuple


class STTEngine(Protocol):
    def transcribe(self, wav_bytes: bytes) -> Tuple[str, str]:
        """Return (recognized_text, detected_language_code)."""
        ...


class FakeSTT:
    """Deterministic STT for unit tests (no model)."""
    def __init__(self, text: str = "hola", lang: str = "es"):
        self.text = text
        self.lang = lang

    def transcribe(self, wav_bytes: bytes) -> Tuple[str, str]:
        return self.text, self.lang


class FasterWhisperSTT:
    """CPU faster-whisper (CTranslate2 int8). Expects 16 kHz mono WAV bytes.
    WHISPER_LANGUAGE (e.g. "en") forces the language — skips auto-detect (faster) and avoids
    cross-language mis-transcription; leave unset for multilingual auto-detect."""
    def __init__(self, model_name: str = "small"):
        from faster_whisper import WhisperModel
        download_root = os.environ.get("WHISPER_CACHE") or None
        cpu_threads = int(os.environ.get("WHISPER_CPU_THREADS", "0"))  # 0 = CTranslate2 default
        self._language = os.environ.get("WHISPER_LANGUAGE") or None
        self._model = WhisperModel(
            model_name, device="cpu", compute_type="int8",
            download_root=download_root, cpu_threads=cpu_threads,
        )

    def transcribe(self, wav_bytes: bytes) -> Tuple[str, str]:
        import numpy as np
        import soundfile as sf
        data, _sr = sf.read(io.BytesIO(wav_bytes), dtype="float32")
        if getattr(data, "ndim", 1) > 1:  # downmix to mono
            data = data.mean(axis=1)
        # Client guarantees 16 kHz; faster-whisper assumes 16 kHz for ndarray input.
        # vad_filter drops silence (e.g. the endpointer's trailing pause) -> less audio to decode.
        segments, info = self._model.transcribe(
            np.ascontiguousarray(data), beam_size=1, language=self._language, vad_filter=True,
        )
        text = "".join(seg.text for seg in segments).strip()
        return text, info.language


# --- TTS ---------------------------------------------------------------------

# Kokoro lang_code per language + a default voice. 'a'=American English, 'e'=Spanish.
# Voices: 'af_heart' (American female), 'ef_dora' (Spanish female).
LANG_VOICE = {
    "en": ("a", "af_heart"),
    "es": ("e", "ef_dora"),
}
_DEFAULT_LANG = "es"  # Gemma's user speaks Spanish; fall back here for unknown langs.


class TTSEngine(Protocol):
    def synthesize(self, text: str, lang: str) -> bytes:
        """Return WAV bytes (mono PCM16) for `text`, voiced per `lang`."""
        ...


class FakeTTS:
    """Deterministic TTS for unit tests: 0.1 s of silence as a valid 24 kHz WAV (stdlib only)."""
    SR = 24000

    def synthesize(self, text: str, lang: str) -> bytes:
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(self.SR)
            w.writeframes(b"\x00\x00" * (self.SR // 10))
        return buf.getvalue()


class KokoroTTS:
    """Kokoro-82M on CPU. One KPipeline per language (lazy), reused across calls."""
    SR = 24000

    def __init__(self, override_voice: str = ""):
        self._override_voice = override_voice or ""
        self._pipelines = {}  # lang_code -> KPipeline

    def _pipeline(self, lang_code: str):
        if lang_code not in self._pipelines:
            from kokoro import KPipeline
            self._pipelines[lang_code] = KPipeline(lang_code=lang_code)
        return self._pipelines[lang_code]

    def synthesize(self, text: str, lang: str) -> bytes:
        import numpy as np
        import soundfile as sf
        lang_code, voice = LANG_VOICE.get(lang, LANG_VOICE[_DEFAULT_LANG])
        if self._override_voice:
            voice = self._override_voice
        pipe = self._pipeline(lang_code)
        chunks = []
        for _gs, _ps, audio in pipe(text, voice=voice):
            arr = audio.numpy() if hasattr(audio, "numpy") else np.asarray(audio)
            chunks.append(arr.astype("float32"))
        data = np.concatenate(chunks) if chunks else np.zeros(1, dtype="float32")
        buf = io.BytesIO()
        sf.write(buf, data, self.SR, format="WAV", subtype="PCM_16")
        return buf.getvalue()
