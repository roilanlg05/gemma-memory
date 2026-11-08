"""Pruebas de forma del docker-compose.browser.yml.

No se usa PyYAML a propósito: no está en requirements.txt y añadirlo metería una
dependencia de pruebas en la imagen de producción. El fichero bajo prueba lo
escribimos nosotros, así que `_config()` lo lee con un parseo de líneas mínimo
(mapas, listas de escalares y listas en línea). La validación real del YAML la
hace `docker compose config`.
"""
import json
import pathlib

_RAIZ = pathlib.Path(__file__).parent.parent
_COMPOSE = _RAIZ / "docker-compose.browser.yml"


def _escalar(texto):
    texto = texto.strip()
    if texto.startswith("["):
        return json.loads(texto)  # lista en línea: ["CMD", "curl", ...]
    if len(texto) >= 2 and texto[0] == texto[-1] and texto[0] in "\"'":
        return texto[1:-1]
    return texto


def _lineas_utiles():
    salida = []
    for cruda in _COMPOSE.read_text().splitlines():
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


def _config() -> dict:
    lineas = _lineas_utiles()
    valor, _ = _bloque(lineas, 0, lineas[0][0])
    return valor


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


def test_el_env_example_nombra_el_token_sin_traer_un_valor():
    texto = (pathlib.Path(__file__).parent / ".env.example").read_text()
    assert "BROWSER_BEARER_TOKEN=" in texto
    assert "replace-me" not in texto  # no se hereda el placeholder de la memoria
