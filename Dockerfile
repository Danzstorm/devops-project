# syntax=docker/dockerfile:1

# =============================================================================
# Stage 1 - build: aqui viven uv, las cabeceras y todo lo que ensucia.
# Nada de esto llega a la imagen final.
# =============================================================================
FROM python:3.12-slim AS builder

# uv entra como binario desde su propia imagen. Version FIJA, no :latest:
# una imagen que cambia sola no es reproducible, y el dia que uv publique un
# cambio incompatible el build se rompe sin que nadie haya tocado el repo.
COPY --from=ghcr.io/astral-sh/uv:0.11.6 /uv /bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# ---- Capa de dependencias -------------------------------------------------
# Se copian SOLO los manifiestos, antes que el codigo. Docker cachea por capa:
# mientras pyproject.toml y uv.lock no cambien, esta capa se reutiliza y el
# `uv sync` no se vuelve a ejecutar. Si copiaramos el codigo primero, cada
# cambio de una linea en main.py reinstalaria todas las dependencias.
COPY pyproject.toml uv.lock ./

# --locked: instala EXACTAMENTE lo que dice uv.lock y falla si el lockfile
#   esta desactualizado respecto a pyproject.toml. Sin esto, el build podria
#   resolver versiones distintas a las que probaste.
# --no-dev: pytest y ruff no pintan nada en produccion. Menos superficie.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev

# ---- Capa de codigo -------------------------------------------------------
COPY app ./app
COPY alembic ./alembic
COPY alembic.ini ./

# =============================================================================
# Stage 2 - runtime: solo Python, el venv y el codigo. Sin uv, sin compiladores,
# sin cache de paquetes, sin tests.
# =============================================================================
FROM python:3.12-slim AS runtime

# Usuario sin privilegios. Por defecto un contenedor corre como root, y root
# dentro del contenedor es (salvo user namespaces) root en el kernel del host:
# una escapada del contenedor te deja con root en la maquina. Ademas, si un
# atacante logra ejecucion, no puede escribir en /usr ni instalar nada.
# UID fijo y >10000 por convencion: Kubernetes puede exigir runAsNonRoot y
# necesita un UID numerico explicito para verificarlo.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

COPY --from=builder --chown=app:app /app /app

ENV PATH="/app/.venv/bin:$PATH" \
    # Sin esto Python bufferiza stdout y los logs aparecen a trozos, tarde y
    # desordenados -- o se pierden enteros si el proceso muere de golpe.
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER app

EXPOSE 8000

# Healthcheck a nivel de imagen: lo usan docker compose y `docker ps`.
# En Kubernetes NO se usa este: alli mandan las probes del Deployment (Fase 4).
# Se llama a /health (liveness), nunca a /ready.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request as u, sys; sys.exit(0 if u.urlopen('http://127.0.0.1:8000/health', timeout=2).status == 200 else 1)"

# Forma exec (lista JSON) y no forma shell: asi uvicorn es el PID 1 y recibe
# directamente el SIGTERM. En forma shell el PID 1 seria /bin/sh, que no
# reenvia senales, y Kubernetes acabaria matando el pod con SIGKILL tras el
# periodo de gracia -- cortando requests en curso en cada despliegue.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
