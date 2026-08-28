# Fase 2 — Contenedores

> **Objetivo:** que la app deje de depender de lo que tengas instalado en tu máquina.

---

## 1. El problema que resuelve un contenedor

En la Fase 0 nos mordió dos veces lo mismo: `terraform` y `jq` estaban instalados pero no
en el PATH; y la terminal veía un PATH viejo. Ninguno de los dos era un problema del
proyecto — eran problemas de *esa máquina, en ese momento*.

Multiplica eso por cada portátil del equipo, por el runner de CI y por cada servidor. Esa
es la clase entera de problemas que resuelve un contenedor: **la imagen lleva dentro el
sistema operativo, el intérprete de Python y las dependencias exactas**, y corre igual en
cualquier sitio con un runtime de contenedores.

A partir de aquí, "funciona en mi máquina" empieza a significar algo.

---

## 2. El Dockerfile, decisión por decisión

### Multi-stage: dos imágenes, solo una se publica

```dockerfile
FROM python:3.12-slim AS builder     # aquí viven uv y todo lo que ensucia
...
FROM python:3.12-slim AS runtime     # aquí solo Python, el venv y el código
COPY --from=builder --chown=app:app /app /app
```

El stage `builder` puede ser tan sucio como haga falta: instala uv, descarga paquetes, deja
cachés. Nada de eso llega a la imagen final, porque `runtime` empieza de cero y solo copia
el resultado.

Verificado en la imagen construida:

```
$ which uv gcc pip
/usr/local/bin/pip
ni uv ni gcc: correcto
```

(`pip` viene de serie en la imagen base de Python; se elimina en la Fase 8, cuando toque
endurecer.)

### El orden de los `COPY` es la diferencia entre 3 segundos y 3 minutos

```dockerfile
COPY pyproject.toml uv.lock ./       # 1. primero los manifiestos
RUN uv sync --locked --no-dev        # 2. instalar dependencias
COPY app ./app                       # 3. y AHORA el código
```

Docker cachea capa a capa: si los archivos que entran en una capa no han cambiado, reutiliza
la capa entera y no ejecuta el `RUN`. Como el código cambia cien veces al día y las
dependencias una vez al mes, el orden correcto es ese.

**Al revés** —copiar el código primero— cada cambio de una línea en `main.py` invalidaría la
capa de dependencias y reinstalaría todo. Es el error de Dockerfile más común que existe.

### `uv sync --locked --no-dev`

- **`--locked`**: instala exactamente lo que dice `uv.lock` y **falla** si el lockfile está
  desactualizado respecto a `pyproject.toml`. Sin esta bandera, el build podría resolver
  versiones distintas a las que probaste — la imagen dejaría de ser reproducible en
  silencio, que es la peor forma de dejar de serlo.
- **`--no-dev`**: `pytest` y `ruff` no hacen nada en producción. Menos paquetes, menos
  superficie de ataque, imagen más pequeña.

### Versiones fijas, nunca `:latest`

```dockerfile
COPY --from=ghcr.io/astral-sh/uv:0.11.6 /uv /bin/uv
FROM python:3.12-slim
image: postgres:17-alpine
```

`:latest` es una etiqueta móvil: apunta a algo distinto cada semana. Una build que depende
de `:latest` puede romperse sin que nadie haya tocado el repositorio, y —peor— puede
*funcionar* con una versión distinta a la que probaste. El día que investigues un fallo, no
podrás reproducir la imagen que estaba corriendo.

Esta misma regla se aplicará a **nuestra propia imagen** en la Fase 3: se etiqueta con el
SHA del commit, y `latest` solo existe por comodidad.

### Usuario no-root

```dockerfile
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
USER app
```

Por defecto un contenedor corre como **root**, y salvo que se usen user namespaces, ese root
es el mismo UID 0 del kernel del host. Una vulnerabilidad de escape del contenedor te deja
con root en la máquina.

Además, sin privilegios, un atacante que logre ejecutar código no puede escribir en `/usr`
ni instalar herramientas:

```
$ touch /usr/local/lib/prueba
touch: cannot touch '/usr/local/lib/prueba': Permission denied
```

El UID es **numérico, fijo y alto** a propósito: Kubernetes puede exigir `runAsNonRoot`, y
para verificarlo necesita un UID numérico — con un nombre de usuario no puede saber si es
root o no.

### `CMD` en forma exec, y por qué importa en cada despliegue

```dockerfile
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]   # exec
# NO:  CMD uvicorn app.main:app --host 0.0.0.0                            # shell
```

En forma exec, uvicorn es el **PID 1** y recibe directamente las señales:

```
$ cat /proc/1/cmdline
/app/.venv/bin/python /app/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
```

En forma shell, el PID 1 sería `/bin/sh`, que **no reenvía señales** a sus hijos. Cuando
Kubernetes manda `SIGTERM` para terminar un pod, uvicorn nunca se entera: espera los 30
segundos del periodo de gracia y luego recibe `SIGKILL`. Resultado: **cada despliegue corta
las peticiones en curso**. Un carácter de sintaxis, un incidente recurrente.

### `PYTHONUNBUFFERED=1`

Python bufferiza stdout cuando no es una terminal — y dentro de un contenedor nunca lo es.
Sin esta variable los logs salen a trozos, con retraso, y **se pierden enteros si el proceso
muere de golpe**. Justo cuando más los necesitas.

### `HEALTHCHECK`

Lo usan `docker compose` y `docker ps`. Apunta a `/health` (liveness), nunca a `/ready`.

> En Kubernetes **este healthcheck no se usa**: allí mandan las probes del Deployment, que
> configuramos en la Fase 4. Es el mismo concepto en dos sitios distintos.

---

## 3. `.dockerignore`: tres motivos, uno de ellos de seguridad

Sin él, el contexto de build entero viaja al daemon de Docker.

1. **Velocidad** — `.git` y `.venv` son cientos de megas enviados en cada build.
2. **Caché** — cualquier archivo enviado que cambie invalida capas. Si `docs/` viajara,
   editar un `.md` reconstruiría la imagen.
3. **Seguridad** — `.env` con credenciales acabaría **dentro de la imagen**. Y una imagen se
   publica en un registro, se copia y se comparte. Un secreto ahí dentro está tan
   comprometido como uno commiteado.

---

## 4. `docker-compose.yml`: la orquestación en pequeño

### El healthcheck no es decoración

```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
```

Es lo que hace que el `depends_on` de abajo signifique **"cuando Postgres acepte
conexiones"** y no "cuando el contenedor haya arrancado". Son cosas distintas: Postgres tarda
unos segundos en estar listo, y ese hueco es exactamente donde fallan las migraciones.

### `migrate` es un contenedor de un solo uso

```yaml
migrate:
  build: .
  command: ["alembic", "upgrade", "head"]
  depends_on:
    db: { condition: service_healthy }

api:
  depends_on:
    migrate: { condition: service_completed_successfully }
```

**Misma imagen, otro comando.** Las migraciones no corren dentro del arranque de la API: con
varias réplicas serían varios procesos tocando el esquema a la vez.

Y la API no arranca hasta que la migración termina **bien**. Si falla, la API ni se levanta:
mejor no arrancar que arrancar contra un esquema a medias.

> Este servicio es el equivalente exacto del **`Job` de Kubernetes** de la Fase 4. Compose
> es un buen sitio para entender el patrón antes de que además haya que lidiar con YAML de
> Kubernetes.

La secuencia real al levantar:

```
db        Started → Waiting → Healthy
migrate   Started → Exited            ← corrió, terminó, se fue
api       Started
```

### `db`, no `localhost`

```yaml
DATABASE_URL: postgresql+psycopg://...@db:5432/...
```

Dentro de la red de Compose cada servicio resuelve por su nombre. `localhost` sería el propio
contenedor de la API, donde no hay ningún Postgres escuchando. Este mismo cambio de mentalidad
—**los servicios se llaman por nombre, no por dirección**— es la base del descubrimiento de
servicios en Kubernetes.

### El volumen con nombre

```yaml
volumes:
  - pgdata:/var/lib/postgresql/data
```

Sin él, cada `docker compose down` empezaría con la base vacía. Comprobado:

```
slug guardado antes del reinicio: n936J-k
$ docker compose down && docker compose up -d
GET /n936J-k -> HTTP 307 -> https://kubernetes.io/docs/     ← sobrevivió
```

### Los defaults son de desarrollo, y cantan

```yaml
POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-devpassword}
```

Con la sintaxis `${VAR:-default}` esto arranca sin configurar nada. Si existe un `.env`,
Compose lo lee y sus valores ganan. La contraseña se llama `devpassword` precisamente para
que sea evidente si alguna vez aparece en un entorno real.

---

## 5. La migración, ahora contra Postgres de verdad

Esto valida el arreglo de la Fase 1:

```
migrate-1  | INFO  [alembic.runtime.migration] Context impl PostgresqlImpl.
migrate-1  | INFO  [alembic.runtime.migration] Running upgrade  -> 278ef5198bc9, crear tabla links
```

Y la tabla resultante en Postgres:

```
   Column   |           Type           | Nullable |      Default
------------+--------------------------+----------+-------------------
 slug       | character varying(16)    | not null |
 url        | character varying(2048)  | not null |
 created_at | timestamp with time zone | not null | CURRENT_TIMESTAMP
Indexes:
    "links_pkey" PRIMARY KEY, btree (slug)
```

`CURRENT_TIMESTAMP` sin paréntesis, aplicado limpiamente. Si no lo hubiéramos corregido en la
Fase 1, la migración habría llegado hasta aquí con sintaxis de SQLite dentro.

---

## 6. Verificación

```powershell
docker compose up --build -d
docker compose ps            # db healthy, api healthy, migrate exited
```

```powershell
curl.exe http://localhost:8000/ready
# {"status":"ok"}   <- ahora consulta Postgres de verdad, no SQLite

curl.exe -X POST http://localhost:8000/links -H "Content-Type: application/json" -d '{\"url\":\"https://kubernetes.io/docs/\"}'
curl.exe -i http://localhost:8000/<slug>     # 307
```

Comprobaciones de la imagen:

```powershell
docker compose exec api id                    # uid=10001(app)  -> no root
docker compose exec api cat /proc/1/cmdline   # uvicorn es PID 1
docker compose exec api touch /usr/local/lib/x  # Permission denied
```

Limpiar del todo (incluido el volumen):

```powershell
docker compose down -v
```

---

## 7. Deuda consciente

- **La imagen pesa 300 MB.** `python:3.12-slim` trae bastante sistema. En la Fase 8 se
  evalúa distroless, que baja mucho pero complica depurar (no hay shell dentro).
- **`pip` sigue presente** en la imagen final: viene de la base. Es superficie de ataque
  innecesaria; se quita en la Fase 8.
- **El sistema de ficheros aún es escribible.** `readOnlyRootFilesystem` llega en la Fase 4,
  cuando haya un `securityContext` de Kubernetes donde declararlo.

Se dejan pendientes a propósito: cada una encaja mejor en su fase, con su contexto.

---

## 8. Lo que viene

**Fase 3 — CI en GitHub Actions.** Hasta ahora todo se ha construido y verificado en tu
máquina. A partir de la siguiente fase lo hace un runner limpio en cada Pull Request: lint,
tests contra un Postgres real, build de la imagen, escaneo de vulnerabilidades y publicación
en el registro. Y `main` pasa a estar protegida de verdad.
