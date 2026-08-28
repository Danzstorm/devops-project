"""Entorno de Alembic.

Dos cambios respecto a la plantilla que genera `alembic init`:

1. La URL de conexion se toma de la configuracion de la app (variable de
   entorno DATABASE_URL), no de alembic.ini. Asi la migracion y la aplicacion
   apuntan siempre a la misma base por construccion, y no hay credenciales en
   un archivo versionado.

2. target_metadata apunta al Base de la app, que es lo que permite
   `alembic revision --autogenerate`: Alembic compara el estado real de la base
   contra los modelos y escribe la diferencia.
"""

from logging.config import fileConfig

from sqlalchemy import engine_from_config, pool

from alembic import context
from app.config import get_settings
from app.models import Base

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

config.set_main_option("sqlalchemy.url", get_settings().database_url)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    """Genera el SQL sin conectarse. Util para que un DBA revise antes de aplicar."""
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            # Necesario en SQLite: no soporta ALTER TABLE completo y sin esto
            # cualquier migracion que modifique una columna falla en desarrollo.
            render_as_batch=connection.dialect.name == "sqlite",
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
