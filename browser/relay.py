"""El relé del stream del navegador: abre el socket del demonio en el i3, filtra,
decide si el panel está «en vivo», y sirve a uno o varios visores.

El servidor de streaming del demonio escucha SOLO en localhost del i3, en un
puerto que le asigna el sistema operativo, así que la app no puede conectarse a
él. Este módulo es el puente, y por estar en medio es también la frontera donde
se hace cumplir el diseño: la app recibe seis clases de mensaje ya limpias y ya
decididas, y no calcula nada sobre el estado del navegador.

Tres piezas:
  - `PanelState`: el predicado de «en vivo», la cuenta de acciones y el host del
    panel. Es comprobable sola, sin red.
  - `Viewer`: un visor conectado, con su propia tarea de escritura y su tope de
    fps. El tope se aplica al DESCARTE y no a la cola: a un visor lento le toca
    saltarse frames, nunca encolarlos, así que no puede retrasar al rápido ni
    convertirse en el reloj de todos.
  - `Relay`: el bucle del socket del demonio, el reparto y el acuse encadenado.

Lo que este módulo NO hace, por restricción del diseño y no por descuido:
  - no registra nunca el cuerpo de un mensaje del demonio, ni en un log, ni en el
    texto de una excepción: `params` no sale de este proceso (spec §5.7 y §6.3);
  - no escribe ningún frame a disco (spec §6.2(a));
  - no llama nunca a `stream enable`, que devuelve `success:false` cuando ya está
    activo, que es siempre (spec §5.1). El único uso del CLI es
    `stream status --json`, para leer el puerto;
  - no cachea el puerto: lo asigna el sistema operativo y cambia con cada demonio
    (spec §5.2). Un relé que lo cachea deja el panel muerto el resto de la sesión;
  - no decide «en vivo» por la edad del frame: los frames se emiten por cambio y
    no por reloj, así que una página quieta sigue estando viva (spec §6.2(f));
  - no se inventa un acuse al demonio: acusa cuando el visor le acusa a él, o
    cuando no queda ningún visor con el frame en vuelo (spec §6.4);
  - no acepta del visor ningún mensaje que no sea `ack`: no hay control remoto
    (spec §7).
"""
import asyncio
import contextlib
import json
import os
import time
from collections import deque
from typing import Awaitable, Callable

import websockets

import cli
import stream

# Sesión del CLI que sigue el panel. Un panel, una sesión (spec, no objetivos).
SESSION = os.environ.get("BROWSER_STREAM_SESSION", "gemma")

# Tope de fps que se le pide al demonio, declarado en la URL y no por un mensaje
# `config`: es la única forma de que cubra el frame de apertura (spec §5.5, §6.2(c)).
DAEMON_MAX_FPS = 10
# Tope por omisión de un visor, y el que se usa si pide uno inválido.
DEFAULT_VIEWER_MAX_FPS = 10

STATUS_TIMEOUT = 20.0          # plazo del `stream status --json`
# Plazo del lector del puerto visto desde el relé, por encima del que ya tiene
# `cli.run`: el lector se inyecta, y el relé no cuelga del plazo de quien le pasen.
PORT_TIMEOUT = 25.0
PORT_TRIES = 3                 # el demonio puede estar arrancando todavía
PORT_RETRY_SECONDS = 2.0
CONNECT_TIMEOUT = 10.0
MAX_FRAME_BYTES = 8 * 1024 * 1024   # un frame son ~92 KB de base64; el tope es por si acaso
CHANNEL_DEPTH = 64             # mensajes del canal ordenado pendientes por visor
# Tiempo que el relé puede llevar sin poder acusar antes de declarar el panel
# congelado. NO es la edad del frame: una página quieta no manda frames y no
# tiene nada en vuelo, así que este plazo no la toca nunca.
STALL_GRACE_SECONDS = 5.0
STALL_TICK_SECONDS = 1.0
# El socket del demonio no se suelta en el instante en que se va el último visor:
# un visor que se va y vuelve a mitad de un turno encuentra el panel con su cuenta
# y su host (Review Focus 4). Pasado el plazo se suelta, para no dejar al navegador
# del i3 emitiendo frames para nadie.
LINGER_SECONDS = 15.0


class PanelState:
    """El estado del panel, decidido en el i3 y mandado ya hecho al visor.

    «En vivo» son cuatro propiedades de la CONEXIÓN, ninguna de la página: el
    socket al demonio abierto, el relé acusando, el último `status` con
    `screencasting: true`, y el panel sin colapsar (spec §6.2(f))."""

    def __init__(self, screencasting: bool) -> None:
        # Nace sembrado de lo que dijo el CLI y no de haber visto un `status`: ese
        # canal no es durable (spec §5.9), y si el predicado exigiera haberlo
        # visto, un panel que pinta frames nuevos se marcaría congelado.
        self._socket_open = True
        self._acking = True
        self._screencasting = bool(screencasting)
        self.collapsed = False
        self.action_count = 0
        self.host: str | None = None

    @property
    def live(self) -> bool:
        return (self._socket_open and self._acking and self._screencasting
                and not self.collapsed)

    @property
    def acking(self) -> bool:
        return self._acking

    def apply(self, decoded: dict) -> None:
        """Aplica un mensaje ya filtrado por `stream.decode`."""
        kind = decoded.get("kind")
        if kind == "status":
            self._screencasting = decoded.get("screencasting") is True
            return
        if kind == "frame":
            # Un frame recibido ES el screencast ocurriendo, así que vale como
            # prueba. Observado en vivo: el demonio manda `status` con
            # `screencasting:false` justo al engancharse el relé y lo corrige con
            # otro `status` solo unos segundos después; sin esto el panel diría
            # «congelado» mientras pinta frames nuevos. Esto NO es la edad del
            # frame decidiendo nada: es su llegada, no su antigüedad.
            self._screencasting = True
        if self.collapsed:
            return  # un panel colapsado ni pinta ni narra ni cuenta
        if kind == "command" and decoded.get("action"):
            self.action_count += 1
            host = stream.host_of(decoded.get("url"))
            if host:
                self.host = host

    def freeze(self) -> None:
        """El panel se congela: suelta su imagen y deja la línea de resumen."""
        self.collapsed = True

    def socket_closed(self) -> None:
        self._socket_open = False

    def set_acking(self, acking: bool) -> None:
        self._acking = bool(acking)

    def state_message(self) -> dict:
        return {"type": "state", "live": self.live, "collapsed": self.collapsed}

    def summary_message(self) -> dict:
        return {"type": "summary", "text": stream.summary(self.host, self.action_count)}

    def snapshot_messages(self) -> list[dict]:
        """Lo que recibe un visor que acaba de entrar: el estado actual, no un
        backlog (Review Focus 4). El `host` solo si hay uno; el cable fija `host`
        como texto y un null rompería al lado de Swift."""
        messages = [self.state_message(), self.summary_message()]
        if self.host:
            messages.append({"type": "host", "host": self.host})
        return messages


def _frame_interval(max_fps) -> float:
    """Segundos mínimos entre frames para un visor. `0` es sin tope, como en el
    demonio; un valor fuera de 1..120 cae al tope por omisión, también como hace
    el demonio con un `maxFps` inválido (spec §5.6)."""
    try:
        fps = int(max_fps)
    except (TypeError, ValueError):
        fps = DEFAULT_VIEWER_MAX_FPS
    if fps == 0:
        return 0.0
    if not 1 <= fps <= 120:
        fps = DEFAULT_VIEWER_MAX_FPS
    return 1.0 / fps


class Viewer:
    """Un visor conectado al relé.

    Tiene su propia tarea de escritura: el bucle del demonio nunca espera por el
    socket de un visor. Eso importa porque un frame pasa del tope de escritura del
    servidor ASGI, así que escribir a un visor atascado bloquearía al resto
    (Review Focus 3). Los frames van a una ranura de uno que se reemplaza —nunca a
    una cola—, y los mensajes del canal ordenado (narración, host, estado, resumen,
    cierre) a una fila acotada que preserva su orden."""

    def __init__(self, ws, max_fps: int) -> None:
        self.ws = ws
        self._min_interval = _frame_interval(max_fps)
        self._next_frame_at = 0.0
        self._channel: deque[dict] = deque(maxlen=CHANNEL_DEPTH)
        self._frame: dict | None = None
        self._wake = asyncio.Event()
        self._drained = asyncio.Event()
        self._drained.set()
        self._gone = False
        self._pump: asyncio.Task | None = None

    @property
    def gone(self) -> bool:
        return self._gone

    def start(self) -> None:
        self._pump = asyncio.create_task(self._run())

    def offer(self, message: dict) -> None:
        """Encola un mensaje del canal ordenado. No espera al socket."""
        if self._gone:
            return
        self._channel.append(message)
        self._drained.clear()
        self._wake.set()

    def offer_frame(self, message: dict, now: float) -> bool:
        """Ofrece un frame. Devuelve False si a este visor le toca saltárselo por
        su tope de fps: se descarta, no se encola."""
        if self._gone or now < self._next_frame_at:
            return False
        self._next_frame_at = now + self._min_interval
        self._frame = message  # ranura del último: se reemplaza, no se acumula
        self._drained.clear()
        self._wake.set()
        return True

    async def flush(self, timeout: float = 2.0) -> None:
        """Espera a que lo ofrecido salga, con plazo: un visor que no drena no
        puede colgar el cierre del panel."""
        with contextlib.suppress(Exception):
            await asyncio.wait_for(self._drained.wait(), timeout)

    async def stop(self) -> None:
        self._gone = True
        pump, self._pump = self._pump, None
        if pump is not None:
            pump.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await pump

    async def _run(self) -> None:
        while not self._gone:
            await self._wake.wait()
            self._wake.clear()
            while self._channel and not self._gone:
                await self._send(self._channel.popleft())
            frame, self._frame = self._frame, None
            if frame is not None and not self._gone:
                await self._send(frame)
            if not self._channel and self._frame is None:
                self._drained.set()

    async def _send(self, message: dict) -> None:
        try:
            await self.ws.send_json(message)
        except Exception:
            # El mensaje NO se registra: llevaría un frame entero al log.
            self._gone = True
            self._drained.set()
            with contextlib.suppress(Exception):
                await self.ws.close()


def _ack_from(text: str) -> int | None:
    """El `seq` de un `{"type":"ack","seq":N}` del visor, o None.

    Cualquier otro mensaje del visor se ignora: el relé no reenvía nada al
    demonio, así que no hay control remoto por esta vía (spec §7)."""
    try:
        message = json.loads(text)
    except (ValueError, TypeError):
        return None
    if not isinstance(message, dict) or message.get("type") != "ack":
        return None
    seq = message.get("seq")
    if isinstance(seq, int) and not isinstance(seq, bool) and seq >= 0:
        return seq
    return None


def _envelope_data(stdout: str) -> dict:
    """El `data` del envelope del CLI, buscando desde la última línea. El stdout
    NO se registra ni se devuelve en ningún error."""
    for line in reversed(stdout.strip().splitlines()):
        try:
            envelope = json.loads(line)
        except (ValueError, TypeError):
            continue
        if isinstance(envelope, dict) and envelope.get("success") is True:
            data = envelope.get("data")
            return data if isinstance(data, dict) else {}
    return {}


async def read_port() -> int | None:
    """El puerto del servidor de streaming del demonio, leído del CLI.

    Se llama en cada (re)conexión y nunca se cachea: lo asigna el sistema
    operativo y cambia con cada demonio (spec §5.2). El único subcomando de
    `stream` que se usa es `status`; `enable` no se llama nunca (spec §5.1)."""
    arguments = ["--session", SESSION, "stream", "status", "--json"]
    try:
        cli.validate(arguments)  # la misma puerta que la red: `enable` no pasa
        result = await cli.run(arguments, timeout=STATUS_TIMEOUT)
    except Exception:
        return None  # el motivo no se registra: arrastraría el stdout del CLI
    if result.get("exitCode") != 0:
        return None
    port = _envelope_data(result.get("stdout") or "").get("port")
    if isinstance(port, int) and not isinstance(port, bool) and 1 <= port <= 65535:
        return port
    return None


class Relay:
    """El relé, por sesión: un socket al demonio y los visores que lo miran."""

    def __init__(self, read_port: Callable[[], Awaitable[int | None]], *,
                 stall_grace: float = STALL_GRACE_SECONDS,
                 linger: float = LINGER_SECONDS) -> None:
        self._read_port = read_port
        self._stall_grace = stall_grace
        self._linger = linger
        self._viewers: set[Viewer] = set()
        self._panel: PanelState | None = None
        self._daemon: object | None = None     # el socket al demonio, mientras vive
        self._daemon_task: asyncio.Task | None = None
        self._linger_task: asyncio.Task | None = None
        self._ack_lock = asyncio.Lock()
        # El frame que está en vuelo y los visores que todavía no lo han acusado.
        # Con `pacing=ack` el demonio mantiene como máximo uno (spec §5.6).
        self._pending_seq: int | None = None
        self._pending_viewers: set[Viewer] = set()
        self._pending_since = 0.0

    # --- visores ---

    async def add_viewer(self, ws, max_fps: int) -> None:
        """Atiende a un visor hasta que se va.

        Le manda el estado actual al entrar (Review Focus 4) y solo le acepta
        `ack`: el acuse del visor es el único momento en que el relé acusa al
        demonio (spec §6.4)."""
        viewer = Viewer(ws, max_fps)
        self._viewers.add(viewer)
        viewer.start()
        self._cancel_linger()
        for message in self._snapshot():
            viewer.offer(message)
        self._ensure_daemon()
        try:
            while True:
                seq = _ack_from(await ws.receive_text())
                if seq is not None:
                    await self.on_viewer_ack(viewer, seq)
        except Exception:
            pass  # el visor se fue; lo que mandó no se registra
        finally:
            await self._remove_viewer(viewer)

    async def on_viewer_ack(self, viewer, seq: int) -> None:
        """El visor acusó un frame, y el relé acusa al demonio en ese momento.

        Basta el PRIMER acuse del frame en vuelo, no el de todos los visores: si
        hiciera falta el de todos, el visor más lento marcaría el ritmo del
        demonio y sería el reloj de los demás (Review Focus 3). Un visor lento
        recibe descartes por su tope de fps, y eso es toda su degradación. Los
        acuses son acumulativos, así que uno más nuevo cubre los anteriores."""
        if self._pending_seq is None or seq < self._pending_seq:
            return
        await self._ack_daemon(self._pending_seq)

    async def shutdown(self) -> None:
        """Suelta el socket del demonio y las tareas de todos los visores."""
        self._cancel_linger()
        await self._drop_daemon()
        for viewer in list(self._viewers):
            self._viewers.discard(viewer)
            await viewer.stop()

    # --- reparto ---

    def _snapshot(self) -> list[dict]:
        panel = self._panel
        if panel is None:
            # Todavía no hay socket al demonio, así que el panel no está en vivo.
            return [{"type": "state", "live": False, "collapsed": False}]
        return panel.snapshot_messages()

    def _broadcast(self, message: dict) -> None:
        for viewer in list(self._viewers):
            viewer.offer(message)

    def _fan_out(self, is_frame: bool, messages: list[dict]) -> set[Viewer]:
        """Reparte sin esperar por ningún socket. Devuelve los visores que se
        quedan el frame en vuelo, que son los que tendrán que acusarlo."""
        if not messages:
            return set()
        now = time.monotonic()
        served: set[Viewer] = set()
        for viewer in list(self._viewers):
            if viewer.gone:
                continue
            if is_frame:
                if viewer.offer_frame(messages[0], now):
                    served.add(viewer)
                continue
            for message in messages:
                viewer.offer(message)
        return served

    async def _remove_viewer(self, viewer: Viewer) -> None:
        self._viewers.discard(viewer)
        awaited = viewer in self._pending_viewers
        self._pending_viewers.discard(viewer)
        pending = self._pending_seq
        no_viewers = not self._viewers
        await viewer.stop()
        # Sin ningún visor con el frame en vuelo se acusa igual: si no, el ritmo
        # del demonio quedaría atascado para siempre (spec §6.4).
        if awaited and pending is not None and not self._pending_viewers:
            await self._ack_daemon(pending)
        if no_viewers:
            self._schedule_linger()

    # --- el socket del demonio ---

    def _ensure_daemon(self) -> None:
        task = self._daemon_task
        if task is None or task.done():
            self._daemon_task = asyncio.create_task(self._run_daemon())

    async def _run_daemon(self) -> None:
        """Una era del socket del demonio: lee el puerto, abre el socket, reparte
        y acusa hasta que se cae, y anuncia el cierre.

        El puerto se lee en cada intento. Los reintentos cubren el caso real de
        que el demonio esté arrancando todavía: el panel se abre a la vez que la
        primera herramienta del turno, que es la que lo levanta."""
        connected = False
        for attempt in range(PORT_TRIES):
            port = await self._read_port_safely()
            if port is not None:
                connected = await self._pump_daemon(port)
                if connected:
                    break
            if attempt + 1 < PORT_TRIES:
                await asyncio.sleep(PORT_RETRY_SECONDS)
        await self._announce_gone(
            "socket caído" if connected else "el navegador no está disponible")

    async def _read_port_safely(self) -> int | None:
        """Con plazo propio: en el camino de arranque del panel no hay ningún
        `await` sin plazo, porque un visor que acepta la conexión y no recibe
        nunca nada es peor que un panel que dice que no hay navegador."""
        try:
            return await asyncio.wait_for(self._read_port(), PORT_TIMEOUT)
        except Exception:
            return None  # sin registrar el motivo: arrastraría el stdout del CLI

    async def _pump_daemon(self, port: int) -> bool:
        """Abre el socket local del demonio y consume sus mensajes. Devuelve False
        si no se pudo abrir, para que `_run_daemon` reintente."""
        url = f"ws://127.0.0.1:{port}/?pacing=ack&maxFps={DAEMON_MAX_FPS}"
        try:
            connection = await asyncio.wait_for(
                websockets.connect(url, max_size=MAX_FRAME_BYTES), CONNECT_TIMEOUT)
        except Exception:
            return False
        # El CLI dio el puerto de un stream `enabled` y acabamos de engancharnos
        # con `pacing=ack`: el panel nace en vivo. `stream status` dice
        # `screencasting:false` hasta que un consumidor se engancha, así que
        # sembrarlo de ahí dejaría el panel congelado mientras pinta frames nuevos.
        # El primer `status` del demonio lo corrige si hace falta.
        self._daemon = connection
        self._panel = PanelState(screencasting=True)
        self._broadcast(self._panel.state_message())
        watchdog = asyncio.create_task(self._watch_stall())
        try:
            async for message in connection:
                if isinstance(message, str):  # el stream es JSON en texto (§5.4)
                    await self._on_daemon_text(message)
        except Exception:
            pass  # el socket se cayó; el cuerpo que lo causó no se registra
        finally:
            watchdog.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await watchdog
            self._daemon = None
            with contextlib.suppress(Exception):
                await connection.close()
        return True

    async def _on_daemon_text(self, text: str) -> None:
        """Un mensaje del demonio: se filtra, se aplica al panel, se reparte, y se
        anota el acuse como pendiente. `params` muere en `stream.decode`."""
        decoded = stream.decode(text)
        if decoded is None:
            return
        if decoded.get("kind") == "frame" and decoded.get("captured_at") is None:
            # `stream.decode` es puro y no tiene reloj; el sello lo pone el relé
            # porque el cable fija `captured_at` como número.
            decoded["captured_at"] = time.time()
        panel = self._panel
        was_live = panel.live if panel is not None else False
        if panel is not None:
            panel.apply(decoded)
        messages = stream.wire_messages(decoded)
        if panel is not None and panel.collapsed:
            messages = []  # un panel congelado no vuelve a pintar (spec §6.2(g))
        served = self._fan_out(decoded.get("kind") == "frame", messages)
        seq = stream.ack_seq(decoded)
        if seq is not None:
            self._pending_seq = seq
            self._pending_viewers = served
            self._pending_since = time.monotonic()
            if not served:
                # Nadie se quedó el frame (ilegible, descartado por fps, o sin
                # visores): se acusa ya, o el ritmo se atasca.
                await self._ack_daemon(seq)
        if panel is not None and panel.live != was_live:
            self._broadcast(panel.state_message())

    async def _ack_daemon(self, seq: int) -> None:
        """El único sitio del relé que acusa al demonio."""
        self._pending_seq = None
        self._pending_viewers = set()
        connection = self._daemon
        if connection is None:
            return
        async with self._ack_lock:  # un solo escritor en el socket del demonio
            try:
                await connection.send(json.dumps({"type": "ack", "seq": seq}))
            except Exception:
                return
        panel = self._panel
        if panel is not None and not panel.acking:
            panel.set_acking(True)
            self._broadcast(panel.state_message())

    async def _watch_stall(self) -> None:
        """Vigila el acuse, no la página: un frame en vuelo que ningún visor acusa
        significa que el relé no está acusando, y un panel que no acusa está
        congelado (spec §6.2(f)). No se inventa el acuse para destrabarlo."""
        tick = max(0.01, min(STALL_TICK_SECONDS, self._stall_grace / 2))
        while True:
            await asyncio.sleep(tick)
            panel = self._panel
            if panel is None or self._pending_seq is None or not panel.acking:
                continue
            if time.monotonic() - self._pending_since < self._stall_grace:
                continue
            panel.set_acking(False)
            self._broadcast(panel.state_message())

    async def _announce_gone(self, reason: str) -> None:
        """El socket del demonio ya no está: el panel se marca congelado, suelta su
        imagen dejando la línea de resumen, y los visores se cierran."""
        panel, self._panel = self._panel, None
        self._pending_seq = None
        self._pending_viewers = set()
        if panel is not None:
            panel.socket_closed()
            panel.freeze()
            self._broadcast(panel.state_message())
            self._broadcast(panel.summary_message())
        self._broadcast({"type": "closed", "reason": reason})
        for viewer in list(self._viewers):
            await viewer.flush()
            with contextlib.suppress(Exception):
                await viewer.ws.close()

    # --- el plazo de gracia sin visores ---

    def _schedule_linger(self) -> None:
        task = self._daemon_task
        if task is None or task.done():
            return
        self._cancel_linger()
        self._linger_task = asyncio.create_task(self._linger_then_drop())

    def _cancel_linger(self) -> None:
        task, self._linger_task = self._linger_task, None
        if task is not None:
            task.cancel()

    async def _linger_then_drop(self) -> None:
        await asyncio.sleep(self._linger)
        if self._viewers:
            return
        await self._drop_daemon()

    async def _drop_daemon(self) -> None:
        task, self._daemon_task = self._daemon_task, None
        if task is not None:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        connection, self._daemon = self._daemon, None
        if connection is not None:
            with contextlib.suppress(Exception):
                await connection.close()
        self._panel = None
        self._pending_seq = None
        self._pending_viewers = set()
