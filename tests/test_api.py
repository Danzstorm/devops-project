"""Tests de la API."""

EJEMPLO = "https://www.anthropic.com/"


def test_crear_link_devuelve_slug_y_url_corta(client):
    r = client.post("/links", json={"url": EJEMPLO})

    assert r.status_code == 201
    body = r.json()
    assert body["url"] == EJEMPLO
    assert len(body["slug"]) == 7
    assert body["short_url"].endswith(body["slug"])


def test_seguir_slug_redirige_al_destino(client):
    slug = client.post("/links", json={"url": EJEMPLO}).json()["slug"]

    # follow_redirects=False para inspeccionar la respuesta 307 en si misma,
    # no el resultado de seguirla.
    r = client.get(f"/{slug}", follow_redirects=False)

    assert r.status_code == 307
    assert r.headers["location"] == EJEMPLO


def test_slug_inexistente_da_404(client):
    assert client.get("/noexiste", follow_redirects=False).status_code == 404


def test_url_invalida_se_rechaza_en_el_borde(client):
    # 422 y no 500: la validacion ocurre antes de tocar la base de datos.
    assert client.post("/links", json={"url": "esto-no-es-una-url"}).status_code == 422


def test_health_no_depende_de_la_base(client, monkeypatch):
    # Con la base caida, liveness DEBE seguir en verde. Si fallara, Kubernetes
    # reiniciaria los pods en bucle durante una caida de Postgres.
    monkeypatch.setattr("app.main.check_db", lambda: False)

    r = client.get("/health")

    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_ready_da_503_si_la_base_no_responde(client, monkeypatch):
    monkeypatch.setattr("app.main.check_db", lambda: False)

    r = client.get("/ready")

    assert r.status_code == 503
    assert r.json()["status"] == "database unavailable"


def test_ready_ok_con_base_disponible(client, monkeypatch):
    monkeypatch.setattr("app.main.check_db", lambda: True)

    assert client.get("/ready").status_code == 200


def test_metrics_expone_formato_prometheus(client):
    client.post("/links", json={"url": EJEMPLO})

    r = client.get("/metrics")

    assert r.status_code == 200
    assert "http_requests_total" in r.text
