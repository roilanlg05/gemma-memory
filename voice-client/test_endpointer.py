"""Pure-logic test for the VAD endpointer (no audio hardware). Run with:
    python3 -m pytest voice-client/test_endpointer.py -v"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from voice_client import VadEndpointer


def test_endpointer_triggers_after_trailing_silence():
    # 30 ms frames; end after 300 ms (10 frames) of silence following >=90 ms (3 frames) of speech.
    ep = VadEndpointer(frame_ms=30, silence_ms=300, min_speech_ms=90)
    for _ in range(5):
        assert ep.update(True) is False          # speech: never ends mid-speech
    results = [ep.update(False) for _ in range(10)]
    assert results[-1] is True                    # ends on the 10th silent frame
    assert True not in results[:9]                # not before


def test_endpointer_ignores_short_blip():
    # Needs 300 ms (10 frames) of speech to "start"; a 90 ms blip must never trigger an end.
    ep = VadEndpointer(frame_ms=30, silence_ms=300, min_speech_ms=300)
    for _ in range(3):
        ep.update(True)                           # only 90 ms speech -> not started
    results = [ep.update(False) for _ in range(20)]
    assert True not in results
