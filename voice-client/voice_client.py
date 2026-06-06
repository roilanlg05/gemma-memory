"""Thin Mac voice client for Gemma. Captures one utterance (webrtcvad silence-endpointing),
POSTs it to the i3 voice gateway, plays the spoken reply, loops. The i3 does all processing.

Run:
    pip install -r requirements.txt
    I3_HOST=http://192.168.1.50:8082 VOICE_BEARER_TOKEN=<token> python3 voice_client.py
Ctrl-C to quit."""
import io
import os
import sys
import wave
from urllib.parse import unquote

SR = 16000
FRAME_MS = 30
FRAME_SAMPLES = SR * FRAME_MS // 1000   # 480 samples = 960 bytes @ 16-bit mono


class VadEndpointer:
    """Signals end-of-utterance after `silence_ms` of trailing silence, but only once at least
    `min_speech_ms` of speech has occurred. Pure logic — fed one voiced/unvoiced flag per frame."""
    def __init__(self, frame_ms: int = 30, silence_ms: int = 800, min_speech_ms: int = 300):
        self.silence_needed = max(1, silence_ms // frame_ms)
        self.min_speech = max(1, min_speech_ms // frame_ms)
        self.speech_frames = 0
        self.trailing_silence = 0
        self.started = False

    def update(self, is_voiced: bool) -> bool:
        if is_voiced:
            self.speech_frames += 1
            self.trailing_silence = 0
            if self.speech_frames >= self.min_speech:
                self.started = True
        elif self.started:
            self.trailing_silence += 1
        return self.started and self.trailing_silence >= self.silence_needed


def _record_utterance(vad, ep) -> bytes:
    import sounddevice as sd
    frames = []
    with sd.RawInputStream(samplerate=SR, channels=1, dtype="int16",
                           blocksize=FRAME_SAMPLES) as stream:
        while True:
            data, _ = stream.read(FRAME_SAMPLES)
            pcm = bytes(data)
            if len(pcm) < FRAME_SAMPLES * 2:
                continue
            voiced = vad.is_speech(pcm, SR)
            if ep.started or voiced:
                frames.append(pcm)
            if ep.update(voiced):
                break
    return b"".join(frames)


def _to_wav(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm)
    return buf.getvalue()


def _play(wav_bytes: bytes) -> None:
    import sounddevice as sd
    import soundfile as sf
    data, sr = sf.read(io.BytesIO(wav_bytes), dtype="float32")
    sd.play(data, sr)
    sd.wait()


def main() -> None:
    import requests
    import webrtcvad
    host = os.environ.get("I3_HOST", "http://localhost:8082").rstrip("/")
    token = os.environ.get("VOICE_BEARER_TOKEN", "")
    thread_id = os.environ.get("THREAD_ID", "mac-voice")
    timezone = os.environ.get("TIMEZONE", "America/Havana")
    print(f"Voice client -> {host} (thread={thread_id}). Listening… Ctrl-C to quit.")
    while True:
        vad = webrtcvad.Vad(2)
        ep = VadEndpointer()
        pcm = _record_utterance(vad, ep)
        if len(pcm) < int(SR * 2 * 0.3):    # <300 ms captured -> ignore
            continue
        try:
            r = requests.post(
                f"{host}/v1/voice/turn",
                headers={"Authorization": f"Bearer {token}"},
                files={"audio": ("u.wav", _to_wav(pcm), "audio/wav")},
                data={"threadId": thread_id, "timezone": timezone},
                timeout=180,
            )
        except Exception as exc:
            print("net error:", exc)
            continue
        if r.status_code == 400:             # silence/no transcript -> just listen again
            continue
        if r.status_code != 200:
            print("error", r.status_code, unquote(r.headers.get("X-Reply-Text", "")))
            continue
        print("you:  ", unquote(r.headers.get("X-STT-Text", "")))
        print("gemma:", unquote(r.headers.get("X-Reply-Text", "")))
        _play(r.content)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
