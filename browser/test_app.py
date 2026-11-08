"""Pruebas del servicio de navegador. Correr con:
    python3 -m pytest browser/test_app.py -v
Usa BROWSER_FAKE_CLI=1 para no lanzar el binario de verdad."""
import asyncio, base64, contextlib, json, os, sys, time
import pytest
os.environ["BROWSER_FAKE_CLI"] = "1"
os.environ["BROWSER_BEARER_TOKEN"] = "test-token"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import websockets
from fastapi import WebSocketDisconnect
from fastapi.testclient import TestClient
import app as appmod
import relay
from relay import PanelState

client = TestClient(appmod.app)
AUTH = {"Authorization": "Bearer test-token"}


def test_healthz_no_pide_token():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_invoke_sin_token_devuelve_401():
    r = client.post("/v1/browser/invoke", json={"arguments": ["stream", "status"]})
    assert r.status_code == 401


def test_invoke_con_token_malo_devuelve_401():
    r = client.post("/v1/browser/invoke",
                    json={"arguments": ["stream", "status"]},
                    headers={"Authorization": "Bearer otro"})
    assert r.status_code == 401


# --- validación ---
def test_rechaza_un_subcomando_que_no_esta_en_la_lista():
    r = client.post("/v1/browser/invoke", json={"arguments": ["eval", "1+1"]}, headers=AUTH)
    assert r.status_code == 400
    assert "eval" in r.json()["detail"]


def test_rechaza_algo_que_no_es_del_cli():
    r = client.post("/v1/browser/invoke", json={"arguments": ["rm", "-rf", "/"]}, headers=AUTH)
    assert r.status_code == 400


def test_rechaza_argumentos_vacios():
    assert client.post("/v1/browser/invoke", json={"arguments": []}, headers=AUTH).status_code == 400


def test_rechaza_flags_que_apuntan_a_ficheros_del_contenedor():
    # --action-policy y --state leen del disco del i3: no se aceptan por red.
    for flag in ["--action-policy", "--state", "--profile", "--init-scripts", "--extensions"]:
        r = client.post("/v1/browser/invoke",
                        json={"arguments": ["open", "https://a.test", flag, "/etc/passwd"]},
                        headers=AUTH)
        assert r.status_code == 400, flag


def test_rechaza_flags_con_valor_pegado_por_igual():
    r = client.post("/v1/browser/invoke",
                    json={"arguments": ["open", "https://a.test", "--state=/etc/passwd"]},
                    headers=AUTH)
    assert r.status_code == 400


def test_el_subcomando_se_busca_en_el_primer_positional_no_en_un_flag():
    # "--session gemma open ..." es la forma que arma AgentBrowserService.
    r = client.post("/v1/browser/invoke",
                    json={"arguments": ["--session", "gemma", "open", "https://a.test", "--json"]},
                    headers=AUTH)
    assert r.status_code == 200


def test_el_valor_de_session_no_se_toma_por_subcomando():
    # "--session eval open ..." : eval es el valor del flag, el subcomando es open.
    r = client.post("/v1/browser/invoke",
                    json={"arguments": ["--session", "eval", "open", "https://a.test"]},
                    headers=AUTH)
    assert r.status_code == 200


def test_session_sin_valor_se_rechaza():
    r = client.post("/v1/browser/invoke", json={"arguments": ["--session"]}, headers=AUTH)
    assert r.status_code == 400


# --- ejecución ---
def test_devuelve_el_envelope_del_cli_tal_cual():
    # Con BROWSER_FAKE_CLI=1 el ejecutor devuelve un envelope fijo sin lanzar nada.
    r = client.post("/v1/browser/invoke",
                    json={"arguments": ["stream", "status", "--json"]}, headers=AUTH)
    body = r.json()
    assert body["exitCode"] == 0
    assert '"success"' in body["stdout"], "el stdout del CLI se pasa sin interpretar"


def test_el_argv_llega_al_ejecutor_sin_shell(monkeypatch):
    visto = {}

    async def falso(arguments, timeout, stdin=None):
        visto["arguments"] = arguments
        return {"exitCode": 0, "stdout": "{}", "stderr": ""}

    monkeypatch.setattr(appmod.cli, "run", falso)
    client.post("/v1/browser/invoke",
                json={"arguments": ["open", "https://a.test; rm -rf /"]}, headers=AUTH)
    assert visto["arguments"] == ["open", "https://a.test; rm -rf /"], \
        "la lista llega entera a execve: nunca pasa por un shell"


def test_stdin_se_pasa_al_proceso_y_no_al_argv(monkeypatch):
    # El sub-proyecto de secretos necesita el modo stdin de `batch`: el valor NO
    # puede ir en argv porque `ps` lo lee. Esta prueba fija el camino desde ya.
    visto = {}

    async def falso(arguments, timeout, stdin=None):
        visto.update(arguments=arguments, stdin=stdin)
        return {"exitCode": 0, "stdout": "{}", "stderr": ""}

    monkeypatch.setattr(appmod.cli, "run", falso)
    # La carga debe ser un batch válido (arreglo de órdenes): una de otra forma ya
    # se rechaza antes de ejecutar, por la validación de la carga de batch.
    carga = '[["fill","#clave","valor-secreto"]]'
    client.post("/v1/browser/invoke",
                json={"arguments": ["batch", "--json"], "stdin": carga}, headers=AUTH)
    assert visto["stdin"] == carga
    assert "secreto" not in " ".join(visto["arguments"])


def test_el_ejecutor_real_usa_exec_y_no_shell():
    import cli
    import inspect
    fuente = inspect.getsource(cli)
    assert "create_subprocess_exec" in fuente
    assert "create_subprocess_shell" not in fuente


def test_el_ejecutor_no_espera_al_demonio_que_hereda_los_descriptores(monkeypatch, tmp_path):
    # El CLI real deja un demonio vivo que hereda stdout; con pipes, run() esperaba
    # al demonio y agotaba el plazo en cada llamada. Aquí un guion imita ese caso.
    import asyncio, time, cli
    guion = tmp_path / "falso-cli"
    guion.write_text('#!/bin/sh\n(sleep 5 &)\necho \'{"success":true}\'\n')
    guion.chmod(0o755)
    monkeypatch.setenv("BROWSER_FAKE_CLI", "0")
    monkeypatch.setattr(cli, "BROWSER_BIN", str(guion))
    inicio = time.monotonic()
    resultado = asyncio.run(cli.run(["open", "https://a.test"], timeout=3))
    assert time.monotonic() - inicio < 2, "no debe esperar al demonio"
    assert resultado == {"exitCode": 0, "stdout": '{"success":true}\n', "stderr": ""}


# --- carga de batch: la lista de permitidos también aplica a lo que batch ejecuta ---
def _batch(**cuerpo):
    return client.post("/v1/browser/invoke", json=cuerpo, headers=AUTH)


def test_batch_con_una_orden_eval_en_stdin_se_rechaza():
    r = _batch(arguments=["batch", "--json"], stdin='[["open","https://a.test"],["eval","1+1"]]')
    assert r.status_code == 400
    assert "eval" in r.json()["detail"]


def test_batch_con_solo_ordenes_permitidas_en_stdin_pasa():
    r = _batch(arguments=["batch", "--json"],
               stdin='[["open","https://a.test"],["snapshot","-i"],["fill","#c","valor"]]')
    assert r.status_code == 200


def test_batch_con_stdin_que_no_es_json_se_rechaza():
    assert _batch(arguments=["batch"], stdin="esto no es json").status_code == 400


def test_batch_con_stdin_de_forma_incorrecta_se_rechaza():
    assert _batch(arguments=["batch"], stdin='{"open":"x"}').status_code == 400
    assert _batch(arguments=["batch"], stdin='["open"]').status_code == 400
    assert _batch(arguments=["batch"], stdin='[[1,2]]').status_code == 400


def test_batch_con_flag_prohibido_dentro_de_una_orden_se_rechaza():
    r = _batch(arguments=["batch"], stdin='[["open","https://a.test","--state","/etc/passwd"]]')
    assert r.status_code == 400


def test_batch_en_modo_argumentos_tambien_se_valida():
    assert _batch(arguments=["batch", "open https://a.test", "eval 1"]).status_code == 400
    assert _batch(arguments=["batch", "--bail", "open https://a.test", "snapshot"]).status_code == 200


def test_batch_sin_ordenes_se_rechaza():
    assert _batch(arguments=["batch", "--json"]).status_code == 400


def test_validate_batch_payload_se_prueba_sola():
    import cli
    cli.validate_batch_payload([], '[["open","https://a.test"]]')
    with pytest.raises(ValueError, match="eval"):
        cli.validate_batch_payload([], '[["eval","1"]]')


# --- lista de permitidos de flags, en cualquier posición ---
def _invoca(*arguments, stdin=None):
    return client.post("/v1/browser/invoke",
                       json={"arguments": list(arguments), "stdin": stdin}, headers=AUTH).status_code


def test_rechaza_init_script_que_carga_javascript_del_disco():
    assert _invoca("open", "https://a.test", "--init-script", "/ruta/x.js") == 400


def test_rechaza_extension_que_carga_codigo_del_disco():
    assert _invoca("open", "https://a.test", "--extension", "/ruta/dir") == 400


def test_rechaza_restore_check_fn_con_javascript_en_la_linea_de_ordenes():
    assert _invoca("open", "https://a.test", "--restore", "k",
                   "--restore-check-fn", "fetch('http://x')") == 400


def test_rechaza_la_forma_corta_de_provider():
    assert _invoca("open", "https://a.test", "-p", "browserbase") == 400


def test_rechaza_un_flag_inventado_en_cualquier_posicion():
    assert _invoca("open", "https://a.test", "--loquesea") == 400
    assert _invoca("--loquesea", "open", "https://a.test") == 400


def test_rechaza_wait_fn_que_ejecuta_javascript():
    assert _invoca("wait", "--fn", "document.title") == 400


def test_rechaza_flags_de_red_sin_permiso():
    for flag in ["--proxy", "--headers", "--ca-cert", "--namespace", "--engine"]:
        assert _invoca("open", "https://a.test", flag, "x") == 400, flag


def test_un_flag_es_valido_solo_en_el_subcomando_que_lo_declara():
    assert _invoca("snapshot", "-i", "--json") == 200
    assert _invoca("open", "https://a.test", "-i") == 400


def test_un_valor_con_forma_de_flag_se_rechaza():
    assert _invoca("wait", "--text", "--fn") == 400


def test_batch_rechaza_flags_peligrosos_dentro_de_sus_ordenes():
    carga = '[["open","https://a.test","--init-script","/x.js"]]'
    assert _invoca("batch", stdin=carga) == 400


def test_stream_enable_y_disable_se_rechazan_y_status_pasa():
    assert _invoca("--session", "gemma", "stream", "status", "--json") == 200
    r = client.post("/v1/browser/invoke",
                    json={"arguments": ["--session", "gemma", "stream", "enable"]},
                    headers=AUTH)
    assert r.status_code == 400 and "enable" in r.json()["detail"]
    assert _invoca("--session", "gemma", "stream", "enable", "--port", "9999") == 400
    assert _invoca("stream", "disable") == 400
    assert _invoca("stream") == 400


# Una prueba por cada forma de invocación real de la app (AgentBrowserService
# antepone --session y añade --json). Protegen de cerrar demasiado.
def test_pasan_las_invocaciones_reales_de_las_herramientas_de_la_app():
    s = ["--session", "gemma"]
    formas = [
        s + ["open", "https://example.com", "--json"],
        s + ["click", "@e3", "--json"],
        s + ["fill", "#correo", "hola mundo", "--json"],
        s + ["press", "Enter", "--json"],
        s + ["close", "--json"],
        s + ["snapshot", "-i", "--json"],
        s + ["snapshot", "-i", "-s", "main", "--json"],
        s + ["snapshot", "--json"],
        s + ["wait", "--text", "Listo", "--json"],
        s + ["wait", "--url", "**/gracias", "--json"],
        s + ["wait", "#cargando", "--json"],
        s + ["wait", "1500", "--json"],
        s + ["get", "title", "--json"],
        s + ["get", "url", "--json"],
        s + ["get", "text", "@e2", "--json"],
        s + ["get", "html", "main", "--json"],
        s + ["get", "value", "#q", "--json"],
        s + ["get", "count", "li", "--json"],
        # read_webpage no lleva sesión
        ["read", "https://example.com", "--json"],
        ["read", "https://example.com", "--outline", "--json"],
        ["read", "https://example.com", "--filter", "precio", "--json"],
        ["read", "https://example.com", "--outline", "--filter", "precio", "--json"],
    ]
    for forma in formas:
        assert _invoca(*forma) == 200, forma


# --- ejecutor: plazo y huérfanos ---
def test_el_stdin_mas_grande_que_el_pipe_vuelve_por_plazo(monkeypatch, tmp_path):
    # Un hijo que no lee su stdin: sin plazo propio, drain() colgaba la petición.
    import asyncio, time, cli
    guion = tmp_path / "no-lee-stdin"
    guion.write_text("#!/bin/sh\nexec sleep 30\n")
    guion.chmod(0o755)
    monkeypatch.setenv("BROWSER_FAKE_CLI", "0")
    monkeypatch.setattr(cli, "BROWSER_BIN", str(guion))
    inicio = time.monotonic()
    resultado = asyncio.run(cli.run(["batch"], timeout=1, stdin="x" * 1_000_000))
    assert time.monotonic() - inicio < 5
    assert resultado["exitCode"] == -1 and "timeout" in resultado["stderr"]


def test_el_proceso_se_mata_si_se_cancela_la_peticion(monkeypatch, tmp_path):
    import asyncio, cli, os, signal
    pidfile = tmp_path / "pid"
    guion = tmp_path / "duerme"
    guion.write_text(f"#!/bin/sh\necho $$ > {pidfile}\nexec sleep 30\n")
    guion.chmod(0o755)
    monkeypatch.setenv("BROWSER_FAKE_CLI", "0")
    monkeypatch.setattr(cli, "BROWSER_BIN", str(guion))

    async def escenario():
        tarea = asyncio.create_task(cli.run(["open", "https://a.test"], timeout=20))
        for _ in range(100):
            await asyncio.sleep(0.05)
            if pidfile.exists() and pidfile.read_text().strip():
                break
        tarea.cancel()
        try:
            await tarea
        except asyncio.CancelledError:
            pass

    asyncio.run(escenario())
    pid = int(pidfile.read_text())
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)


def test_el_cuerpo_tiene_topes():
    assert client.post("/v1/browser/invoke", json={"arguments": ["wait"] * 65},
                       headers=AUTH).status_code == 422
    assert client.post("/v1/browser/invoke",
                       json={"arguments": ["batch"], "stdin": "x" * 262145},
                       headers=AUTH).status_code == 422


# --- esquema de URL y nombre de sesión ---
def test_open_y_read_solo_admiten_http_y_https():
    malas = ["file:///etc/passwd", "FILE://x", " file:///etc/passwd", "file:/etc/passwd",
             "data:text/html,<script>alert(1)</script>", "javascript:alert(1)",
             "chrome://settings", "about:blank", "view-source:https://a.test",
             "ftp://a.test/x", "etc/passwd", "//a.test"]
    for url in malas:
        assert _invoca("open", url) == 400, url
        assert _invoca("read", url) == 400, url


def test_el_motivo_de_una_url_mala_nombra_el_esquema():
    r = client.post("/v1/browser/invoke", json={"arguments": ["open", "file:///etc/passwd"]},
                    headers=AUTH)
    assert r.status_code == 400 and "file" in r.json()["detail"]


def test_el_motivo_de_un_argumento_rechazado_no_reproduce_su_valor():
    # El `detail` de un 400 viaja hasta el log del chat de la app, así que una
    # contraseña que empiece por `-` acabaría en la pantalla del usuario. El motivo
    # debe nombrar el problema (el prefijo, el flag, la posición) y no el contenido.
    # Mismo criterio que `_validate_url`, que nombra el esquema y no la URL.
    secreto = "SECRETO-7f3a9c"
    casos = [
        # un posicional (el texto de un `fill`) que empieza por un prefijo prohibido
        ["--session", "gemma", "fill", "#clave", f"--profile{secreto}"],
        # un posicional con forma de flag que no está en la tabla
        ["--session", "gemma", "fill", "#clave", f"-{secreto}"],
        # el valor de un flag permitido, con forma de flag
        ["--session", "gemma", "wait", "--text", f"-{secreto}"],
    ]
    for argumentos in casos:
        r = client.post("/v1/browser/invoke", json={"arguments": argumentos}, headers=AUTH)
        assert r.status_code == 400, argumentos
        detalle = r.json()["detail"]
        assert secreto not in detalle, detalle
        assert detalle.strip(), "y sigue diciendo algo: un motivo vacío no se depura"


def test_open_y_read_con_http_y_https_pasan_aunque_vengan_en_mayusculas():
    for url in ["https://a.test", "http://a.test/x?y=1", "HTTPS://A.TEST"]:
        assert _invoca("open", url) == 200, url
        assert _invoca("read", url) == 200, url


def test_una_url_mala_dentro_de_batch_tambien_se_rechaza():
    assert _invoca("batch", stdin='[["open","file:///etc/passwd"]]') == 400
    assert _invoca("batch", "open file:///etc/passwd") == 400


def test_el_nombre_de_sesion_es_un_juego_de_caracteres_seguro():
    for malo in ["../../etc/x", "a/b", "..", "", "a b", "a;b", "x" * 65]:
        assert _invoca("--session", malo, "open", "https://a.test") == 400, malo
    for bueno in ["gemma", "gemma-live-test", "sesion_1"]:
        assert _invoca("--session", bueno, "open", "https://a.test") == 200, bueno


# ===========================================================================
# El relé del stream (Tarea 4): el predicado de «en vivo», el cable y el acuse
# encadenado. El cable es contrato con el lado de Swift: seis mensajes y nada más.
# ===========================================================================

# --- el predicado de «en vivo» ---
def test_nace_en_vivo_si_el_cli_dijo_screencasting_sin_haber_visto_ningun_status():
    # §5.9: el canal de status no es durable. Si el predicado exigiera haberlo visto,
    # un panel que pinta frames nuevos se marcaría congelado.
    assert PanelState(screencasting=True).live is True


def test_nace_no_vivo_si_el_cli_dijo_que_no():
    assert PanelState(screencasting=False).live is False


def test_pagina_quieta_sigue_en_vivo():
    s = PanelState(screencasting=True)
    s.apply({"kind": "frame", "seq": 1, "captured_at": 0, "jpeg_b64": "x"})
    assert s.live is True, "los frames se emiten por cambio, no por reloj: la edad no decide nada"


def test_un_status_con_screencasting_false_quita_el_en_vivo():
    s = PanelState(screencasting=True)
    s.apply({"kind": "status", "screencasting": False})
    assert s.live is False


def test_freeze_colapsa_y_deja_de_estar_vivo():
    s = PanelState(screencasting=True)
    s.freeze()
    assert s.collapsed is True and s.live is False


def test_cuenta_acciones_y_recuerda_el_host():
    s = PanelState(screencasting=True)
    s.apply({"kind": "command", "action": "navigate", "url": "https://amazon.es/x"})
    s.apply({"kind": "command", "action": "click", "url": None})
    assert s.action_count == 2 and s.host == "amazon.es"


def test_un_frame_prueba_que_el_screencast_corre_y_devuelve_el_en_vivo():
    # Observado en vivo: el demonio manda `status` con `screencasting:false` justo
    # al engancharse el relé y lo corrige unos segundos después. Un frame recibido
    # ES el screencast ocurriendo, así que el panel no puede decir «congelado»
    # mientras pinta uno nuevo. Decide su LLEGADA, nunca su antigüedad.
    s = PanelState(screencasting=True)
    s.apply({"kind": "status", "screencasting": False})
    assert s.live is False
    s.apply({"kind": "frame", "seq": 1, "captured_at": 0, "jpeg_b64": "x"})
    assert s.live is True


def test_el_socket_caido_quita_el_en_vivo():
    s = PanelState(screencasting=True)
    s.socket_closed()
    assert s.live is False


def test_dejar_de_acusar_quita_el_en_vivo():
    # Spec §6.2(f): en pacing=ack, dejar de acusar es la forma de congelar el panel.
    s = PanelState(screencasting=True)
    s.set_acking(False)
    assert s.live is False


def test_un_panel_colapsado_ya_no_cuenta_ni_narra():
    s = PanelState(screencasting=True)
    s.freeze()
    s.apply({"kind": "command", "action": "click", "url": None})
    assert s.action_count == 0


# Review Focus 4: un visor que entra a mitad recibe el estado actual.
def test_un_visor_que_entra_a_mitad_recibe_estado_resumen_y_host():
    s = PanelState(screencasting=True)
    s.apply({"kind": "command", "action": "navigate", "url": "https://amazon.es/x"})
    kinds = [m["type"] for m in s.snapshot_messages()]
    assert "state" in kinds and "summary" in kinds and "host" in kinds


# --- el endpoint ---
def _linea_filtrada(plantilla, args):
    """Pasa un registro por el filtro y devuelve la línea que se escribiría."""
    import logging
    registro = logging.LogRecord("uvicorn.error", logging.INFO, __file__, 1,
                                 plantilla, args, None)
    assert appmod.RedactTokenFilter().filter(registro) is True
    return registro.getMessage()


def test_el_token_se_tacha_en_mayusculas_y_en_cualquier_forma_de_args():
    # Las tres vías que dejaba pasar el filtro, una por una. Un cliente que mande
    # `?Token=` falla la autenticación, que es sensible a mayúsculas, pero su
    # token se escribiría en el log igual de claro.
    assert "SECRETO" not in _linea_filtrada("%s", ("/s?Token=SECRETO",))
    assert "SECRETO" not in _linea_filtrada("%s", ("/s?TOKEN=SECRETO",))
    # `args` como mapping: logging colapsa una tupla de un solo dict en el propio
    # dict, y por esa vía el scope entero de uvicorn —con la query string— llega
    # al log. Se construye como lo construye logging, con el dict en una tupla.
    assert "SECRETO" not in _linea_filtrada("%(path)s", ({"path": "/s?token=SECRETO"},))
    # Y sin pasar por un str: bytes, y un dict que NO va solo en la tupla.
    assert "SECRETO" not in _linea_filtrada("%s", (b"/s?token=SECRETO",))
    assert "SECRETO" not in _linea_filtrada("%s %s", ("x", {"q": "token=SECRETO"}))
    # El token también puede venir en la propia plantilla.
    assert "SECRETO" not in _linea_filtrada("GET /s?token=SECRETO", ())
    # Y lo que no es el token sobrevive, incluido un %d que no se puede convertir
    # a texto sin romper el formateo.
    linea = _linea_filtrada('%s [%d] scope=%s', ("cliente", 7, "/s?token=X&maxFps=10"))
    assert "maxFps=10" in linea and "[7]" in linea and "cliente" in linea
    assert "token=[redactado]" in linea


def test_tachar_el_token_no_puede_romper_el_formateo_de_la_linea():
    # El caso que hacía peligrosa la redacción pieza a pieza: el `token=` está en la
    # PLANTILLA y el secreto en los `args`. Redactando la plantilla se comía el
    # `%s`, el `getMessage()` del formateador reventaba con un TypeError y
    # `Handler.handleError` escribía en stderr el `record.args` entero — el token,
    # por haber intentado tacharlo.
    linea = _linea_filtrada("GET /s?token=%s&maxFps=%d", ("SECRETO", 10))
    assert "SECRETO" not in linea, linea
    assert "token=[redactado]" in linea and "maxFps=10" in linea, linea


def test_el_filtro_del_token_nunca_tira_al_que_registra():
    # `Logger.handle` NO envuelve los filtros: una excepción aquí saldría por el
    # `logger.info` del handshake del WebSocket y tiraría la conexión.
    import logging

    class _MsgQueRevienta:
        def __str__(self):
            raise RuntimeError("no me conviertas")

    registro = logging.LogRecord("uvicorn.error", logging.INFO, __file__, 1,
                                 _MsgQueRevienta(), None, None)
    assert appmod.RedactTokenFilter().filter(registro) is True


def test_los_tres_loggers_que_escribirian_el_token_llevan_el_filtro():
    import logging
    for nombre in ("uvicorn.error", "uvicorn.access", "uvicorn.asgi"):
        assert any(isinstance(f, appmod.RedactTokenFilter)
                   for f in logging.getLogger(nombre).filters), nombre


def test_un_logger_que_nadie_registro_tambien_sale_tachado():
    # Un filtro puesto en un logger NO se aplica a los registros que le llegan por
    # propagación de un hijo (`callHandlers` recorre handlers, no filtros), así que
    # «ponerlo también en el root» no cubriría un logger nuevo. Lo que lo cubre es
    # la fábrica de registros, que corre para CADA LogRecord del proceso.
    import logging
    nombre = "un.logger.que.nadie.registro"
    registro = logging.getLogger(nombre).makeRecord(
        nombre, logging.INFO, __file__, 1,
        "upgrade /v1/browser/stream?token=%s", ("secreto-de-la-casa",), None)
    linea = registro.getMessage()
    assert "secreto-de-la-casa" not in linea, linea
    assert "token=[redactado]" in linea, linea


def test_el_token_no_puede_acabar_en_un_log():
    # uvicorn registra el upgrade del WebSocket con su query string, y el panel
    # manda el bearer ahí porque un cliente de WebSocket no puede poner cabeceras.
    # Los logs de Docker del i3 no rotan ni se tratan como un secreto.
    import logging
    filtro = appmod.RedactTokenFilter()
    registro = logging.LogRecord("uvicorn.error", logging.INFO, __file__, 1,
                                 '%s - "WebSocket %s" [accepted]',
                                 (("10.0.0.1", 1234),
                                  "/v1/browser/stream?token=secreto-de-verdad&maxFps=10"),
                                 None)
    assert filtro.filter(registro) is True
    linea = registro.getMessage()
    assert "secreto-de-verdad" not in linea
    assert "token=[redactado]" in linea
    assert "maxFps=10" in linea, "solo se tacha el token, no la línea entera"
    # Y está puesto en los loggers que lo escribirían.
    for nombre in ("uvicorn.error", "uvicorn.access"):
        assert any(isinstance(f, appmod.RedactTokenFilter)
                   for f in logging.getLogger(nombre).filters), nombre


def test_el_stream_sin_token_se_rechaza():
    with pytest.raises(Exception):
        with client.websocket_connect("/v1/browser/stream"):
            pass


def test_el_stream_con_un_token_malo_se_rechaza():
    with pytest.raises(Exception):
        with client.websocket_connect("/v1/browser/stream?token=otro"):
            pass


def test_el_stream_manda_state_al_conectar():
    with client.websocket_connect("/v1/browser/stream?token=test-token") as ws:
        first = ws.receive_json()
        assert first["type"] == "state"
        assert set(first) >= {"type", "live", "collapsed"}


def test_el_stream_acepta_el_token_en_la_cabecera():
    with client.websocket_connect("/v1/browser/stream", headers=AUTH) as ws:
        assert ws.receive_json()["type"] == "state"


# --- la guardia de sesión: el visor declara y el relé compara ---
# El relé sigue UNA sesión del CLI (BROWSER_STREAM_SESSION) y la app usa su propio
# AGENT_BROWSER_SESSION, en otro repositorio. Coincidían por dos valores por
# omisión iguales: si alguien define una y no la otra, el navegador sigue
# funcionando y el panel se queda en blanco, en silencio. Con la guardia, el visor
# declara su sesión y el relé la compara.
def test_el_stream_sin_declarar_sesion_se_comporta_como_siempre():
    # Opcional a propósito: un visor viejo, que no manda el parámetro, no se rompe.
    with client.websocket_connect("/v1/browser/stream?token=test-token") as ws:
        assert ws.receive_json()["type"] == "state"


def test_el_stream_que_declara_la_sesion_del_rele_se_comporta_como_siempre():
    with client.websocket_connect(
            f"/v1/browser/stream?token=test-token&session={relay.SESSION}") as ws:
        assert ws.receive_json()["type"] == "state"


def test_el_stream_que_declara_otra_sesion_cierra_nombrando_las_dos():
    # Un motivo que solo dijera «sesión equivocada» no sirve para arreglarlo: hacen
    # falta los dos valores, porque el fallo es justamente que no se sabe cuál es
    # cuál.
    #
    # Y el `state` de delante es parte del contrato, no ruido: el visor no dibuja el
    # panel hasta haber recibido algo del servidor, y un `closed` NO cuenta para eso
    # —el cliente se fabrica uno él mismo cuando la conexión falla—, así que sin el
    # `state` este motivo moriría en una fila vacía y la guardia no serviría de nada.
    # Por eso el orden se asevera, no solo el contenido.
    with client.websocket_connect(
            "/v1/browser/stream?token=test-token&session=gemma-live-test") as ws:
        primero = ws.receive_json()
        mensaje = ws.receive_json()
    assert primero["type"] == "state", primero
    assert primero["live"] is False, primero
    assert mensaje["type"] == "closed"
    assert relay.SESSION in mensaje["reason"], mensaje["reason"]
    assert "gemma-live-test" in mensaje["reason"], mensaje["reason"]
    _comprobar_esquema([primero, mensaje])


def test_la_comparacion_de_sesion_se_prueba_sola():
    assert relay.session_mismatch("") is None, "sin declarar nada, como siempre"
    assert relay.session_mismatch(relay.SESSION) is None
    motivo = relay.session_mismatch("otra")
    assert motivo is not None and relay.SESSION in motivo and "otra" in motivo


def test_sin_puerto_del_demonio_el_visor_recibe_closed_y_el_servicio_sigue_vivo():
    # BROWSER_FAKE_CLI=1: `stream status` no trae puerto. Degradación §6.2(e): el
    # panel no aparece y nada más se rompe.
    tipos, termino = [], False
    with contextlib.suppress(Exception):
        with client.websocket_connect("/v1/browser/stream?token=test-token") as ws:
            for _ in range(5):
                try:
                    tipos.append(ws.receive_json()["type"])
                except Exception:
                    termino = True  # el relé cerró en vez de dejar al visor colgado
                    break
    assert tipos[0] == "state", "el state sale incondicional, antes de hablar con el CLI"
    assert tipos[-1] == "closed"
    assert [m for m in tipos if m == "closed"], "con motivo, no un cuelgue"
    assert termino, "la conexión termina; un visor en blanco para siempre es el peor fallo"
    assert client.get("/healthz").status_code == 200


def test_el_motivo_del_closed_sin_navegador_es_legible():
    with contextlib.suppress(Exception):
        with client.websocket_connect("/v1/browser/stream?token=test-token") as ws:
            for _ in range(5):
                m = ws.receive_json()
                if m["type"] == "closed":
                    assert m["reason"] == "el navegador no está disponible"
                    return
    pytest.fail("no llegó el closed")


# El esquema de los seis mensajes, clave por clave. El lado de Swift los lee por
# nombre y por tipo, así que un campo de más es un campo que nadie decidió
# mandar, y el sitio donde aparecería es el mismo por donde saldría un secreto.
_ESQUEMA_DEL_CABLE = {
    "frame": {"type", "seq", "jpeg", "captured_at"},
    "narration": {"type", "text"},
    "host": {"type", "host"},
    "state": {"type", "live", "collapsed"},
    "summary": {"type", "text"},
    "closed": {"type", "reason"},
}


def _comprobar_esquema(enviados):
    assert enviados, "sin mensajes no se está comprobando nada"
    for mensaje in enviados:
        assert mensaje["type"] in _ESQUEMA_DEL_CABLE, mensaje["type"]
        assert set(mensaje) == _ESQUEMA_DEL_CABLE[mensaje["type"]], mensaje


# --- el cable, contra un demonio falso: sin Docker y sin el CLI de verdad ---
_JPEG_B64 = base64.b64encode(bytes([0xFF, 0xD8, 0xFF, 0xE0]) + b"relleno" * 8).decode()


def _frame(seq, timestamp=1793996915607):
    cuerpo = {"type": "frame", "seq": seq, "data": _JPEG_B64}
    if timestamp is not None:
        cuerpo["metadata"] = {"timestamp": timestamp}
    return json.dumps(cuerpo)


def _paso(texto, espera_acuse=False):
    return {"texto": texto, "espera_acuse": espera_acuse}


class VisorFalso:
    """Un visor de prueba. Guarda lo que le llega al cable y, si se le pide, acusa
    cada frame como hará la app. `lento` imita un socket que tarda en drenar."""

    def __init__(self, auto_ack=True, lento=0.0, se_va_tras_frames=None):
        self.enviados = []
        self.auto_ack = auto_ack
        self.lento = lento
        self.se_va_tras_frames = se_va_tras_frames
        self._entrada = []
        self._cerrado = False

    async def send_json(self, mensaje):
        if self._cerrado:
            raise RuntimeError("visor cerrado")
        if self.lento:
            await asyncio.sleep(self.lento)
        self.enviados.append(mensaje)
        if mensaje.get("type") == "frame":
            if self.auto_ack:
                self._entrada.append(json.dumps({"type": "ack", "seq": mensaje["seq"]}))
            if self.se_va_tras_frames is not None and len(self.frames) >= self.se_va_tras_frames:
                self._cerrado = True

    async def receive_text(self):
        while True:
            if self._entrada:
                return self._entrada.pop(0)
            if self._cerrado:
                raise WebSocketDisconnect(code=1000)
            await asyncio.sleep(0.005)

    async def close(self, code=1000):
        self._cerrado = True

    def desconectar(self):
        self._cerrado = True

    def inyectar_acuse(self, seq):
        """Mete un acuse en la entrada, incluso de un frame que este visor no
        recibió: así se puede probar que el relé no lo cuenta."""
        self._entrada.append(json.dumps({"type": "ack", "seq": seq}))

    @property
    def frames(self):
        return [m for m in self.enviados if m.get("type") == "frame"]

    @property
    def tipos(self):
        return [m.get("type") for m in self.enviados]


@contextlib.asynccontextmanager
async def _demonio_falso(guion, acuses, lecturas, cierra=False):
    """Imita el servidor del stream del demonio: manda cada paso del guion y, en
    los pasos marcados, no manda nada hasta que llega el acuse del relé. Así el
    flujo se corta en seco si el encadenado del acuse está roto (§5.8: el servidor
    de verdad ignora en silencio lo que no entiende, así que solo se puede probar
    por el efecto)."""

    async def manejar(ws):
        with contextlib.suppress(Exception):
            for paso in guion:
                if paso["espera_acuse"]:
                    acuses.append(json.loads(await ws.recv()))
                await ws.send(paso["texto"])
            if cierra:
                return
            async for crudo in ws:
                acuses.append(json.loads(crudo))

    async with websockets.serve(manejar, "127.0.0.1", 0) as servidor:
        puerto = servidor.sockets[0].getsockname()[1]

        async def leer_puerto():
            lecturas.append(puerto)
            return puerto

        yield leer_puerto


async def _esperar(predicado, timeout=6.0):
    limite = time.monotonic() + timeout
    while time.monotonic() < limite:
        if predicado():
            return True
        await asyncio.sleep(0.01)
    return False


async def _cablear(guion, visores, hasta, acuses=None, lecturas=None,
                   stall_grace=5.0, cierra=False, timeout=6.0, tras=None):
    """Levanta el demonio falso, conecta el relé y los visores [(visor, max_fps)],
    espera a que `hasta` se cumpla, corre `tras` con todo todavía conectado, y
    desmonta."""
    acuses = [] if acuses is None else acuses
    lecturas = [] if lecturas is None else lecturas
    async with _demonio_falso(guion, acuses, lecturas, cierra=cierra) as leer_puerto:
        rele = relay.Relay(leer_puerto, stall_grace=stall_grace)
        tareas = [asyncio.create_task(rele.add_viewer(v, max_fps=f)) for v, f in visores]
        try:
            await _esperar(hasta, timeout)
            if tras is not None:
                await tras()
        finally:
            for visor, _ in visores:
                visor.desconectar()
            for tarea in tareas:
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(tarea, 2.0)
            await rele.shutdown()
    return acuses, lecturas


def test_el_cable_no_lleva_params_nunca():
    # LA prueba del diseño entero: el `params` de un `fill` lleva el valor
    # tecleado, y el cable no puede transportarlo ni por un error de programación
    # de la app, porque nunca sale de este proceso (spec §6.3 y §5.10).
    visor = VisorFalso()
    guion = [_paso(json.dumps({
        "type": "command", "action": "fill", "id": "r1",
        "params": {"action": "fill", "id": "r1", "selector": "#tarjeta",
                   "value": "4111111111111111"}}))]
    asyncio.run(_cablear(guion, [(visor, 0)], lambda: "narration" in visor.tipos))
    cable = json.dumps(visor.enviados, ensure_ascii=False)
    assert "4111111111111111" not in cable
    assert "#tarjeta" not in cable
    assert "params" not in cable
    assert {"type": "narration", "text": "rellenando un campo"} in visor.enviados


def test_una_accion_desconocida_sale_como_frase_generica_en_espanol():
    # La tabla de frases es incompleta por naturaleza: el eco usa nombres de
    # operación del protocolo (`gettext`, `innerhtml`), no los del CLI. Una
    # operación nueva narra algo genérico en español y no su nombre crudo, que
    # sería inglés en la cara del usuario.
    visor = VisorFalso()
    guion = [_paso(json.dumps({"type": "command", "action": "scrollintoview",
                               "params": {"value": "SECRETO"}}))]
    asyncio.run(_cablear(guion, [(visor, 0)], lambda: "narration" in visor.tipos))
    assert {"type": "narration", "text": "trabajando en la página"} in visor.enviados
    assert "scrollintoview" not in json.dumps(visor.enviados)
    assert "SECRETO" not in json.dumps(visor.enviados)


def test_la_frase_generica_no_se_come_a_las_de_la_tabla():
    import stream as streammod
    esperadas = {
        "navigate": "navegando", "open": "navegando",
        "click": "haciendo clic", "fill": "rellenando un campo",
        "type": "rellenando un campo", "press": "pulsando una tecla",
        "wait": "esperando", "close": "cerrando la pestaña",
        "snapshot": "leyendo la página", "read": "leyendo la página",
        "get": "leyendo la página", "url": "leyendo la página",
        "title": "leyendo la página", "count": "leyendo la página",
        "gettext": "leyendo la página", "innerhtml": "leyendo la página",
        "inputvalue": "leyendo la página", "text": "leyendo la página",
        "html": "leyendo la página", "value": "leyendo la página",
    }
    for accion, frase in esperadas.items():
        assert streammod.phrase(accion, None) == frase, accion
    assert streammod.phrase("navigate", "https://a.test/x") == "navegando a a.test"


def test_launch_no_narra_ni_cuenta_porque_no_es_una_accion_del_agente():
    # Observado en vivo: el demonio hace eco de `launch` antes de CADA orden,
    # porque el CLI asegura el navegador en cada invocación. Narrarla pondría
    # «launch» en una interfaz en español, y contarla duplicaría la cuenta del
    # resumen, que es lo único que queda cuando el panel colapsa.
    import stream as streammod
    crudo = json.dumps({"type": "command", "action": "launch", "id": "r1",
                        "params": {"url": "https://amazon.es/x"}})
    decodificado = streammod.decode(crudo)
    assert decodificado["kind"] == "other"
    assert streammod.wire_messages(decodificado) == []

    s = PanelState(screencasting=True)
    s.apply(decodificado)
    assert s.action_count == 0 and s.host is None

    visor = VisorFalso()
    guion = [_paso(crudo),
             _paso(json.dumps({"type": "command", "action": "click", "params": {}}))]
    asyncio.run(_cablear(guion, [(visor, 0)], lambda: "narration" in visor.tipos))
    narraciones = [m["text"] for m in visor.enviados if m["type"] == "narration"]
    assert narraciones == ["haciendo clic"], "launch no llega al cable"


def test_las_seis_formas_de_get_narran_leyendo_la_pagina():
    # El eco no usa el nombre del subcomando sino la operación del protocolo.
    # Observados en vivo, uno por uno, con las seis formas que llama la app:
    # url→url, title→title, count→count, text→gettext, html→innerhtml,
    # value→inputvalue. Los cuatro últimos son alias por si cambian.
    import stream as streammod
    observados = ["url", "title", "count", "gettext", "innerhtml", "inputvalue"]
    alias = ["get", "text", "html", "value"]
    for palabra in observados + alias:
        assert streammod.phrase(palabra, None) == "leyendo la página", palabra


def test_el_nombre_de_la_accion_no_es_sensible_a_mayusculas():
    # Una versión del CLI que emitiera `Click` no puede caer en la frase genérica,
    # ni un `LAUNCH` colarse en la cuenta. El nombre se normaliza en el punto del
    # saneado, así que IGNORED_ACTIONS, _NAVIGATE y la tabla lo ven ya en
    # minúsculas; `phrase` normaliza también porque es público.
    import stream as streammod
    assert streammod.phrase("Click", None) == "haciendo clic"
    assert streammod.decode(
        json.dumps({"type": "command", "action": "LAUNCH"}))["kind"] == "other"
    d = streammod.decode(json.dumps({"type": "command", "action": "Navigate",
                                     "params": {"url": "https://a.test/x"}}))
    assert d["action"] == "navigate" and d["url"] == "https://a.test/x"
    assert {"type": "host", "host": "a.test"} in streammod.wire_messages(d)


def test_la_accion_url_no_navega_ni_emite_host():
    # `url` es el nombre de una acción de lectura, no una navegación: la url de
    # `params` se lee solo para `navigate` y `open`.
    import stream as streammod
    decodificado = streammod.decode(json.dumps({
        "type": "command", "action": "url",
        "params": {"url": "https://www.amazon.es/dp/secreto"}}))
    assert decodificado["url"] is None
    assert streammod.wire_messages(decodificado) == [
        {"type": "narration", "text": "leyendo la página"}]


def test_llegan_dos_frames_porque_el_acuse_encadena():
    # §5.8, por el efecto: si `{"type":"ack","seq":N}` estuviera mal formado, el
    # demonio no mandaría nada más y el flujo se pararía en el primer frame.
    visor = VisorFalso()
    guion = [_paso(_frame(1)), _paso(_frame(2), espera_acuse=True),
             _paso(_frame(3), espera_acuse=True)]
    acuses, _ = asyncio.run(_cablear(guion, [(visor, 0)], lambda: len(visor.frames) >= 3))
    assert len(visor.frames) >= 3, "el encadenado visor→relé→demonio no fluye"
    assert [a["seq"] for a in acuses[:2]] == [1, 2]
    assert all(a["type"] == "ack" for a in acuses[:2])


def test_el_acuse_al_demonio_no_se_manda_antes_que_el_del_visor():
    # Spec §6.4: si el relé acusara por su cuenta, el anti objetivo principal
    # volvería un salto más atrás. Se mira con el visor todavía conectado: al irse
    # el último visor sí se acusa a propósito, y eso lo prueba otro test.
    visor, acuses, vistos = VisorFalso(auto_ack=False), [], []

    async def comprobar():
        await asyncio.sleep(0.3)  # tiempo de sobra para un acuse inventado
        vistos.extend(acuses)

    asyncio.run(_cablear([_paso(_frame(1))], [(visor, 0)], lambda: visor.frames,
                         acuses=acuses, tras=comprobar))
    assert visor.frames, "el frame sí se reparte"
    assert vistos == [], "el relé no acusa al demonio por su cuenta"


def test_un_frame_sin_timestamp_sale_con_captured_at_numerico():
    # `stream.decode` es puro y se quedó sin reloj: el sello lo pone el relé, y el
    # cable fija `captured_at` como número (un null rompería al lado de Swift).
    visor = VisorFalso()
    asyncio.run(_cablear([_paso(_frame(7, timestamp=None))], [(visor, 0)],
                         lambda: visor.frames))
    capturado = visor.frames[0]["captured_at"]
    assert isinstance(capturado, (int, float)) and not isinstance(capturado, bool)
    assert capturado > 0


def test_un_frame_ilegible_se_acusa_igual_y_no_se_manda_al_cable():
    visor, acuses = VisorFalso(), []
    malo = json.dumps({"type": "frame", "seq": 4, "data": "no-soy-un-jpeg"})
    asyncio.run(_cablear([_paso(malo)], [(visor, 0)], lambda: acuses, acuses=acuses))
    assert acuses and acuses[0] == {"type": "ack", "seq": 4}, "el ritmo no se atasca"
    assert visor.frames == []


def test_sin_visores_el_rele_acusa_igual():
    # El visor se va con el frame 1 en vuelo y el 2 llega sin nadie mirando: si el
    # relé no acusara, el ritmo del demonio quedaría atascado para siempre.
    visor, acuses = VisorFalso(auto_ack=False, se_va_tras_frames=1), []
    guion = [_paso(_frame(1)), _paso(_frame(2), espera_acuse=True)]
    asyncio.run(_cablear(guion, [(visor, 0)], lambda: len(acuses) >= 2, acuses=acuses))
    assert [a["seq"] for a in acuses[:2]] == [1, 2]


def test_dos_visores_ven_lo_mismo_y_el_lento_no_retrasa_al_rapido():
    # Review Focus 3: el tope de fps de cada visor se aplica al DESCARTE y no a la
    # cola. Al de 1 fps le toca saltarse frames; el de sin tope los ve todos.
    rapido, lento = VisorFalso(), VisorFalso()
    guion = [_paso(_frame(1)), _paso(_frame(2), espera_acuse=True),
             _paso(_frame(3), espera_acuse=True)]
    asyncio.run(_cablear(guion, [(rapido, 0), (lento, 1)],
                         lambda: len(rapido.frames) >= 3))
    assert len(rapido.frames) >= 3
    assert len(lento.frames) == 1, "al lento le toca saltárselos, no encolarlos"
    assert rapido.frames[0]["seq"] == lento.frames[0]["seq"], "los dos ven lo mismo"


def test_basta_el_primer_acuse_y_el_que_no_acusa_no_frena_a_nadie():
    # Review Focus 3: si el relé esperara el acuse de TODOS, el visor que no
    # acusa marcaría el ritmo del demonio y sería el reloj de los demás.
    acusador, callado = VisorFalso(), VisorFalso(auto_ack=False)
    guion = [_paso(_frame(1)), _paso(_frame(2), espera_acuse=True),
             _paso(_frame(3), espera_acuse=True)]
    acuses, _ = asyncio.run(_cablear(guion, [(acusador, 0), (callado, 0)],
                                     lambda: len(acusador.frames) >= 3))
    assert len(acusador.frames) >= 3, "el callado no puede frenar el flujo"
    assert [a["seq"] for a in acuses[:2]] == [1, 2]
    assert len(callado.frames) >= 1, "los dos ven lo mismo mientras drenen"


def test_un_visor_que_deja_de_acusar_marca_el_panel_congelado():
    # Spec §6.2(f): dejar de acusar congela el panel, y el relé NO se inventa un
    # acuse para destrabarlo. El plazo mide el tiempo sin poder acusar, no la edad
    # del frame: una página quieta no manda frames y no tiene nada en vuelo.
    visor, acuses, vistos = VisorFalso(auto_ack=False), [], []

    async def comprobar():
        vistos.extend(acuses)

    asyncio.run(_cablear(
        [_paso(_frame(1))], [(visor, 0)],
        lambda: len([m for m in visor.enviados if m["type"] == "state"]) >= 3,
        acuses=acuses, stall_grace=0.05, tras=comprobar))
    estados = [m for m in visor.enviados if m["type"] == "state"]
    assert estados[-1]["live"] is False, "el panel no puede decir «en vivo» atascado"
    assert vistos == [], "el relé no se inventa el acuse para destrabarse"


def test_el_socket_caido_congela_el_panel_con_resumen_y_closed():
    # Degradación §6.2(e) y §6.2(g): el panel se marca congelado, suelta su imagen
    # y deja solo la línea de resumen.
    visor = VisorFalso()
    guion = [_paso(json.dumps({"type": "command", "action": "navigate", "id": "r1",
                               "params": {"url": "https://www.amazon.es/dp/x"}}))]
    asyncio.run(_cablear(guion, [(visor, 0)], lambda: "closed" in visor.tipos,
                         cierra=True))
    assert {"type": "host", "host": "www.amazon.es"} in visor.enviados
    resumen = [m for m in visor.enviados if m["type"] == "summary"][-1]
    assert resumen["text"] == "navegó en www.amazon.es · 1 acción"
    estado = [m for m in visor.enviados if m["type"] == "state"][-1]
    assert estado["live"] is False and estado["collapsed"] is True
    assert visor.tipos[-1] == "closed"
    _comprobar_esquema(visor.enviados)  # aquí sí aparece `host`


def _ultimo_resumen(visor):
    resumenes = [m for m in visor.enviados if m.get("type") == "summary"]
    return resumenes[-1]["text"] if resumenes else None


def test_el_resumen_llega_durante_el_turno_y_no_solo_cuando_muere_el_demonio():
    # El resumen es LO ÚNICO que queda del turno en el historial del chat (spec
    # §6.2(g) y §10(2)): cuando la app congela el panel pinta el último `summary`
    # que recibió. Si solo se emitiera al morir el socket del demonio —que en un
    # turno normal no pasa, porque el que se va es el visor— la etiqueta del panel
    # plegado se quedaría en el literal de reserva («navegador»).
    visor = VisorFalso()
    guion = [_paso(json.dumps({"type": "command", "action": "navigate", "id": "r1",
                               "params": {"url": "https://www.amazon.es/dp/x"}})),
             _paso(json.dumps({"type": "command", "action": "click", "id": "r2",
                               "params": {"selector": "#comprar"}}))]
    asyncio.run(_cablear(guion, [(visor, 0)],
                         lambda: _ultimo_resumen(visor) == "navegó en www.amazon.es · 2 acciones"))
    assert _ultimo_resumen(visor) == "navegó en www.amazon.es · 2 acciones"
    _comprobar_esquema(visor.enviados)


def test_un_visor_nuevo_resume_lo_que_ESE_visor_ha_visto_y_no_la_historia_del_demonio():
    # Los dos ciclos de vida no son el mismo: el `PanelState` del relé vive por era
    # del demonio (que sobrevive LINGER_SECONDS sin visores) y el panel de la app
    # vive por turno. Sin reiniciar, un turno 2 que abra su panel dentro del plazo
    # de gracia heredaría la cuenta del turno 1 y seguiría sumando: un turno de dos
    # acciones diría siete. El resumen que recibe un visor describe lo que ese
    # visor ha visto.
    guion = [_paso(json.dumps({"type": "command", "action": "navigate", "id": "r1",
                               "params": {"url": "https://www.amazon.es/dp/x"}})),
             _paso(json.dumps({"type": "command", "action": "click", "id": "r2",
                               "params": {"selector": "#comprar"}}))]

    async def cuerpo():
        acuses, lecturas = [], []
        async with _demonio_falso(guion, acuses, lecturas) as leer_puerto:
            rele = relay.Relay(leer_puerto, stall_grace=5.0)
            primero = VisorFalso()
            tarea = asyncio.create_task(rele.add_viewer(primero, max_fps=0))
            esperado = "navegó en www.amazon.es · 2 acciones"
            assert await _esperar(lambda: _ultimo_resumen(primero) == esperado), \
                _ultimo_resumen(primero)
            primero.desconectar()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(tarea, 2.0)
            # El demonio sigue conectado (plazo de gracia): el visor nuevo entra
            # sobre un `PanelState` que ya existe, que es el caso que mentía.
            segundo = VisorFalso()
            tarea = asyncio.create_task(rele.add_viewer(segundo, max_fps=0))
            assert await _esperar(lambda: _ultimo_resumen(segundo) is not None, 3.0)
            visto = (_ultimo_resumen(segundo), list(segundo.tipos))
            segundo.desconectar()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(tarea, 2.0)
            await rele.shutdown()
            assert lecturas == [lecturas[0]] * len(lecturas), "un solo demonio"
            return visto

    resumen, tipos = asyncio.run(cuerpo())
    assert resumen == "navegó en la web · 0 acciones", resumen
    assert "host" not in tipos, "ni el host del turno anterior"


def test_el_cable_solo_lleva_los_seis_mensajes_de_la_spec():
    visor = VisorFalso()
    guion = [_paso(_frame(1)),
             _paso(json.dumps({"type": "status", "screencasting": True})),
             _paso(json.dumps({"type": "command", "action": "click",
                               "params": {"selector": "#comprar"}})),
             _paso(json.dumps({"type": "result", "action": "click", "data": {"x": 1}})),
             _paso(json.dumps({"type": "console", "text": "ruido"}))]
    asyncio.run(_cablear(guion, [(visor, 0)], lambda: "closed" in visor.tipos,
                         cierra=True))
    # Igualdad y no subconjunto: con un subconjunto, un cable vacío pasaría.
    assert set(visor.tipos) == {"state", "frame", "narration", "summary", "closed"}
    _comprobar_esquema(visor.enviados)  # `host` lo cubre la prueba del socket caído


class _FalloNoAtrapable(BaseException):
    """Imita un fallo que los `except Exception` del relé no cubren."""


async def _un_visor_contra(rele, hasta, timeout=3.0):
    """Conecta un visor falso a un relé ya construido y espera a `hasta`."""
    visor = VisorFalso()
    tarea = asyncio.create_task(rele.add_viewer(visor, max_fps=0))
    await _esperar(lambda: hasta(visor), timeout)
    visor.desconectar()
    with contextlib.suppress(Exception):
        await asyncio.wait_for(tarea, 2.0)
    await asyncio.sleep(0.05)  # deja acabar lo que el relé haya programado
    await rele.shutdown()
    return visor


def test_el_arranque_entero_tiene_un_presupuesto_y_el_visor_recibe_su_closed():
    # La cota de lo que tarda un visor en saber que no hay panel no puede ser la
    # suma de los plazos de cada intento: con tres intentos de leer el puerto y
    # abrir el socket, pasaría del minuto esperando su `closed`.
    async def escenario():
        async def nunca_responde():
            await asyncio.sleep(30)
            return None

        rele = relay.Relay(nunca_responde, startup_budget=0.3)
        inicio = time.monotonic()
        visor = await _un_visor_contra(rele, lambda v: "closed" in v.tipos)
        return time.monotonic() - inicio, visor

    tardo, visor = asyncio.run(escenario())
    assert visor.tipos[0] == "state", "el state sale desde el primer instante"
    assert "closed" in visor.tipos
    assert tardo < 2.0, f"el arranque no quedó acotado: {tardo:.1f}s"


def test_si_la_era_del_demonio_muere_de_algo_raro_el_visor_recibe_closed():
    # El peor fallo posible es un visor con su `state{live:false}` y SIN `closed`:
    # se queda en blanco para siempre y, con la política de no registrar cuerpos,
    # sin rastro. La red de seguridad difunde el cierre.
    async def escenario():
        async def revienta():
            raise _FalloNoAtrapable("este texto no se mira nunca")

        rele = relay.Relay(revienta)
        visor = VisorFalso()
        tarea = asyncio.create_task(rele.add_viewer(visor, max_fps=0))
        await _esperar(lambda: "closed" in visor.tipos, 3.0)
        visor.desconectar()
        with contextlib.suppress(Exception):
            await asyncio.wait_for(tarea, 2.0)
        await asyncio.sleep(0.05)
        # El fallo sigue guardado en la tarea de la era, y `shutdown` lo levanta
        # al recogerla: es un BaseException y el relé no se los traga, con razón.
        with contextlib.suppress(_FalloNoAtrapable):
            await rele.shutdown()
        return visor

    visor = asyncio.run(escenario())
    assert visor.tipos[0] == "state"
    assert "closed" in visor.tipos, "la era murió sin avisar al visor"
    _comprobar_esquema(visor.enviados)


def test_el_acuse_de_un_visor_que_se_salto_el_frame_no_cuenta():
    # A un visor que se saltó el frame por su tope de fps no se le puede dejar
    # mover el ritmo del demonio ni mantener el panel «en vivo» sin haber pintado.
    rapido, lento = VisorFalso(auto_ack=False), VisorFalso(auto_ack=False)
    acuses, vistos = [], []

    async def comprobar():
        await _esperar(lambda: rapido.frames, 2.0)
        rapido.inyectar_acuse(1)                    # el primero sí lo recibió
        await _esperar(lambda: len(rapido.frames) >= 2, 2.0)
        lento.inyectar_acuse(2)                     # este no: su tope lo saltó
        await asyncio.sleep(0.3)
        vistos.extend(a["seq"] for a in acuses)

    asyncio.run(_cablear([_paso(_frame(1)), _paso(_frame(2), espera_acuse=True)],
                         [(rapido, 0), (lento, 1)], lambda: True,
                         acuses=acuses, tras=comprobar))
    assert len(lento.frames) == 1, "al lento le tocó saltarse el segundo frame"
    assert vistos == [1], "solo cuenta el acuse de quien SÍ se quedó el frame"


def test_el_puerto_se_lee_en_cada_reconexion():
    # Review Focus 1 y §5.2: el demonio se apaga por inactividad y al volver el
    # puerto es otro. Un relé que lo cachea deja el panel muerto el resto de la
    # sesión.
    async def escenario():
        acuses, lecturas = [], []
        async with _demonio_falso([], acuses, lecturas, cierra=True) as leer_puerto:
            rele = relay.Relay(leer_puerto)
            for _ in range(2):
                visor = VisorFalso()
                tarea = asyncio.create_task(rele.add_viewer(visor, max_fps=0))
                await _esperar(lambda: "closed" in visor.tipos)
                visor.desconectar()
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(tarea, 2.0)
            await rele.shutdown()
        return lecturas

    assert len(asyncio.run(escenario())) == 2, "el puerto se lee en cada (re)conexión"


def test_el_visor_no_puede_mandar_nada_que_no_sea_un_acuse():
    # Spec §7: nada de control remoto. Un `input_mouse` del visor no se reenvía.
    assert relay._ack_from(json.dumps({"type": "input_mouse", "x": 1})) is None
    assert relay._ack_from(json.dumps({"type": "config", "maxFps": 120})) is None
    assert relay._ack_from("no soy json") is None
    assert relay._ack_from(json.dumps({"type": "ack", "seq": True})) is None
    assert relay._ack_from(json.dumps({"type": "ack", "seq": 41})) == 41


def test_read_port_saca_el_puerto_del_envelope_del_cli(monkeypatch):
    async def falso(arguments, timeout, stdin=None):
        assert arguments == ["--session", relay.SESSION, "stream", "status", "--json"]
        assert "enable" not in arguments, "nunca se llama a stream enable (§5.1)"
        return {"exitCode": 0, "stderr": "", "stdout": json.dumps(
            {"success": True, "data": {"connected": True, "enabled": True,
                                       "port": 55058, "screencasting": False},
             "error": None})}

    monkeypatch.setattr(relay.cli, "run", falso)
    assert asyncio.run(relay.read_port()) == 55058


def test_read_port_devuelve_none_cuando_el_cli_no_da_puerto(monkeypatch):
    casos = ['{"success":false,"data":null,"error":"nope"}', '{"success":true,"data":{}}',
             "no soy json", "", '{"success":true,"data":{"port":"55058"}}']
    for salida in casos:
        async def falso(arguments, timeout, stdin=None, salida=salida):
            return {"exitCode": 0, "stdout": salida, "stderr": ""}
        monkeypatch.setattr(relay.cli, "run", falso)
        assert asyncio.run(relay.read_port()) is None, salida


def test_el_caudal_del_panel_cabe_en_un_enlace_movil():
    # Lo que decide es el PICO, no la media: tope de fps x fotograma más grande
    # medido (1080x608 q45: 54 715 B; media 51 594 B). Presupuesto: 400 kB/s.
    # Medición: personal_agent, commit 03ba854,
    # docs/superpowers/notes/2026-11-08-medicion-nitidez-panel.md
    # OJO: 54_715 B es el máximo de 25 fotogramas medidos a 1080x608 q45 exactamente.
    # Si cambia la resolución o la calidad del compose, este número no se adivina:
    # se vuelve a medir (método en la nota citada arriba).
    assert relay.DEFAULT_VIEWER_MAX_FPS * 54_715 <= 400_000
    # El demonio no debe codificar más fotogramas de los que el relé deja pasar.
    assert relay.DAEMON_MAX_FPS <= relay.DEFAULT_VIEWER_MAX_FPS
