FROM python:3.11-slim AS base

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential espeak-ng libsndfile1 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install CPU-only torch FIRST: the i3 has no GPU, and the default torch==2.6.0 wheel drags in
# ~4 GB of unused CUDA libs. The CPU wheel (2.6.0+cpu) satisfies kokoro's `torch==2.6.0` dep below.
RUN pip install --no-cache-dir torch==2.6.0 --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-pull models into the image so the first request is warm. Done BEFORE copying the app code
# (the pre-pull only needs the pip packages) so editing app.py/engines.py doesn't re-download models.
ENV HF_HUB_CACHE=/models
ENV WHISPER_CACHE=/models
RUN python -c "from faster_whisper import WhisperModel; WhisperModel('small', device='cpu', compute_type='int8', download_root='/models')"
RUN python -c "import warnings; warnings.filterwarnings('ignore'); from kokoro import KPipeline; \
[list(KPipeline(lang_code=lc)(t, voice=v)) for lc, v, t in [('a','af_heart','hi'), ('e','ef_dora','hola')]]"

COPY app.py engines.py test_app.py ./

EXPOSE 8082
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8082"]
