"""Validación y ejecución del CLI `agent-browser`.

Este módulo es la frontera de seguridad del servicio: el `argv` llega por red, así
que sin lista de permitidos el endpoint sería ejecución remota de órdenes. Por eso:
  - el subcomando debe estar en ALLOWED_SUBCOMMANDS (`eval` NO está);
  - antes del subcomando solo se aceptan los flags globales de GLOBAL_FLAGS, para que
    un flag desconocido con valor no desplace al subcomando que el CLI real vería;
  - se rechazan los flags que leen o escriben ficheros del disco del servidor;
  - el proceso se lanza con `create_subprocess_exec` (la lista entera llega a
    execve, nunca pasa por un shell) y `stdin` viaja aparte, nunca en `argv`.
"""
import asyncio
import json
import os
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
REJECTED_FLAG_PREFIXES: tuple[str, ...] = (
    "--action-policy",
    "--state",
    "--profile",
    "--init-scripts",
    "--extensions",
    "--executable-path",
    "--config",
    "--args",
    "--download-path",
    "--cdp",
    "--auto-connect",
    "--provider",
    "--allow-file-access",
)

# Flags globales permitidos antes del subcomando, con el número de valores que toman.
GLOBAL_FLAGS: dict[str, int] = {"--session": 1, "--json": 0}

_FAKE_ENVELOPE = '{"success":true,"data":{},"error":null}'


def validate(arguments: list[str], stdin: str | None = None) -> None:
    """Lanza ValueError con el motivo si el `argv` (y el `stdin`) no son aceptables.

    Nota de diseño: se rechaza cualquier argumento, también un posicional como el
    texto de `fill`, que empiece por un prefijo de REJECTED_FLAG_PREFIXES. Falla
    cerrado a propósito: los valores sensibles viajan por `stdin`, no por argv."""
    if not arguments:
        raise ValueError("arguments vacío")

    for argument in arguments:
        if argument.startswith(REJECTED_FLAG_PREFIXES):
            raise ValueError(f"flag no permitido por red: {argument}")

    i = 0
    while i < len(arguments) and arguments[i].startswith("-"):
        flag = arguments[i]
        if flag not in GLOBAL_FLAGS:
            raise ValueError(f"flag no permitido antes del subcomando: {flag}")
        i += 1 + GLOBAL_FLAGS[flag]
        if i > len(arguments):
            raise ValueError(f"falta el valor de {flag}")

    if i >= len(arguments):
        raise ValueError("falta el subcomando")
    subcommand = arguments[i]
    if subcommand not in ALLOWED_SUBCOMMANDS:
        raise ValueError(f"subcomando no permitido: {subcommand}")

    if subcommand == "batch":
        validate_batch_payload(arguments[i + 1:], stdin)


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
            continue  # opciones de batch (--bail, --json, --omit-command)
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


async def run(arguments: list[str], timeout: float, stdin: str | None = None) -> dict:
    """Ejecuta el CLI y devuelve {"exitCode", "stdout", "stderr"}.
    No valida: quien llama desde la red debe llamar a `validate` antes."""
    if os.environ.get("BROWSER_FAKE_CLI") == "1":
        return {"exitCode": 0, "stdout": _FAKE_ENVELOPE, "stderr": ""}

    # stdout y stderr van a ficheros temporales y no a pipes: el CLI deja un demonio
    # vivo que hereda esos descriptores, y con pipes `communicate()` no vuelve hasta
    # que el demonio muere (verificado en vivo: cada llamada agotaba el plazo).
    # Con ficheros basta esperar a que salga el CLI.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        process = await asyncio.create_subprocess_exec(
            BROWSER_BIN, *arguments,
            stdin=asyncio.subprocess.PIPE if stdin is not None else asyncio.subprocess.DEVNULL,
            stdout=out,
            stderr=err,
            env=os.environ.copy(),
        )
        try:
            if stdin is not None:
                try:
                    process.stdin.write(stdin.encode())
                    await process.stdin.drain()
                except (BrokenPipeError, ConnectionResetError):
                    pass  # el CLI salió sin leer todo el stdin; el código de salida lo dirá
                finally:
                    process.stdin.close()
            await asyncio.wait_for(process.wait(), timeout=timeout)
        except asyncio.TimeoutError:
            try:
                process.kill()
            except ProcessLookupError:
                pass  # salió justo entre el plazo y el kill
            await process.wait()
            return {"exitCode": -1, "stdout": "", "stderr": f"timeout tras {timeout}s"}
        out.seek(0)
        err.seek(0)
        return {
            "exitCode": process.returncode,
            "stdout": out.read().decode(errors="replace"),
            "stderr": err.read().decode(errors="replace"),
        }
