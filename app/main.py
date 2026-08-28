"""API de linkshort.

Endpoints:
    POST /links     crear un enlace corto
    GET  /{slug}    seguir un enlace corto (307)
    GET  /health    liveness  -- ¿el proceso vive?
    GET  /ready     readiness -- ¿puede atender trafico ahora?
    GET  /metrics   metricas Prometheus
"""

import logging
import secrets
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Response
from fastapi.responses import RedirectResponse
from prometheus_fastapi_instrumentator import Instrumentator
from pydantic import BaseModel, HttpUrl
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import check_db, get_session
from app.logging_setup import setup_logging
from app.models import Link

settings = get_settings()
setup_logging(settings.log_level)
log = logging.getLogger("linkshort")

app = FastAPI(title=settings.app_name, version="0.1.0")

# Expone /metrics con latencia, throughput y codigos de respuesta por endpoint.
# Se instrumenta ANTES de declarar las rutas propias para que /metrics quede
# registrada antes que el catch-all GET /{slug}.
Instrumentator().instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)


# Alias del tipo inyectado. Es la forma moderna de declarar dependencias en
# FastAPI: el valor por defecto de un parametro deja de ser una llamada a
# funcion (que se evalua una vez al importar el modulo, no por request) y
# pasa a ser metadato del tipo. Ademas se escribe una sola vez.
SessionDep = Annotated[Session, Depends(get_session)]


class LinkIn(BaseModel):
    # HttpUrl valida el formato en el borde. Una URL invalida se rechaza con un
    # 422 antes de tocar la base: validar en el limite de confianza, no despues.
    url: HttpUrl


class LinkOut(BaseModel):
    slug: str
    url: str
    short_url: str


@app.get("/health", include_in_schema=False)
def health() -> dict[str, str]:
    """Liveness: ¿el proceso responde?

    NO toca la base de datos, y es la decision mas importante de este archivo.

    Kubernetes REINICIA el contenedor cuando falla la liveness. Si esta sonda
    dependiera de la base, una caida de Postgres reiniciaria todos los pods en
    bucle: la app perderia su cache, el arranque anadiria carga, y una
    degradacion temporal se convertiria en una caida total. La app esta viva
    aunque su base no lo este.
    """
    return {"status": "ok"}


@app.get("/ready", include_in_schema=False)
def ready(response: Response) -> dict[str, str]:
    """Readiness: ¿puede este pod atender trafico AHORA mismo?

    Aqui SI se comprueba la base, porque sin ella no se puede servir.

    Kubernetes saca el pod del balanceador, pero **no lo mata**. Cuando Postgres
    vuelva, el siguiente sondeo saldra en verde y el pod volvera solo al
    balanceo. Esa es exactamente la diferencia con liveness.
    """
    if not check_db():
        response.status_code = 503
        return {"status": "database unavailable"}
    return {"status": "ok"}


@app.post("/links", response_model=LinkOut, status_code=201)
def create_link(payload: LinkIn, session: SessionDep) -> LinkOut:
    url = str(payload.url)

    for _ in range(5):
        # secrets y no random: random usa un PRNG predecible. Estos slugs son
        # identificadores publicos y adivinables significa enumerables.
        slug = secrets.token_urlsafe(16)[: settings.slug_length]
        session.add(Link(slug=slug, url=url))
        try:
            session.commit()
        except IntegrityError:
            # Colision de slug. Quien la detecta es la clave primaria, no un
            # SELECT previo: entre el SELECT y el INSERT cabe otra transaccion.
            session.rollback()
            continue

        log.info("link creado", extra={"slug": slug})
        return LinkOut(slug=slug, url=url, short_url=f"{settings.base_url.rstrip('/')}/{slug}")

    # Cinco colisiones seguidas no es mala suerte, es que el espacio de slugs se
    # esta agotando. Fallar ruidosamente es mejor que reintentar para siempre.
    log.error("no se pudo generar un slug unico tras 5 intentos")
    raise HTTPException(status_code=503, detail="no se pudo generar un slug unico")


# Esta ruta va LA ULTIMA: es un catch-all y FastAPI resuelve por orden de
# declaracion. Si estuviera arriba, /health se interpretaria como el slug "health".
@app.get("/{slug}", include_in_schema=False)
def follow(slug: str, session: SessionDep) -> RedirectResponse:
    link = session.get(Link, slug)
    if link is None:
        raise HTTPException(status_code=404, detail="slug no encontrado")

    # 307 y no 301: el 301 es permanente y los navegadores lo cachean para
    # siempre. Perderiamos la metrica de clics y la posibilidad de cambiar el
    # destino de un enlace ya publicado.
    return RedirectResponse(url=link.url, status_code=307)
