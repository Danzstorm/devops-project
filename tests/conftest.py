"""Fixtures compartidas.

La clave de todo el archivo: la base de datos de los tests **no es la de
desarrollo**. Un test que depende de datos que dejo el test anterior es un test
que falla en CI de forma intermitente, y ese es el peor tipo de fallo: nadie
se lo cree, todo el mundo reintenta el pipeline.
"""

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db import get_session
from app.main import app
from app.models import Base


@pytest.fixture
def client():
    # SQLite en memoria: se crea y se destruye con cada test, sin tocar disco.
    # StaticPool obliga a reutilizar LA MISMA conexion; sin el, cada conexion
    # del pool abriria su propia base en memoria, vacia, y no se veria nada de
    # lo que escribio la anterior.
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )

    # create_all y no alembic: aqui interesa que el test sea rapido. Que las
    # migraciones funcionen se verifica aparte, en el Job de migracion que
    # montamos en la Fase 4 -- son dos cosas distintas y conviene no mezclarlas.
    Base.metadata.create_all(engine)
    TestingSession = sessionmaker(bind=engine, expire_on_commit=False)

    def session_de_test():
        with TestingSession() as session:
            yield session

    # Sustituir la dependencia, no parchear el modulo. Por esto get_session era
    # una dependencia inyectable y no un import directo dentro del endpoint.
    app.dependency_overrides[get_session] = session_de_test
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()
