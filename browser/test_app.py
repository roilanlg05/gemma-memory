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
