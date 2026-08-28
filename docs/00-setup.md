# Fase 0 — Setup y fundamentos

> **Objetivo:** dejar la máquina lista y, sobre todo, entender el modelo de trabajo que
> vamos a seguir en las nueve fases siguientes.

---

## 1. Por qué esta fase existe

La tentación al empezar en DevOps es abrir un tutorial de Docker y escribir un
`Dockerfile`. El problema es que DevOps no es una herramienta, es **una forma de trabajar
donde el estado del sistema está descrito en un repositorio y todo lo demás se deriva de
ahí automáticamente**.

Si esa idea no está clara al principio, terminas con lo de siempre: un cluster que alguien
tocó a mano, un servidor que nadie sabe reconstruir, y un despliegue que solo funciona
si lo hace la persona correcta desde su portátil.

Así que la Fase 0 establece dos cosas: **el entorno reproducible** y **las reglas del
juego**.

---

## 2. Las reglas del juego

Estas cuatro reglas se aplican desde el primer commit y no se rompen en ninguna fase.

### El repositorio es la única fuente de verdad

Si un valor de configuración, un manifiesto o una regla de infraestructura no está en
git, **no existe**. Más adelante (Fase 6) instalaremos Argo CD, que activamente revierte
cualquier cambio hecho a mano en el cluster. Eso no es un castigo: es la garantía de que
lo que lees en el repo es lo que realmente está corriendo.

### Trunk-based: `main` protegida, ramas cortas, PR obligatorio

Hay dos modelos de ramas populares:

| | **Gitflow** | **Trunk-based** (el que usamos) |
|---|---|---|
| Ramas vivas | `main`, `develop`, `release/*`, `hotfix/*` | `main` + ramas de horas o días |
| Integración | tardía, en bloques grandes | continua, en piezas pequeñas |
| Conflictos | frecuentes y dolorosos | raros y triviales |
| Encaja con CI/CD | mal | es su premisa |

Gitflow se diseñó en 2010 para software que se publicaba en versiones cada varios meses.
Si despliegas varias veces al día, sobra. Nosotros usamos **trunk-based**: ramas que viven
horas, un PR, CI en verde, merge.

La regla concreta: **nunca `git push` directo a `main`**. Ni siquiera para un typo. En la
Fase 3, cuando exista el pipeline de CI, activaremos la protección en GitHub para que sea
la plataforma la que lo impida, y no tu disciplina.

### Conventional commits

`feat:`, `fix:`, `ci:`, `docs:`, `chore:`. Un prefijo por commit. No es estética: permite
generar changelogs y calcular versiones automáticamente, y sobre todo obliga a que cada
commit tenga **un** propósito.

### Ningún secreto en git

Nunca. Ni "temporalmente", ni en una rama que vas a borrar. Un secreto commiteado está
comprometido para siempre: el historial de git es inmutable y probablemente ya se replicó.
La única respuesta correcta es **rotar la credencial**. En la Fase 3 automatizamos la
detección (gitleaks) y en la Fase 8 resolvemos el problema de fondo (SOPS + age).

---

## 3. Qué se construyó en esta fase

```
devops-project/
├─ .gitignore            # qué NO entra en git
├─ .env.example          # plantilla de configuración; el .env real nunca se commitea
├─ README.md             # el mapa del proyecto
├─ scripts/preflight.ps1 # verificación del entorno
└─ docs/00-setup.md      # este archivo
```

### `scripts/preflight.ps1`

La primera automatización del proyecto, y no es casualidad que sea esta. Comprueba que
estén las nueve herramientas y —esto importa— que **el daemon de Docker responda**, no
solo que el cliente `docker` exista. Es una distinción que causa confusión real: `docker
--version` funciona perfectamente con Docker Desktop cerrado, y luego `docker build` falla
con un error que no dice nada obvio.

Sale con código `1` si falta algo. Ese detalle es lo que lo hace útil en un script o en
CI, y no solo bonito en pantalla.

**Herramientas y para qué sirve cada una:**

| Herramienta | Para qué |
|---|---|
| `git` | control de versiones |
| `uv` | gestor de Python: entornos, dependencias, lockfile y ejecución |
| `docker` | construir y correr contenedores |
| `kubectl` | hablar con el cluster |
| `kind` | levantar un cluster Kubernetes real dentro de Docker |
| `helm` | instalar componentes de terceros (ingress, monitoreo) |
| `terraform` | describir la infraestructura como código |
| `jq` | parsear JSON en scripts |
| `gh` | operar GitHub desde la terminal |

### `.gitignore`

Vale la pena mirar dos decisiones:

- **`uv.lock` NO está ignorado.** Se commitea a propósito. Es el archivo que garantiza que
  tu portátil, el runner de CI y la imagen Docker instalen exactamente las mismas
  versiones, hasta el hash. Sin él, "funciona en mi máquina" deja de ser una excusa y pasa
  a ser una descripción técnicamente correcta del problema.
- **`*.tfstate` sí está ignorado.** El estado de Terraform contiene valores sensibles en
  claro. Se hablará de esto en la Fase 5, cuando veamos el estado remoto.

---

## 4. Verificación

```powershell
.\scripts\preflight.ps1
```

Debe salir todo en verde y con código de salida `0`:

```powershell
.\scripts\preflight.ps1 ; $LASTEXITCODE   # tiene que imprimir 0
```

Y el repositorio debe existir en GitHub como privado.

---

## 5. Lo que viene

**Fase 1 — La aplicación.** Una API FastAPI escrita según los 12-factor: toda la
configuración por variables de entorno, logs estructurados a stdout, migraciones
versionadas, y endpoints de `/health` y `/ready` separados —una distinción que parece
trivial y que en la Fase 4 será la diferencia entre un despliegue limpio y un servicio
caído.

---

## 6. Tropiezos reales de esta fase

Se dejan documentados porque *esto* es el trabajo real, no el camino feliz de los
tutoriales.

### El daemon de Docker estaba apagado

`docker --version` respondía sin problema, pero `docker info` fallaba con:

```
failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine
```

El cliente y el daemon son dos cosas distintas. Docker Desktop tiene que estar **abierto**
y mostrando "Engine running". Por eso el preflight comprueba las dos cosas por separado.

### El ID del paquete de Terraform estaba mal

`winget install --id HashiCorp.Terraform` devolvía "No se encontró ningún paquete". El ID
real es **`Hashicorp.Terraform`** — con `h` minúscula. Los IDs de winget distinguen
mayúsculas. Cuando uno falla, `winget search <nombre>` da el ID correcto.

### `terraform` y `jq` se instalaron pero no estaban en el PATH

Este es sutil y vale la pena entenderlo. winget instala de dos formas:

- **Añadiendo la carpeta del paquete al PATH del usuario** — es lo que hizo con `kind` y
  `helm`, y funcionó a la primera.
- **Creando un alias de ejecución** en `%LOCALAPPDATA%\Microsoft\WinGet\Links` — es lo que
  intentó con `terraform` y `jq`. Esa carpeta no existía en esta máquina, así que los
  binarios quedaron instalados pero inalcanzables.

Se arregló añadiendo sus carpetas al PATH de usuario. Los binarios están en:

```
%LOCALAPPDATA%\Microsoft\WinGet\Packages\Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe\
%LOCALAPPDATA%\Microsoft\WinGet\Packages\jqlang.jq_Microsoft.Winget.Source_8wekyb3d8bbwe\
```

> **Nota importante sobre el PATH:** un cambio en el PATH **no afecta a las terminales ya
> abiertas**. Los procesos heredan las variables de entorno al arrancar. Si acabas de
> instalar algo y "no lo encuentra", cierra la terminal y abre una nueva antes de
> sospechar de nada más.

Este tropiezo, por cierto, es exactamente el argumento a favor de los contenedores: en la
Fase 2 dejamos de depender de qué hay instalado en la máquina y de cómo está su PATH.
