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
# El compose de la raíz TAMBIÉN define un servicio `browser` (el README manda
# levantar desde ahí). Los dos tienen que decir lo mismo en nitidez.
_COMPOSE_RAIZ = _RAIZ / "docker-compose.yml"
_NITIDEZ = ("AGENT_BROWSER_STREAM_MAX_WIDTH", "AGENT_BROWSER_STREAM_MAX_HEIGHT",
            "AGENT_BROWSER_STREAM_QUALITY")


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
        if clave in mapa:
            # Sin esto el segundo bloque sobrescribiría al primero en silencio: un
            # `environment:` repetido dejaría el token en el primero y las pruebas
            # verdes, porque solo verían el segundo.
            raise ValueError(f"clave duplicada {clave!r} en el mismo nivel")
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


def _config(fichero=_COMPOSE) -> dict:
    return _parsear(fichero.read_text())


def _env_del_servicio(nombre: str, fichero=_COMPOSE) -> dict:
    env = {}
    for item in _config(fichero)["services"][nombre].get("environment", []):
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


def test_la_nitidez_es_la_medida_no_la_heredada():
    # Candado de regresión. Estos números salen de la medición de 25 fotogramas por
    # combinación sobre una página de resultados real; está en el repositorio
    # personal_agent, en la nota (se cita la ruta y no un SHA, que un squash borra):
    #   docs/superpowers/notes/2026-11-08-medicion-nitidez-panel.md
    # Si alguien los cambia sin medir, esta prueba se pone roja y le obliga a leerla.
    # (Los 640x360 q20 heredados daban un panel borroso.)
    env = _env_del_servicio("browser")
    assert env["AGENT_BROWSER_STREAM_MAX_WIDTH"] == "1080"
    assert env["AGENT_BROWSER_STREAM_MAX_HEIGHT"] == "608"
    assert env["AGENT_BROWSER_STREAM_QUALITY"] == "45"
    # Valores fuera de rango no pueden llegar al demonio.
    assert 1 <= int(env["AGENT_BROWSER_STREAM_QUALITY"]) <= 100
    # Cota de CORDURA, no una verdad del universo: ancho 320..1920, alto 180..1080.
    # Atrapa un 4000x4000 o un 10x10 por un cero de más o de menos. Un valor fuera
    # de la cota obliga a MEDIR de nuevo (y a justificarlo en la nota), no a
    # ensanchar la cota.
    assert 320 <= int(env["AGENT_BROWSER_STREAM_MAX_WIDTH"]) <= 1920
    assert 180 <= int(env["AGENT_BROWSER_STREAM_MAX_HEIGHT"]) <= 1080


def test_los_dos_composes_dicen_lo_mismo_en_nitidez():
    # El servicio `browser` está definido en docker-compose.browser.yml Y en el
    # docker-compose.yml de la raíz. Si solo se actualiza uno, quien levante desde
    # el otro (el README manda la raíz) obtiene el panel borroso que esta rama
    # arregló. Esta prueba es la que impide que vuelvan a divergir.
    a = _env_del_servicio("browser", _COMPOSE)
    b = _env_del_servicio("browser", _COMPOSE_RAIZ)
    for clave in _NITIDEZ:
        assert clave in a and clave in b, clave
        assert a[clave] == b[clave], f"{clave}: {a[clave]!r} vs {b[clave]!r}"


def test_el_compose_de_la_raiz_conserva_su_token_propio_y_sin_literal():
    # Diferencia deliberada respecto a docker-compose.browser.yml (ver el comentario
    # del servicio en la raíz): el token viene del `.env` de la raíz como secreto
    # PROPIO del navegador, nunca escrito en el fichero ni el de la memoria. La
    # prueba de coincidencia de nitidez NO debe llevar a «uniformar» esto.
    env = _env_del_servicio("browser", _COMPOSE_RAIZ)
    assert env["BROWSER_BEARER_TOKEN"] == "${BROWSER_BEARER_TOKEN}"


def test_una_clave_duplicada_en_el_mismo_nivel_hace_fallar_el_parseo():
    # Escenario real: el token en un primer `environment:` y las claves de stream
    # en un segundo. Sin el aviso, el segundo sobrescribe al primero y
    # «el token no está en el env» pasa en verde con el token escrito en el fichero.
    roto = (
        "services:\n"
        "  browser:\n"
        "    environment:\n"
        "      - BROWSER_BEARER_TOKEN=abc\n"
        "    environment:\n"
        "      - AGENT_BROWSER_STREAM_QUALITY=45\n"
    )
    with pytest.raises(ValueError, match="duplicada"):
        _parsear(roto)
