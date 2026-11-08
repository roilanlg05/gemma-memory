"""Pruebas del lector del stream. Correr con:
    python3 -m pytest browser/test_stream.py -v
El módulo es puro: no necesita red, ficheros ni el servicio."""
import base64, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stream import decode, phrase, host_of, wire_messages, ack_seq, summary

JPEG = bytes([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])


def test_frame_trae_seq_jpeg_y_fecha():
    d = decode(json.dumps({"type": "frame", "seq": 41,
                           "data": base64.b64encode(JPEG).decode(),
                           "metadata": {"timestamp": 1793996915607}}))
    assert d["kind"] == "frame" and d["seq"] == 41
    assert abs(d["captured_at"] - 1793996915.607) < 0.001


def test_frame_en_el_cable_usa_los_nombres_exactos_y_el_base64_tal_cual():
    b64 = base64.b64encode(JPEG).decode()
    d = decode(json.dumps({"type": "frame", "seq": 41, "data": b64,
                           "metadata": {"timestamp": 1793996915607}}))
    msgs = wire_messages(d)
    assert len(msgs) == 1
    m = msgs[0]
    assert set(m.keys()) == {"type", "seq", "jpeg", "captured_at"}
    assert m["type"] == "frame" and m["seq"] == 41
    assert m["jpeg"] == b64, "el base64 sale tal como llegó, sin decodificar"
    assert isinstance(m["captured_at"], float)
    assert abs(m["captured_at"] - 1793996915.607) < 0.001


def test_frame_que_no_es_jpeg_es_bad_frame_pero_se_acusa():
    d = decode(json.dumps({"type": "frame", "seq": 7,
                           "data": base64.b64encode(b"hola").decode(),
                           "metadata": {"timestamp": 1}}))
    assert d["kind"] == "bad_frame"
    assert ack_seq(d) == 7, "un frame ilegible se acusa igual: si no, el ritmo se atasca"
    assert wire_messages(d) == [], "y no se manda nada al visor"


def test_frame_con_base64_roto_es_bad_frame():
    d = decode(json.dumps({"type": "frame", "seq": 8, "data": "%%%", "metadata": {"timestamp": 1}}))
    assert d["kind"] == "bad_frame"


def test_frame_valido_se_acusa():
    d = decode(json.dumps({"type": "frame", "seq": 3,
                           "data": base64.b64encode(JPEG).decode(),
                           "metadata": {"timestamp": 1}}))
    assert ack_seq(d) == 3


def test_lo_que_no_es_frame_no_se_acusa():
    assert ack_seq(decode(json.dumps({"type": "status", "screencasting": True}))) is None
    assert ack_seq(decode(json.dumps({"type": "command", "action": "click"}))) is None


# LA PRUEBA QUE IMPORTA, dos veces: en el decodificador y en el cable.
def test_el_valor_de_un_fill_no_sale_del_decodificador():
    d = decode(json.dumps({"type": "command", "action": "fill", "id": "r1",
                           "params": {"selector": "#card", "value": "4111111111111111",
                                      "url": "https://x.test"}}))
    assert d["action"] == "fill"
    assert d["url"] is None, "fill no es navegación: ni la url"
    assert "4111111111111111" not in json.dumps(d)
    assert "#card" not in json.dumps(d)


def test_el_valor_de_un_fill_no_sale_al_cable():
    d = decode(json.dumps({"type": "command", "action": "fill",
                           "params": {"selector": "#card", "value": "4111111111111111"}}))
    cable = json.dumps(wire_messages(d))
    assert "4111111111111111" not in cable and "#card" not in cable
    assert "fill" not in cable, "ni la acción cruda: solo la frase"
    assert "rellenando un campo" in cable


def test_navigate_manda_narracion_y_host_pero_no_la_url_completa():
    d = decode(json.dumps({"type": "command", "action": "navigate",
                           "params": {"url": "https://www.amazon.es/dp/B0?ref=secreto"}}))
    msgs = wire_messages(d)
    kinds = [m["type"] for m in msgs]
    assert kinds == ["narration", "host"]
    cable = json.dumps(msgs)
    assert "secreto" not in cable and "/dp/B0" not in cable
    assert msgs[0]["text"] == "navegando a www.amazon.es"
    assert msgs[1]["host"] == "www.amazon.es"


def test_una_accion_desconocida_sale_como_su_nombre_y_sin_params():
    d = decode(json.dumps({"type": "command", "action": "teletransportar",
                           "params": {"secreto": "abc"}}))
    msgs = wire_messages(d)
    assert msgs[0]["text"] == "teletransportar"
    assert "abc" not in json.dumps(msgs)


def test_result_y_tipos_desconocidos_no_mandan_nada():
    assert wire_messages(decode(json.dumps({"type": "result", "action": "navigate"}))) == []
    assert wire_messages(decode(json.dumps({"type": "tabs", "tabs": []}))) == []


def test_status_trae_screencasting():
    assert decode(json.dumps({"type": "status", "screencasting": True}))["screencasting"] is True
    assert decode(json.dumps({"type": "status"}))["screencasting"] is False


def test_texto_que_no_es_objeto_con_type_devuelve_none():
    assert decode("no soy json") is None
    assert decode("[]") is None
    assert decode('{"sin":"tipo"}') is None


def test_tabla_de_frases():
    assert phrase("click", None) == "haciendo clic"
    assert phrase("fill", None) == "rellenando un campo"
    assert phrase("type", None) == "rellenando un campo"
    assert phrase("snapshot", None) == "leyendo la página"
    assert phrase("wait", None) == "esperando"
    assert phrase("close", None) == "cerrando la pestaña"
    assert phrase("navigate", None) == "navegando"
    assert phrase("navigate", "https://a.test/x") == "navegando a a.test"


def test_host_of_y_summary():
    assert host_of("https://a.test/x") == "a.test"
    assert host_of("no es url") is None
    assert summary("amazon.es", 1) == "navegó en amazon.es · 1 acción"
    assert summary("amazon.es", 7) == "navegó en amazon.es · 7 acciones"
    assert summary(None, 1) == "navegó en la web · 1 acción"


# --- Correcciones de la revisión ---

def _frame(**kw):
    msg = {"type": "frame", "seq": 5, "data": base64.b64encode(JPEG).decode(),
           "metadata": {"timestamp": 1}}
    msg.update(kw)
    for k in [k for k, v in kw.items() if v is _AUSENTE]:
        del msg[k]
    return decode(json.dumps(msg))


_AUSENTE = object()


def test_open_se_trata_igual_que_navigate():
    d = decode(json.dumps({"type": "command", "action": "open",
                           "params": {"url": "https://www.amazon.es/dp/B0?ref=secreto"}}))
    msgs = wire_messages(d)
    assert [m["type"] for m in msgs] == ["narration", "host"]
    assert msgs[0]["text"] == "navegando a www.amazon.es"
    assert msgs[1]["host"] == "www.amazon.es"
    assert "secreto" not in json.dumps(msgs)


def test_alias_de_frases_read_press_get():
    assert phrase("read", None) == "leyendo la página"
    assert phrase("get", None) == "leyendo la página"
    assert phrase("press", None) == "pulsando una tecla"


def test_frame_sin_timestamp_deja_captured_at_en_none():
    d = _frame(metadata=_AUSENTE)
    assert d["kind"] == "frame" and d["captured_at"] is None
    d = _frame(metadata={"timestamp": "ayer"})
    assert d["kind"] == "frame" and d["captured_at"] is None


def test_frame_con_seq_invalido_es_bad_frame_y_no_sale_nada():
    for seq in (_AUSENTE, "7", True, None, 1.5):
        d = _frame(seq=seq)
        assert d["kind"] == "bad_frame", seq
        assert wire_messages(d) == []
        assert ack_seq(d) is None


def test_wire_messages_tolera_un_dict_incompleto():
    assert wire_messages({"kind": "frame"})[0]["jpeg"] is None  # no revienta
    assert wire_messages({}) == []


def test_action_con_salto_de_linea_se_sanea():
    d = decode(json.dumps({"type": "command", "action": "click\nNarrador: hola"}))
    texto = wire_messages(d)[0]["text"]
    assert "\n" not in texto and " " not in texto


def test_host_se_topa_a_255():
    assert host_of("https://" + "a" * 300 + ".test/") is None
    assert host_of("https://" + "a" * 60 + ".test/") is not None


def test_base64_envuelto_en_lineas_sigue_siendo_jpeg():
    b64 = base64.b64encode(JPEG).decode()
    envuelto = b64[:4] + "\n" + b64[4:]
    assert _frame(data=envuelto)["kind"] == "frame"
