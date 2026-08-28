# devops-project — `linkshort`

[![CI](https://github.com/Danzstorm/devops-project/actions/workflows/ci.yml/badge.svg)](https://github.com/Danzstorm/devops-project/actions/workflows/ci.yml)

Proyecto de aprendizaje **DevOps end-to-end**. La aplicación (un acortador de URLs) es
pequeña a propósito: lo que se está aprendiendo no es la app, es **todo lo que hay
alrededor** para llevarla desde tu editor hasta un cluster, de forma repetible, segura y
observable.

## Cómo leer este repo

Empieza por `docs/`. Hay un documento por fase que explica **qué** se construyó, **por
qué** se hizo así y **cómo verificarlo**. El código es la consecuencia; los documentos son
el proyecto.

## Fases

| # | Fase | Estado | Doc |
|---|------|--------|-----|
| 0 | Setup y fundamentos | ✅ | [docs/00-setup.md](docs/00-setup.md) |
| 1 | La aplicación (FastAPI + Postgres) | ✅ | [docs/01-app.md](docs/01-app.md) |
| 2 | Contenedores (Docker) | ✅ | [docs/02-contenedores.md](docs/02-contenedores.md) |
| 3 | CI (GitHub Actions) | ✅ | [docs/03-ci.md](docs/03-ci.md) |
| 4 | Kubernetes local (kind) | ✅ | [docs/04-kubernetes.md](docs/04-kubernetes.md) |
| 5 | IaC (Terraform) | ✅ | [docs/05-iac.md](docs/05-iac.md) |
| 6 | CD con GitOps (Argo CD) | 🔨 siguiente | — |
| 7 | Observabilidad (Prometheus + Grafana) | ⏳ | — |
| 8 | Seguridad | ⏳ | — |
| 9 | Nube (opcional) | ⏳ | — |

## Empezar

```powershell
.\scripts\preflight.ps1     # verifica que tengas todas las herramientas
uv sync                     # instala dependencias exactas desde uv.lock
uv run pytest               # 8 tests
uv run uvicorn app.main:app # http://localhost:8000/docs
```

O el entorno completo con Postgres, sin instalar nada de Python:

```powershell
docker compose up --build   # http://localhost:8000/docs
docker compose down -v      # -v borra tambien el volumen de datos
```

O en un cluster de Kubernetes de verdad, creado con Terraform:

```powershell
terraform -chdir=terraform init
terraform -chdir=terraform apply           # cluster + complementos
kubectl apply -k k8s/overlays/dev          # http://localhost:8000/docs
terraform -chdir=terraform destroy         # se lo lleva todo
```

## Reglas del proyecto

- `main` está protegida. Todo cambio entra por rama corta + Pull Request con CI en verde.
- Commits en formato [Conventional Commits](https://www.conventionalcommits.org/):
  `feat:`, `fix:`, `ci:`, `docs:`, `chore:`.
- **Si no está en el repo, no existe.** Nada se configura a mano en el cluster.
- Ningún secreto en git, nunca. Se valida automáticamente.
- Python se gestiona **solo con `uv`**. `uv.lock` se commitea.
