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

COPY app.py cli.py stream.py relay.py test_app.py test_stream.py ./

EXPOSE 8083
# --no-access-log: el log de acceso registra la ruta CON su query string, y el
# panel manda el bearer en `?token=` (un cliente de WebSocket no puede poner
# cabeceras). Sin esto, cada conexión del panel escribiría el token en claro en
# los logs de Docker del i3, que no rotan ni se tratan como un secreto.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8083", "--no-access-log"]
