"""Conexion a la base de datos."""

from collections.abc import Iterator

from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session, sessionmaker

from app.config import get_settings

_settings = get_settings()

engine = create_engine(
    _settings.database_url,
    # pool_pre_ping hace un ping antes de entregar una conexion del pool.
    # Sin esto, cualquier cosa que corte conexiones inactivas -- un reinicio de
    # Postgres, un firewall, el balanceador de la nube -- te deja conexiones
    # muertas en el pool, y el primer request que las toque falla sin motivo
    # aparente. Cuesta un round-trip y ahorra incidentes.
    pool_pre_ping=True,
)

SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_session() -> Iterator[Session]:
    """Dependencia de FastAPI: una sesion por request, cerrada pase lo que pase.

    Al ser una dependencia inyectable, los tests pueden sustituirla por una que
    apunte a SQLite en memoria sin tocar el codigo de los endpoints.
    """
    with SessionLocal() as session:
        yield session


def check_db() -> bool:
    """Ping real contra la base. Lo usa /ready.

    Se ejecuta una query de verdad, no se mira si el objeto engine existe: el
    engine existe siempre, incluso con la base apagada.
    """
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception:
        return False
