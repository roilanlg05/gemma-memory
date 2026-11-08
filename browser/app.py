"""Pasarela del navegador del agente. Es dueña del CLI `agent-browser` (y de su
Chromium) en el i3; la app de macOS lo invoca por HTTP en vez de lanzarlo en local.
/v1/browser/invoke valida el argv y lo ejecuta vía cli.py; /v1/browser/stream es
el relé del panel, que sirve el stream del demonio a uno o varios visores."""
import asyncio
import logging
import os
import re
import weakref
from collections.abc import Mapping
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket
from pydantic import BaseModel, Field, StringConstraints

import cli
import relay

# Ruta del CLI (la misma que usa cli.py para lanzar el proceso).
BROWSER_BIN = os.environ.get("AGENT_BROWSER_BIN", "agent-browser")


def require_bearer(authorization: str = Header(default="")) -> None:
    # Se lee el token del entorno en cada llamada (falla cerrado: sin token → siempre 401).
    expected = os.environ.get("BROWSER_BEARER_TOKEN", "")
    if not expected or authorization != f"Bearer {expected}":
        raise HTTPException(status_code=401, detail="unauthorized")


class RedactTokenFilter(logging.Filter):
    """Tacha `token=...` de cualquier línea de log.

    El panel manda su bearer en `?token=` porque un cliente de WebSocket no puede
    poner cabeceras, y uvicorn registra el upgrade **con su query string**. El
    `--no-access-log` del `CMD` apaga el log de acceso, pero la línea del upgrade
    sale por el logger `uvicorn.error` y seguía apareciendo: verificado en vivo.
    Esto lo cierra sin depender de cómo se lance el proceso, que es lo que importa
    porque este es el primer endpoint que sirve imágenes de la pantalla."""

    # Sin mayúsculas no vale: un cliente que mande `?Token=` falla la
    # autenticación (el parámetro es sensible a mayúsculas) pero su token se
    # escribiría en el log igual de claro.
    _TOKEN = re.compile(r"(token=)[^&\s\"']+", re.IGNORECASE)

    @classmethod
    def redact(cls, text: str) -> str:
        return cls._TOKEN.sub(r"\1[redactado]", text)

    @classmethod
    def _clean(cls, value):
        """Redacta cualquier argumento, no solo los `str`: logging acepta dicts,
        bytes y lo que tenga `__str__`. Si no había nada que tachar devuelve el
        valor TAL CUAL, para no romper un `%d` convirtiendo un número en texto."""
        try:
            text = value if isinstance(value, str) else str(value)
            redacted = cls.redact(text)
        except Exception:
            return value
        return redacted if redacted != text else value

    def filter(self, record: logging.LogRecord) -> bool:
        # Un filtro de logging no puede tirar a quien registra: `Logger.handle` no
        # envuelve los filtros, así que una excepción aquí saldría por el
        # `logger.info` del handshake del WebSocket.
        #
        # Se redacta sobre el mensaje YA FORMATEADO y se congela el resultado.
        # Redactar la plantilla y los `args` por separado no basta y además es
        # PELIGROSO: con una plantilla `"... token=%s"` y el secreto en `args`, la
        # redacción se come el `%s`, el `getMessage()` del formateador revienta con
        # un TypeError, y `Handler.handleError` escribe en stderr el `record.args`
        # entero — o sea, el token, por haber intentado tacharlo. Formateando una
        # vez se cubren de golpe la plantilla, los `args` partidos, el mapping del
        # scope de uvicorn y lo que no es `str`.
        #
        # Si no había nada que tachar NO se toca nada: así un `%d` sigue siendo un
        # número y no se pierde el formateo perezoso del caso normal.
        try:
            texto = record.getMessage()
        except Exception:
            texto = None
        if texto is not None:
            try:
                redactado = self.redact(texto)
                if redactado != texto:
                    record.msg = redactado
                    record.args = None
            except Exception:
                pass
            return True
        # Sin poder formatear (una plantilla o unos `args` que no casan): se limpia
        # pieza a pieza, que es lo único que queda por intentar.
        try:
            record.msg = self._clean(record.msg)
            args = record.args
            if isinstance(args, Mapping):
                # logging guarda así un único argumento dict (`%(path)s`), y por
                # esa vía el scope entero —con la query string— llega al log.
                record.args = {k: self._clean(v) for k, v in args.items()}
            elif isinstance(args, tuple):
                record.args = tuple(self._clean(a) for a in args)
        except Exception:
            pass
        return True


_REDACTOR = RedactTokenFilter()

# `uvicorn.error` emite la línea del upgrade del WebSocket con su query string, y
# es la que importa. `uvicorn.access`, el log de acceso. `uvicorn.asgi` registra
# el scope completo —`query_string` incluido— y solo se alcanza con
# `--log-level trace`, que el CMD no pone: está aquí porque el día que alguien
# suba el nivel de log para depurar, el token no debe aparecer.
for _nombre in ("uvicorn.error", "uvicorn.access", "uvicorn.asgi"):
    logging.getLogger(_nombre).addFilter(_REDACTOR)

# Y donde cubre TODO, que no es el root: un filtro puesto en un logger no se
# aplica a los registros que le llegan por propagación de un hijo —`callHandlers`
# recorre los HANDLERS de los ancestros, no sus filtros—, así que instalarlo en el
# root dejaría fuera justo lo que se quiere cubrir: un `logging.getLogger("algo")`
# nuevo del servicio. Lo que lo cubre es la FÁBRICA DE REGISTROS, que corre para
# cada `LogRecord` que se cree en el proceso, venga del logger que venga. El root
# se añade igual, por los registros emitidos directamente en él.
#
# Lo que esto NO cubre, dicho aquí para que nadie lo dé por cubierto: el texto de
# un traceback (`exc_info`), que el formateador del handler compone aparte del
# mensaje. Hoy no hay vía conocida por la que el token entre en una excepción —el
# relé registra solo el nombre de la clase— y cerrarla pediría parchear
# `logging.Formatter`, que cuesta más de lo que compra.
logging.getLogger().addFilter(_REDACTOR)

_fabrica_previa = logging.getLogRecordFactory()


def _fabrica_sin_token(*args, **kwargs) -> logging.LogRecord:
    record = _fabrica_previa(*args, **kwargs)
    # El propio filtro, que ya se traga sus errores: aquí eso importa el doble,
    # porque esto corre en CADA registro del proceso. El coste es formatear el
    # mensaje una vez por registro, que en un servicio que arranca con
    # `--no-access-log` no se nota; se encadena a la fábrica anterior para no pisar
    # la de nadie.
    _REDACTOR.filter(record)
    return record


logging.setLogRecordFactory(_fabrica_sin_token)


app = FastAPI(title="Gemma Browser Gateway", version="1.0")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


class InvokeBody(BaseModel):
    # Topes: un cuerpo sin límite crecería sin freno en el servidor.
    arguments: list[Annotated[str, StringConstraints(max_length=8192)]] = Field(max_length=64)
    timeout: float = Field(default=30, gt=0, le=300)
    # Va al stdin del proceso, nunca a argv: `ps` lee el argv de cualquier proceso.
    stdin: str | None = Field(default=None, max_length=262144)


@app.post("/v1/browser/invoke", dependencies=[Depends(require_bearer)])
async def browser_invoke(body: InvokeBody):
    try:
        cli.validate(body.arguments, body.stdin)
    except ValueError as motivo:
        raise HTTPException(status_code=400, detail=str(motivo))
    return await cli.run(body.arguments, timeout=body.timeout, stdin=body.stdin)


# El relé vive en el proceso, no en la petición: un panel, una sesión. Se guarda
# por bucle de eventos porque sus tareas y su socket pertenecen al bucle que lo
# creó (en producción hay uno solo; cada cliente de prueba trae el suyo).
_relays: weakref.WeakKeyDictionary = weakref.WeakKeyDictionary()


def _relay() -> relay.Relay:
    loop = asyncio.get_running_loop()
    rele = _relays.get(loop)
    if rele is None:
        rele = relay.Relay(relay.read_port)
        _relays[loop] = rele
    return rele


@app.websocket("/v1/browser/stream")
async def browser_stream(
    ws: WebSocket,
    maxFps: int = Query(default=relay.DEFAULT_VIEWER_MAX_FPS),
    token: str = Query(default=""),
    session: str = Query(default=""),
) -> None:
    """El panel: frames filtrados, narración ya compuesta y el estado ya decidido.

    `Bearer` en la cabecera o en el parámetro `token`, que es la única vía que
    tiene un cliente de WebSocket que no puede poner cabeceras. Ni dentro de la
    VPN se sirve sin token.

    `session` es la sesión del CLI que el visor espera ver. Es opcional (un visor
    que no la declara se comporta como siempre) y si no coincide con la del relé se
    cierra con un motivo que nombra las dos: ver `relay.session_mismatch`."""
    expected = os.environ.get("BROWSER_BEARER_TOKEN", "")
    presented = ws.headers.get("authorization", "")
    if not expected or (presented != f"Bearer {expected}" and token != expected):
        await ws.close(code=1008)  # policy violation, antes de aceptar
        return
    await ws.accept()
    motivo = relay.session_mismatch(session)
    if motivo is not None:
        # Se acepta y se cierra con un `closed` en vez de rechazar el handshake,
        # porque un 1008 sin cuerpo dejaría al usuario mirando un rectángulo en
        # blanco, que es justo la avería que esta guardia existe para matar. La
        # comparación va DESPUÉS del token (nadie sin autenticar averigua el nombre
        # de la sesión) y ANTES de `add_viewer`, para no levantar un Chromium en el
        # i3 por un visor que no va a ver nada.
        #
        # El `state` de delante NO es decorativo, y sin él esta guardia no sirve de
        # nada: el visor no dibuja el panel hasta haber recibido algo del servidor,
        # y un `closed` **no cuenta** para eso —el cliente se fabrica uno él mismo
        # cuando la conexión falla, así que contarlo haría aparecer un panel gris
        # con el i3 caído—. El `state` es la forma de decir «el servidor sí habló»,
        # y es lo que hace que el motivo de abajo llegue a un píxel en vez de morir
        # en una fila vacía.
        await ws.send_json({"type": "state", "live": False, "collapsed": False})
        await ws.send_json({"type": "closed", "reason": motivo})
        await ws.close(code=1008)
        return
    await _relay().add_viewer(ws, max_fps=maxFps)
