# Fase 1 — La aplicación

> **Objetivo:** una app que *se pueda operar*. No una app que funcione: eso es el mínimo.
> Una que se pueda desplegar, observar, reiniciar y depurar sin adivinar.

---

## 1. Por qué la app es lo de menos (y aún así importa mucho)

`linkshort` tiene ~150 líneas de lógica. Podría guardar los enlaces en una lista en memoria
y para el usuario funcionaría igual. Pero entonces las ocho fases siguientes serían mentira:
sin base de datos no hay migraciones, ni secretos, ni volúmenes persistentes, ni orden de
arranque, ni sondas de readiness que signifiquen algo.

Lo que sí importa de esta fase son **cuatro decisiones de diseño** que determinan si la app
se puede operar o no. Ninguna tiene que ver con acortar URLs.

---

## 2. Decisión 1: toda la configuración viene del entorno

`app/config.py` — 12-factor, factor III.

```python
class Settings(BaseSettings):
    database_url: str = "sqlite+pysqlite:///./linkshort.db"
```

La regla: **la misma imagen de contenedor tiene que correr en tu portátil, en CI y en
producción sin recompilarse.** Lo único que cambia entre esos tres sitios son variables de
entorno.

Si `database_url` estuviera escrito en el código, necesitarías una build por entorno. Y en
cuanto tienes builds distintas por entorno, lo que probaste en staging **no es** lo que
desplegaste en producción — y "en staging funcionaba" deja de ser una excusa para pasar a
ser una descripción exacta de lo que ocurrió.

Los defaults que ves son solo para desarrollo. SQLite está ahí para que
`uv run uvicorn app.main:app` funcione sin levantar nada más. En Docker y en Kubernetes
siempre llega `DATABASE_URL` apuntando a Postgres.

---

## 3. Decisión 2: `/health` y `/ready` son cosas distintas

Parece un detalle. Es lo más importante de `app/main.py`.

| | `/health` (liveness) | `/ready` (readiness) |
|---|---|---|
| Pregunta | ¿el proceso vive? | ¿puede atender tráfico **ahora**? |
| ¿Toca la base? | **No** | **Sí** |
| Si falla, Kubernetes… | **reinicia el contenedor** | **lo saca del balanceador**, sin matarlo |

Imagina que las juntas en una sola sonda que consulta la base, y Postgres se cae 30
segundos:

1. Liveness falla en todas las réplicas a la vez.
2. Kubernetes reinicia **todos** los pods.
3. Al volver, arrancan simultáneamente y golpean la base que se estaba recuperando.
4. La base vuelve a caer. Vuelta al punto 1.

Una degradación de 30 segundos se convierte en una caída total con bucle de reinicios.

Con las sondas separadas: liveness sigue verde (el proceso está perfectamente vivo),
readiness se pone roja, Kubernetes deja de mandarle tráfico y **cuando Postgres vuelve, el
pod regresa solo al balanceo**. Sin reinicios y sin intervención humana.

Hay un test que fija exactamente esto:

```python
def test_health_no_depende_de_la_base(client, monkeypatch):
    monkeypatch.setattr("app.main.check_db", lambda: False)
    assert client.get("/health").status_code == 200
```

Si alguien "mejora" `/health` añadiéndole un chequeo de base, el test falla y el comentario
explica por qué. Ese test no prueba una función: **protege una decisión de arquitectura**.

---

## 4. Decisión 3: logs en JSON a stdout, y nada más

`app/logging_setup.py` — 12-factor, factor XI.

La app no abre archivos de log, no los rota y no los comprime. Escribe a stdout y se
desentiende. El motivo es concreto: dentro de un contenedor, un archivo vive en un sistema
de ficheros efímero. Cuando el pod muere —y los pods mueren constantemente, es normal— el
archivo se va con él. Justo el log que necesitabas para entender por qué murió.

JSON y no texto plano porque quien lo lee es una máquina:

```json
{"ts": "2026-08-27T20:36:20-0500", "level": "INFO", "logger": "linkshort", "msg": "link creado", "slug": "6zAskGc"}
```

Ese `slug` no está incrustado en el texto del mensaje: es un campo. Buscar todos los eventos
de un slug concreto es un filtro, no una expresión regular.

Dos detalles que costaron una iteración cada uno:

- **uvicorn instala sus propios handlers** con formato de texto. Hay que quitárselos, o la
  mitad de los logs sale en JSON y la otra mitad en texto — y el agregador solo entiende uno
  de los dos formatos.
- **uvicorn cuela un campo `color_message`** que es el mismo mensaje con códigos ANSI de
  color dentro. En una terminal se ve bonito; en un JSON destinado a un agregador es basura
  duplicada. Se filtra.

---

## 5. Decisión 4: el esquema se versiona desde el primer día

`alembic/` — la pieza menos obvia de la fase, así que empecemos por lo básico.

**Alembic es control de versiones para el esquema de la base de datos.** Git versiona tu
código; Alembic versiona tus tablas.

El problema que resuelve: tu código nuevo espera una columna que la base de producción
todavía no tiene. ¿Quién ejecuta ese `ALTER TABLE`, cuándo, y en qué entornos ya se hizo?

| Enfoque | Por qué falla |
|---|---|
| Alguien lo corre a mano por SSH | nadie sabe si se hizo ni dónde; no hay forma de revertir |
| `create_all()` al arrancar la app | crea tablas nuevas pero **nunca modifica** las existentes. Y con 3 réplicas arrancando a la vez, son tres procesos tocando el esquema en paralelo |
| Un `.sql` suelto en una carpeta | no hay registro de cuáles ya se aplicaron |

Alembic guarda cada cambio como un archivo Python encadenado al anterior, y mantiene una
tabla `alembic_version` **dentro de tu propia base** con el ID del último aplicado:

```
$ uv run alembic upgrade head
INFO  Running upgrade  -> 278ef5198bc9, crear tabla links

$ tablas de la base
['alembic_version', 'links']
```

Esa tabla es la clave: **la base sabe en qué versión de esquema está**. Alembic solo corre
lo que falta, en orden, y cada migración lleva su `downgrade()` para revertir.

En la Fase 4 esto se ejecutará como un `Job` de Kubernetes que corre **antes** del
despliegue, no dentro de la app.

### El tropiezo: autogenerate escribió SQLite en una migración destinada a Postgres

`alembic revision --autogenerate` compara los modelos contra la base y escribe la
diferencia. Pero la compara contra **la base que tengas delante**, que en desarrollo es
SQLite. Generó esto:

```python
server_default=sa.text('(CURRENT_TIMESTAMP)')   # los paréntesis son sintaxis de SQLite
```

Corregido a `sa.text("CURRENT_TIMESTAMP")`, que es SQL estándar y vale en ambos motores.

> **La regla que se lleva uno de aquí:** las migraciones autogeneradas **siempre** se
> revisan antes de commitear. Autogenerate produce un borrador, no una respuesta. Y lo
> correcto a partir de la Fase 2, cuando tengamos Postgres en `docker compose`, es
> generarlas contra el mismo motor que corre en producción.

---

## 6. Qué se construyó

```
app/
├─ config.py         # 12-factor: configuración desde el entorno
├─ db.py             # engine, sesión inyectable, check_db()
├─ logging_setup.py  # formateador JSON a stdout
├─ models.py         # tabla links
└─ main.py           # endpoints
alembic/
├─ env.py            # lee DATABASE_URL de la config de la app, no de alembic.ini
└─ versions/         # migraciones encadenadas
tests/
├─ conftest.py       # SQLite en memoria, dependencia sustituida
└─ test_api.py       # 8 tests
pyproject.toml       # deps + ruff + pytest, todo en un solo archivo
uv.lock              # versiones exactas, commiteado
.python-version      # 3.12, uv gestiona el intérprete
```

### Tres detalles del código que vale la pena mirar

**El orden de las rutas importa.** `GET /{slug}` está declarado **el último** a propósito.
FastAPI resuelve por orden de declaración: si estuviera arriba, `/health` se interpretaría
como el slug `"health"`.

**La unicidad la garantiza la base, no la app.** Al crear un link no se hace un `SELECT`
para comprobar si el slug ya existe: se inserta y se captura el `IntegrityError` de la clave
primaria. Entre un `SELECT` y un `INSERT` cabe otra transacción — con tres réplicas
corriendo, eso no es teoría.

**Los tests sustituyen la dependencia, no parchean el módulo.** Por eso `get_session` es una
dependencia inyectable de FastAPI y no un import directo dentro del endpoint: permite que
los tests apunten a SQLite en memoria sin tocar una línea del código de producción.

---

## 7. Verificación

```powershell
uv run ruff check .           # sin errores
uv run pytest                 # 8 passed
uv run alembic upgrade head   # crea alembic_version + links
uv run uvicorn app.main:app   # http://localhost:8000/docs
```

Prueba manual (en otra terminal, con el servidor levantado):

```powershell
curl.exe -X POST http://localhost:8000/links -H "Content-Type: application/json" -d '{\"url\":\"https://www.anthropic.com/\"}'
# -> {"slug":"WzQmnwT","url":"...","short_url":"http://localhost:8000/WzQmnwT"}

curl.exe -i http://localhost:8000/WzQmnwT       # -> HTTP/1.1 307 Temporary Redirect
curl.exe http://localhost:8000/metrics          # -> formato Prometheus
```

> **307 y no 301** en el redirect: el 301 es permanente y los navegadores lo cachean para
> siempre. Perderíamos la métrica de clics y la capacidad de cambiar el destino de un enlace
> ya publicado.

---

## 8. Lo que viene

**Fase 2 — Contenedores.** Empaquetamos esto en una imagen Docker multi-stage con usuario
no-root, y levantamos Postgres de verdad con `docker compose`. Ahí desaparece la última
dependencia de "qué tienes instalado en tu máquina" — que es justo lo que nos mordió dos
veces en la Fase 0 con el PATH.
