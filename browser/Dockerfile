FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg \
 && rm -rf /var/lib/apt/lists/*

# Node 24 (NodeSource): el paquete agent-browser declara engines.node >= 24,
# y el Node de Debian es más viejo.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# Chromium de Debian, Xvfb (el CLI lo usa en Linux) y fuentes mínimas para que
# las páginas no se rendericen en cuadros.
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium xvfb fonts-liberation \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g agent-browser@0.41.2 \
 && mkdir -p /run/agent-browser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py test_app.py ./

EXPOSE 8083
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8083"]
