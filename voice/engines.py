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
    """CPU faster-whisper (CTranslate2 int8). Expects 16 kHz mono WAV bytes."""
    def __init__(self, model_name: str = "small"):
        from faster_whisper import WhisperModel
        download_root = os.environ.get("WHISPER_CACHE") or None
        self._model = WhisperModel(
            model_name, device="cpu", compute_type="int8", download_root=download_root
        )

    def transcribe(self, wav_bytes: bytes) -> Tuple[str, str]:
        import numpy as np
        import soundfile as sf
        data, _sr = sf.read(io.BytesIO(wav_bytes), dtype="float32")
        if getattr(data, "ndim", 1) > 1:  # downmix to mono
            data = data.mean(axis=1)
        # Client guarantees 16 kHz; faster-whisper assumes 16 kHz for ndarray input.
        segments, info = self._model.transcribe(np.ascontiguousarray(data), beam_size=1)
        text = "".join(seg.text for seg in segments).strip()
        return text, info.language
