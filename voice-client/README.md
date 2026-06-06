# Gemma Mac voice client

Thin client: captures your speech, sends it to the i3 voice gateway, plays the reply.

## Setup (macOS)
```
brew install portaudio        # if the sounddevice wheel doesn't bundle PortAudio
cd voice-client
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Run
```
I3_HOST=http://192.168.1.50:8082 \
VOICE_BEARER_TOKEN=<the MEMORY_BEARER_TOKEN from the i3 .env> \
python3 voice_client.py
```
Speak after "Listening…"; pause ~0.8 s to end your turn. Gemma answers by voice. Ctrl-C quits.
Env: `I3_HOST`, `VOICE_BEARER_TOKEN`, `THREAD_ID` (default `mac-voice`), `TIMEZONE` (default `America/Havana`).
