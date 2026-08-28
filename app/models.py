"""Modelo de datos.

Una sola tabla. El proyecto no trata sobre modelado de datos.
"""

from datetime import datetime

from sqlalchemy import DateTime, String, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class Link(Base):
    __tablename__ = "links"

    # El slug es la clave primaria: la unicidad la garantiza la base de datos,
    # no la aplicacion. Dos procesos concurrentes pueden generar el mismo slug;
    # solo la base puede arbitrar quien gana.
    slug: Mapped[str] = mapped_column(String(16), primary_key=True)
    url: Mapped[str] = mapped_column(String(2048), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
