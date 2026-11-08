"""Lector del stream del demonio del navegador: donde `params` muere.

Entra el texto de un mensaje del WebSocket del demonio; sale un diccionario
con solo los campos que el relé necesita, o los mensajes del cable.

El demonio emite `frame`, `status` y, sin documentar, un eco `command` por cada
orden ejecutada, con un objeto `params` que lleva los argumentos crudos (el
número de tarjeta de un `fill`, por ejemplo). Este módulo es el filtro: de
`params` solo se lee `url`, y solo cuando la acción es `navigate` u `open`; nada
más sobrevive. Lo que sale al cable de un `fill` es la frase «rellenando un campo».

Algunas acciones del eco no son acciones del agente, y este módulo es el único
punto donde se descartan: ver IGNORED_ACTIONS. Al clasificarlas como `other` se
saltan de una vez la narración y la cuenta del panel, sin un segundo filtro en el
relé.

El módulo es puro: sin red, sin ficheros, sin estado, sin reloj, y SIN registrar nunca el
cuerpo de un mensaje (ni en un log, ni en un error). Las excepciones se
tragan sin reproducir el texto que las causó.
"""
import base64
import binascii
import json
import re
from urllib.parse import urlparse

_JPEG_MAGIC = b"\xff\xd8\xff"
_MAX_ACTION = 40  # una acción es un nombre de orden, no un contenido
_MAX_HOST = 255  # límite de DNS
_SAFE_ACTION = re.compile(r"[^A-Za-z0-9_.:-]")
# `open` es el subcomando del CLI y `navigate` el nombre del protocolo: el
# demonio puede decir cualquiera, así que ambos son navegar.
_NAVIGATE = ("navigate", "open")

# Acciones del eco que NO son acciones del agente. `launch` lo observé en vivo
# llegando antes de CADA orden, porque el CLI asegura el navegador en cada
# invocación: narrarla pondría «launch» en una interfaz en español, y contarla
# duplicaría la cuenta del resumen del panel (un turno de 7 acciones diría 14, y
# el resumen es lo único que queda cuando el panel colapsa). Se clasifican como
# `other`, así que se saltan la narración y la cuenta en el mismo punto.
IGNORED_ACTIONS: frozenset[str] = frozenset({"launch"})


def _empty(kind: str) -> dict:
    return {"kind": kind, "seq": None, "jpeg_b64": None, "captured_at": None,
            "screencasting": None, "action": None, "url": None}


def _is_jpeg(b64: str) -> bool:
    """Olfatea los tres primeros bytes: el formato puede cambiar por debajo."""
    try:
        head = base64.b64decode("".join(b64.split())[:8], validate=True)
    except (binascii.Error, ValueError):
        return False
    return head[:3] == _JPEG_MAGIC


def _decode_frame(msg: dict) -> dict:
    seq = msg.get("seq")
    seq = seq if isinstance(seq, int) and not isinstance(seq, bool) else None
    data = msg.get("data")
    # Sin seq entero no hay nada que acusar ni que mandar: el cable fija seq
    # entero y un null haría fallar el decodificador del lado de Swift.
    if seq is None or not isinstance(data, str) or not _is_jpeg(data):
        out = _empty("bad_frame")
        out["seq"] = seq
        return out
    meta = msg.get("metadata")
    ts = meta.get("timestamp") if isinstance(meta, dict) else None
    if isinstance(ts, (int, float)) and not isinstance(ts, bool):
        captured_at = ts / 1000.0  # el demonio manda milisegundos
    else:
        # Sin reloj aquí: la Tarea 4 lo sella con el suyo antes del cable.
        captured_at = None
    out = _empty("frame")
    out["seq"] = seq
    out["jpeg_b64"] = data
    out["captured_at"] = captured_at
    return out


def _decode_command(msg: dict) -> dict:
    action = msg.get("action")
    name = _SAFE_ACTION.sub("", action)[:_MAX_ACTION] if isinstance(action, str) else ""
    if name in IGNORED_ACTIONS:
        # Ni narración ni cuenta: para el panel esto no ha pasado.
        return _empty("other")
    out = _empty("command")
    out["action"] = name or None
    params = msg.get("params")
    # Única lectura de params: la url, y solo si la acción es navegar.
    if out["action"] in _NAVIGATE and isinstance(params, dict):
        url = params.get("url")
        if isinstance(url, str):
            out["url"] = url
    return out


def decode(text: str) -> dict | None:
    """Texto del socket -> dict filtrado, o None si no es un objeto con `type`."""
    try:
        msg = json.loads(text)
    except (ValueError, TypeError):
        return None
    if not isinstance(msg, dict) or not isinstance(msg.get("type"), str):
        return None
    kind = msg["type"]
    if kind == "frame":
        return _decode_frame(msg)
    if kind == "status":
        out = _empty("status")
        out["screencasting"] = msg.get("screencasting") is True
        return out
    if kind == "command":
        return _decode_command(msg)
    return _empty("other")


def host_of(url: str | None) -> str | None:
    """Solo el host de una URL http(s); None si no hay uno."""
    if not isinstance(url, str):
        return None
    try:
        parsed = urlparse(url)
        if parsed.scheme not in ("http", "https"):
            return None
        host = parsed.hostname
        return host if host and len(host) <= _MAX_HOST else None
    except ValueError:
        return None


def phrase(action: str, url: str | None) -> str:
    """Frase de narración para una acción; nunca incluye argumentos."""
    if action in _NAVIGATE:
        host = host_of(url)
        return f"navegando a {host}" if host else "navegando"
    fixed = {
        "click": "haciendo clic",
        "fill": "rellenando un campo",
        "type": "rellenando un campo",
        "snapshot": "leyendo la página",
        "read": "leyendo la página",
        "press": "pulsando una tecla",
        "wait": "esperando",
        "close": "cerrando la pestaña",
        # Las seis formas de `get` que llama la app. El eco NO usa el nombre del
        # subcomando sino la operación del protocolo, y los nombres se observaron
        # en vivo uno por uno: `get url`→`url`, `get title`→`title`,
        # `get count`→`count`, `get text`→`gettext`, `get html`→`innerhtml`,
        # `get value`→`inputvalue`. `get`, `text`, `html` y `value` se quedan como
        # alias por si otra versión del CLI usa la palabra llana; no estorban.
        # Ojo: `url` es aquí un nombre de acción de lectura y NO navega — la url de
        # `params` se lee solo para `navigate` y `open`.
        "get": "leyendo la página",
        "url": "leyendo la página",
        "title": "leyendo la página",
        "count": "leyendo la página",
        "gettext": "leyendo la página",
        "innerhtml": "leyendo la página",
        "inputvalue": "leyendo la página",
        "text": "leyendo la página",
        "html": "leyendo la página",
        "value": "leyendo la página",
    }
    return fixed.get(action, action)


def wire_messages(decoded: dict) -> list[dict]:
    """Mensajes del cable (frame, narration, host) para un dict de `decode`, o []."""
    kind = decoded.get("kind")
    if kind == "frame":
        return [{"type": "frame", "seq": decoded.get("seq"),
                 "jpeg": decoded.get("jpeg_b64"),
                 "captured_at": decoded.get("captured_at")}]
    if kind == "command" and decoded.get("action"):
        action = decoded["action"]
        url = decoded.get("url")
        msgs = [{"type": "narration", "text": phrase(action, url)}]
        host = host_of(url) if action in _NAVIGATE else None
        if host:
            msgs.append({"type": "host", "host": host})
        return msgs
    return []


def ack_seq(decoded: dict) -> int | None:
    """El seq a acusar: frames y frames ilegibles (si no, el ritmo se atasca)."""
    if decoded.get("kind") in ("frame", "bad_frame"):
        return decoded.get("seq")
    return None


def summary(host: str | None, action_count: int) -> str:
    where = host if host else "la web"
    noun = "acción" if action_count == 1 else "acciones"
    return f"navegó en {where} · {action_count} {noun}"
