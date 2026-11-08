"""Pruebas de forma del docker-compose.browser.yml.

No se usa PyYAML a propósito: no está en requirements.txt y añadirlo metería una
dependencia de pruebas en la imagen de producción. El fichero bajo prueba lo
escribimos nosotros, así que `_config()` lo lee con un parseo de líneas mínimo
(mapas, listas de escalares y listas en línea). La validación real del YAML la
hace `docker compose config`.

Limitaciones a tener presentes al editar el compose:
- No admite comentarios en línea: `- FOO=bar # nota` metería la nota dentro del
  valor. Los comentarios van en su propia línea.
- Una sangría incoherente NO se ignora: `_config()` lanza ValueError si quedan
  líneas sin consumir, para que las aserciones negativas no pasen en falso.
"""
import json
import pathlib

import pytest

_RAIZ = pathlib.Path(__file__).parent.parent
_COMPOSE = _RAIZ / "docker-compose.browser.yml"


def _escalar(texto):
    texto = texto.strip()
    if texto.startswith("["):
        return json.loads(texto)  # lista en línea: ["CMD", "curl", ...]
    if len(texto) >= 2 and texto[0] == texto[-1] and texto[0] in "\"'":
        return texto[1:-1]
    return texto


def _lineas_utiles(texto):
    salida = []
    for cruda in texto.splitlines():
        if not cruda.strip() or cruda.lstrip().startswith("#"):
            continue
        salida.append((len(cruda) - len(cruda.lstrip()), cruda.strip()))
    return salida


def _bloque(lineas, i, sangria):
    """Parsea desde lineas[i] un bloque con esa sangría; devuelve (valor, i)."""
    if lineas[i][1].startswith("- "):
        lista = []
        while i < len(lineas) and lineas[i][0] == sangria and lineas[i][1].startswith("- "):
            lista.append(_escalar(lineas[i][1][2:]))
            i += 1
        return lista, i
    mapa = {}
    while i < len(lineas) and lineas[i][0] == sangria:
        clave, _, resto = lineas[i][1].partition(":")
        i += 1
        if resto.strip():
            mapa[clave] = _escalar(resto)
        elif i < len(lineas) and lineas[i][0] > sangria:
            mapa[clave], i = _bloque(lineas, i, lineas[i][0])
        else:
            mapa[clave] = None
    return mapa, i


def _parsear(texto: str) -> dict:
    lineas = _lineas_utiles(texto)
    valor, i = _bloque(lineas, 0, lineas[0][0])
    if i != len(lineas):
        # Sin esto, una línea mal indentada cortaría el parseo en silencio y las
        # aserciones "X not in env" pasarían aunque X esté en el fichero.
        raise ValueError(f"sangría incoherente cerca de: {lineas[i][1]!r}")
    return valor


def _config() -> dict:
    return _parsear(_COMPOSE.read_text())


def _env_del_servicio(nombre: str) -> dict:
    env = {}
    for item in _config()["services"][nombre].get("environment", []):
        clave, _, valor = item.partition("=")
        env[clave] = valor
    return env


def test_el_compose_declara_las_claves_que_el_servicio_lee():
    env = _env_del_servicio("browser")
    assert env["BROWSER_STREAM_SESSION"] == "gemma"
    assert env["AGENT_BROWSER_EXECUTABLE_PATH"] == "/usr/bin/chromium"
    assert env["AGENT_BROWSER_SOCKET_DIR"] == "/run/agent-browser"
    assert env["AGENT_BROWSER_IDLE_TIMEOUT_MS"] == "1800000"
    assert env["AGENT_BROWSER_NO_VERSION_CHECK"] == "1"
    assert "AGENT_BROWSER_NO_XVFB" not in env  # en Linux el CLI usa Xvfb


def test_el_token_viene_del_env_file_y_no_tiene_valor_por_omision():
    # Un valor por omisión aquí convertiría el servicio en abierto. Sin token,
    # require_bearer da 401 en todo, y eso es lo correcto.
    assert ".env" in _config()["services"]["browser"]["env_file"]
    assert "BROWSER_BEARER_TOKEN" not in _env_del_servicio("browser")


def test_el_puerto_y_el_healthcheck_son_los_del_servicio_desplegado():
    svc = _config()["services"]["browser"]
    assert "8083:8083" in svc["ports"]
    assert "http://localhost:8083/healthz" in " ".join(svc["healthcheck"]["test"])
    assert svc["restart"] == "unless-stopped"


def test_el_env_example_declara_el_token_sin_ningun_valor():
    # Una línea NO comentada `BROWSER_BEARER_TOKEN=` con el resto vacío: ni un
    # valor real, ni un placeholder, ni la variable comentada.
    texto = (pathlib.Path(__file__).parent / ".env.example").read_text()
    lineas = [l.strip() for l in texto.splitlines() if not l.strip().startswith("#")]
    asignaciones = [l for l in lineas if l.startswith("BROWSER_BEARER_TOKEN=")]
    assert len(asignaciones) == 1
    assert asignaciones[0].partition("=")[2] == ""
    assert "replace-me" not in texto  # no se hereda el placeholder de la memoria


def test_una_sangria_incoherente_hace_fallar_el_parseo():
    # La línea del token está mal indentada a propósito: el parseo no puede
    # perderla en silencio, porque entonces "token not in env" pasaría en falso.
    roto = (
        "services:\n"
        "  browser:\n"
        "    environment:\n"
        "      - TZ=America/Havana\n"
        "     - BROWSER_BEARER_TOKEN=abc\n"
    )
    with pytest.raises(ValueError):
        _parsear(roto)
