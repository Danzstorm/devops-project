"""Configuracion de la aplicacion.

12-factor, factor III: **la configuracion vive en el entorno, no en el codigo**.

La misma imagen de contenedor tiene que poder correr en tu portatil, en CI y en
produccion sin recompilarse. Lo unico que cambia entre esos tres sitios son las
variables de entorno. Si un valor esta escrito en el codigo, ya no puedes hacer
eso: necesitas una build por entorno, y ahi empiezan los problemas.

Los defaults de este archivo son SOLO para desarrollo local. Ninguno es valido
en produccion, y eso es intencional: si algo falta, queremos enterarnos.
"""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # extra="ignore" para que una variable de entorno ajena no tumbe el arranque.
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = "linkshort"
    log_level: str = "INFO"
    base_url: str = "http://localhost:8000"

    # SQLite por defecto: `uv run uvicorn app.main:app` funciona sin levantar
    # nada mas. En contenedor y en Kubernetes siempre llega DATABASE_URL
    # apuntando a Postgres.
    database_url: str = "sqlite+pysqlite:///./linkshort.db"

    slug_length: int = 7


@lru_cache
def get_settings() -> Settings:
    """Leer el entorno una vez por proceso, no en cada request."""
    return Settings()
