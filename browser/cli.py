"""Validación y ejecución del CLI `agent-browser`.

Este módulo es la frontera de seguridad del servicio: el `argv` llega por red, así
que sin lista de permitidos el endpoint sería ejecución remota de órdenes. Por eso:
  - el subcomando debe estar en ALLOWED_SUBCOMMANDS (`eval` NO está);
  - los flags son una LISTA DE PERMITIDOS por subcomando (FLAGS_BY_SUBCOMMAND) más
    los globales (GLOBAL_FLAGS), en cualquier posición: el CLI acepta flags antes y
    después del subcomando, así que validar solo los de antes no basta. Cualquier
    argumento que empiece por `-` y no esté en la tabla se rechaza. Una lista de
    prohibidos no sirve: el CLI tiene flags que ejecutan JavaScript
    (`--init-script`, `--restore-check-fn`, `wait --fn`) o cargan código del disco;
  - REJECTED_FLAG_PREFIXES queda como segunda capa (defensa en profundidad);
  - `stream` solo admite `status`: `enable`/`disable` cambian el servidor de
    streaming del contenedor y no se ofrecen por red;
  - el proceso se lanza con `create_subprocess_exec` (la lista entera llega a
    execve, nunca pasa por un shell) y `stdin` viaja aparte, nunca en `argv`.
"""
import asyncio
import json
import os
import re
import shlex
import tempfile

# Ruta del CLI; misma variable que lee app.py.
BROWSER_BIN = os.environ.get("AGENT_BROWSER_BIN", "agent-browser")

ALLOWED_SUBCOMMANDS: frozenset[str] = frozenset({
    "open", "read", "click", "fill", "press", "wait", "get",
    "close", "snapshot", "stream", "batch",
})

# Flags que apuntan a ficheros, procesos o navegadores del servidor, o que cargan
# código: no se aceptan por red en ninguna posición.
# Segunda capa: flags que leen/escriben ficheros del servidor, cargan código o
# ejecutan JavaScript. La defensa real es la tabla de permitidos de abajo; esto
# solo atrapa un error futuro en esa tabla. Los nombres son los de los FLAGS
# (singulares: --init-script, --extension), no los de las variables de entorno.
REJECTED_FLAG_PREFIXES: tuple[str, ...] = (
    "--action-policy",
    "--state",
    "--profile",
    "--init-script",
    "--extension",
    "--restore",
    "--restore-check-fn",
    "--executable-path",
    "--config",
    "--args",
    "--download-path",
    "--cdp",
    "--auto-connect",
    "--provider",
    "-p",
    "--allow-file-access",
    "--fn",
    "--headers",
    "--proxy",
)

# Flags globales permitidos en cualquier posición, con el número de valores que toman.
# Origen: AgentBrowserService.run antepone `--session <nombre>` y añade `--json`.
GLOBAL_FLAGS: dict[str, int] = {"--session": 1, "--json": 0}

# Flags propios de cada subcomando, con su aridad. Origen: los sitios de llamada de
# la app (Gemma/NativeServices/Browser*Tools.swift, ReadWebpageTool.swift) contrastados
# con `agent-browser <subcomando> --help` (0.41.2). Deliberadamente fuera: `wait --fn`
# (ejecuta JS), `wait --state` (colisiona con el flag global de ruta de estado),
# `read --llms/--require-md/--raw`, `snapshot --depth/--compact/--urls`.
FLAGS_BY_SUBCOMMAND: dict[str, dict[str, int]] = {
    "open": {},
    "read": {"--outline": 0, "--filter": 1},
    "click": {},
    "fill": {},
    "press": {},
    "wait": {"--text": 1, "--url": 1},
    "get": {},
    "close": {},
    "snapshot": {"-i": 0, "-s": 1},
    "stream": {},
    "batch": {"--bail": 0, "--omit-command": 0},
}

# Primer argumento posicional permitido tras el subcomando, cuando el subcomando
# tiene sub-subcomandos. `stream` solo `status`: `enable` abre un servidor dentro
# del contenedor y `disable` tumba el panel. `get`: los datos que lee la app.
ALLOWED_SECOND_WORD: dict[str, frozenset[str]] = {
    "stream": frozenset({"status"}),
    "get": frozenset({"text", "html", "value", "title", "url", "count"}),
}

# Esquemas de URL que `open` y `read` aceptan. Lista de permitidos: file:, data:,
# javascript:, chrome:, about:, view-source:, ftp: y cualquier otro quedan fuera.
# Verificado contra el CLI 0.41.2: `open file:///etc/passwd` NO lo bloquea el CLI
# (devuelve success y luego `get text body` leería el fichero); `read` sí.
ALLOWED_URL_PREFIXES: tuple[str, ...] = ("http://", "https://")

# Nombre de sesión: el CLI puede usarlo para construir la ruta del socket
# (AGENT_BROWSER_SOCKET_DIR), así que nada de `/`, `..` ni caracteres raros.
SESSION_NAME_PATTERN = re.compile(r"[A-Za-z0-9_-]{1,64}")

_FAKE_ENVELOPE = '{"success":true,"data":{},"error":null}'


def validate(arguments: list[str], stdin: str | None = None) -> None:
    """Lanza ValueError con el motivo si el `argv` (y el `stdin`) no son aceptables.

    Se rechaza cualquier argumento, también un posicional como el texto de `fill`,
    que empiece por un prefijo de REJECTED_FLAG_PREFIXES o que empiece por `-` y no
    esté en la tabla de flags. Falla cerrado a propósito (la app ya rechaza valores
    con aspecto de flag): los valores sensibles viajan por `stdin`, no por argv."""
    if not arguments:
        raise ValueError("arguments vacío")

    for argument in arguments:
        if argument.startswith(REJECTED_FLAG_PREFIXES):
            raise ValueError(f"flag no permitido por red: {argument}")

    subcommand: str | None = None
    positionals: list[str] = []
    i = 0
    while i < len(arguments):
        argument = arguments[i]
        i += 1
        if not argument.startswith("-"):
            if subcommand is None:
                if argument not in ALLOWED_SUBCOMMANDS:
                    raise ValueError(f"subcomando no permitido: {argument}")
                subcommand = argument
            else:
                positionals.append(argument)
            continue
        # Antes del subcomando solo valen los globales; después, también los suyos.
        arity = GLOBAL_FLAGS.get(argument)
        if arity is None and subcommand is not None:
            arity = FLAGS_BY_SUBCOMMAND[subcommand].get(argument)
        if arity is None:
            raise ValueError(f"flag no permitido: {argument}")
        for _ in range(arity):
            if i >= len(arguments):
                raise ValueError(f"falta el valor de {argument}")
            if arguments[i].startswith("-"):
                # Un valor con forma de flag haría que el CLI lo interprete de otra manera.
                raise ValueError(f"el valor de {argument} parece un flag: {arguments[i]}")
            valor = arguments[i]
            if argument == "--session" and not SESSION_NAME_PATTERN.fullmatch(valor):
                raise ValueError("nombre de --session no permitido: solo letras, dígitos, - y _ (máx. 64)")
            i += 1

    if subcommand is None:
        raise ValueError("falta el subcomando")

    if subcommand in ("open", "read") and positionals:
        _validate_url(positionals[0])

    permitidas = ALLOWED_SECOND_WORD.get(subcommand)
    if permitidas is not None:
        segunda = positionals[0] if positionals else None
        if segunda not in permitidas:
            raise ValueError(
                f"{subcommand} {segunda or ''}".strip()
                + f" no permitido; solo: {', '.join(sorted(permitidas))}")

    if subcommand == "batch":
        validate_batch_payload(positionals, stdin)


def _validate_url(url: str) -> None:
    """Solo http:// y https://. Se ignoran mayúsculas y espacios/control al principio,
    que el navegador también ignora (" FILE:///x", "file:/etc/passwd" no pasan)."""
    normalizada = url.lstrip().lower()
    if not normalizada.startswith(ALLOWED_URL_PREFIXES):
        esquema = normalizada.split(":", 1)[0] if ":" in normalizada else "(sin esquema)"
        raise ValueError(f"esquema de URL no permitido: {esquema}; solo http y https")


def validate_batch_payload(batch_arguments: list[str], stdin: str | None) -> None:
    """Valida las órdenes que `batch` ejecutará, que llegan de dos formas:
      - modo argumentos: cada argumento posicional es una orden completa
        ("open https://a.test");
      - modo stdin: un JSON con un arreglo de arreglos de strings.
    Cada orden pasa por `validate`, así que `eval` queda fuera por esta vía igual
    que por argv. Sin ninguna orden, se rechaza."""
    commands: list[list[str]] = []

    for argument in batch_arguments:
        if argument.startswith("-"):
            continue  # las opciones de batch ya las validó `validate`
        try:
            tokens = shlex.split(argument)
        except ValueError as motivo:
            raise ValueError(f"orden de batch ilegible: {motivo}")
        commands.append(tokens)

    if stdin is not None:
        try:
            payload = json.loads(stdin)
        except ValueError as motivo:
            raise ValueError(f"stdin de batch no es JSON válido: {motivo}")
        if not isinstance(payload, list):
            raise ValueError("stdin de batch debe ser un arreglo de órdenes")
        for command in payload:
            if not isinstance(command, list) or not all(isinstance(t, str) for t in command):
                raise ValueError("cada orden de batch debe ser un arreglo de strings")
            commands.append(command)

    if not commands:
        raise ValueError("batch sin órdenes")
    for command in commands:
        validate(command)


def _temp_dir() -> str | None:
    """tmpfs si existe (en el contenedor): lo que el CLI escriba por stdout no toca
    el disco. Fuera del contenedor (pruebas en Mac) se usa el directorio por omisión."""
    return "/dev/shm" if os.path.isdir("/dev/shm") else None


async def _write_stdin_and_wait(process, stdin: str | None) -> None:
    if stdin is not None:
        try:
            process.stdin.write(stdin.encode())
            await process.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass  # el CLI salió sin leer todo el stdin; el código de salida lo dirá
        finally:
            process.stdin.close()
    await process.wait()


async def run(arguments: list[str], timeout: float, stdin: str | None = None) -> dict:
    """Ejecuta el CLI y devuelve {"exitCode", "stdout", "stderr"}.
    No valida: quien llama desde la red debe llamar a `validate` antes."""
    if os.environ.get("BROWSER_FAKE_CLI") == "1":
        return {"exitCode": 0, "stdout": _FAKE_ENVELOPE, "stderr": ""}

    # stdout y stderr van a ficheros temporales y no a pipes: el CLI deja un demonio
    # vivo que hereda esos descriptores, y con pipes `communicate()` no vuelve hasta
    # que el demonio muere (verificado en vivo: cada llamada agotaba el plazo).
    # Con ficheros basta esperar a que salga el CLI.
    with tempfile.TemporaryFile(dir=_temp_dir()) as out, \
            tempfile.TemporaryFile(dir=_temp_dir()) as err:
        process = await asyncio.create_subprocess_exec(
            BROWSER_BIN, *arguments,
            stdin=asyncio.subprocess.PIPE if stdin is not None else asyncio.subprocess.DEVNULL,
            stdout=out,
            stderr=err,
            env=os.environ.copy(),
        )
        try:
            # La escritura del stdin y la espera comparten UN plazo: si el hijo no
            # lee su stdin, `drain()` no puede colgar la petición.
            await asyncio.wait_for(_write_stdin_and_wait(process, stdin), timeout=timeout)
        except asyncio.TimeoutError:
            return {"exitCode": -1, "stdout": "", "stderr": f"timeout tras {timeout}s"}
        finally:
            # Plazo, cancelación del cliente o cualquier excepción: no queda el CLI
            # vivo. Solo se mata el proceso, no su grupo: el demonio que el CLI deja
            # a propósito debe sobrevivir.
            if process.returncode is None:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
                await process.wait()
        out.seek(0)
        err.seek(0)
        return {
            "exitCode": process.returncode,
            "stdout": out.read().decode(errors="replace"),
            "stderr": err.read().decode(errors="replace"),
        }
