"""Pruebas del servicio de navegador. Correr con:
    python3 -m pytest browser/test_app.py -v
Usa BROWSER_FAKE_CLI=1 para no lanzar el binario de verdad."""
import os, sys
import pytest
os.environ["BROWSER_FAKE_CLI"] = "1"
os.environ["BROWSER_BEARER_TOKEN"] = "test-token"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi.testclient import TestClient
import app as appmod

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
