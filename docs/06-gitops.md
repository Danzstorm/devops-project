# Fase 6 — CD con GitOps (Argo CD)

> **Estado:** completada
> **Archivos:** `k8s/argocd/application.yaml`, `terraform/main.tf`, anotaciones en `k8s/base/` y `k8s/overlays/dev/`

---

## 1. El último `kubectl apply` a mano

Hasta ahora el despliegue lo hacía una persona escribiendo `kubectl apply -k`. Eso tiene tres
problemas que no se ven hasta que muerden:

- **Nadie sabe qué hay desplegado.** El repositorio dice una cosa; el cluster, lo que le
  aplicaron por última vez. Puede que coincidan.
- **Los cambios a mano son invisibles.** Un `kubectl edit` de madrugada para apagar un fuego
  no deja rastro en ningún sitio, y sobrevive hasta el siguiente despliegue completo.
- **Desplegar exige credenciales del cluster.** Cada persona (y cada CI) necesita acceso de
  escritura a producción.

GitOps invierte la dirección: en vez de empujar cambios *hacia* el cluster, un agente **dentro**
del cluster observa el repositorio y se encarga de que la realidad coincida. Es el mismo bucle
que Terraform aplica a la infraestructura, con una diferencia: Terraform reconcilia cuando
alguien ejecuta `apply`; Argo CD reconcilia **solo, continuamente**.

---

## 2. Dónde vive cada cosa

Se mantiene la frontera de la Fase 5, con un matiz nuevo:

| | Dónde | Por qué |
|---|---|---|
| Argo CD (la herramienta) | Terraform | Es plataforma: se instala una vez y sobrevive a todo |
| La `Application` (qué desplegar) | `k8s/argocd/application.yaml` | Si viviera en Terraform, cambiar de rama sería un `terraform apply` |

La `Application` es **el único manifiesto que se aplica a mano**, y una sola vez:

```bash
kubectl apply -f k8s/argocd/application.yaml
```

A partir de ahí nadie vuelve a ejecutar `kubectl apply -k`. Ese comando pasa a ser una
herramienta de emergencia, no el procedimiento.

```yaml
syncPolicy:
  automated:
    prune: true      # borrar del cluster lo que se borre del repo
    selfHeal: true   # revertir los cambios hechos a mano
```

`prune` evita que el cluster acumule fantasmas que nadie recuerda haber creado. `selfHeal` es
lo que convierte el repositorio en la fuente de verdad **de verdad**, y no en una sugerencia.

---

## 3. El experimento: self-heal

```bash
kubectl -n linkshort delete deploy linkshort
# deployment.apps "linkshort" deleted
```

Diez segundos después, sin que nadie intervenga:

```
NAME        READY   UP-TO-DATE   AVAILABLE   AGE
linkshort   0/2     2            0           5s
```

Argo CD detectó la diferencia entre el repositorio y el cluster, y la corrigió. El mismo
mecanismo que la deriva de Terraform en la Fase 5, pero sin que nadie ejecute nada.

La consecuencia práctica: **para cambiar producción hay que cambiar el repositorio**. Un
arreglo a mano dura lo que tarde la siguiente reconciliación, así que el atajo deja de ser
atajo.

---

## 4. El orden de despliegue: cuatro intentos

Esta parte costó cuatro iteraciones y es lo más instructivo de la fase.

### Intento 1 — `PreSync` y el abrazo mortal

La Fase 4 dejó anotado que el Job de migración pasaría a ser un hook `PreSync`. Parecía
evidente: migrar antes de desplegar. El resultado:

```
Running: waiting for completion of hook batch/Job/linkshort-migrate
```

Colgado para siempre. **`PreSync` se ejecuta antes de sincronizar *nada*, Postgres incluido.**
La migración esperaba una base de datos que la propia sincronización tenía bloqueada.

Con `kubectl apply -k` no pasaba porque todo se creaba a la vez y el Job reintentaba con
backoff hasta que Postgres aparecía. Al ordenar el despliegue, se rompió lo que funcionaba
por accidente.

**Arreglo:** `hook: Sync` en vez de `PreSync`. Así el Job participa en la fase de
sincronización normal y respeta las `sync-wave`, de modo que el orden se **declara** en vez de
asumirse:

```
wave -1   Postgres
wave  0   migración   ← Argo espera a que termine bien
wave  1   la API
```

Y la garantía que se buscaba se mantiene: si la migración falla, la sincronización se detiene
y la versión nueva no llega a desplegarse.

### Intento 2 — la wave 0 no es "primero", es "en medio"

```
Error: secret "linkshort-db-4t79765hmb" not found
```

Al dar wave `-1` a Postgres, el Secret y el ConfigMap —que no tenían anotación, o sea wave
`0`— pasaron a crearse **después**. Postgres arrancaba sin sus variables de entorno.

**Asignar una wave a unos recursos reordena implícitamente todos los demás.** Es el efecto
secundario que no aparece en los tutoriales: la wave por defecto no es "lo primero", es un
punto intermedio, y todo lo que no anotes se queda ahí.

Como los genera kustomize, se anotan en bloque:

```yaml
generatorOptions:
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

### Intento 3 — la operación colgada sigue en la revisión vieja

Con el arreglo ya en el repositorio, seguía fallando igual. El motivo:

```bash
kubectl -n argocd get application linkshort -o jsonpath='{.status.operationState.operation.sync.revision}'
# 0d24ea14        <- la revisión ANTERIOR
git rev-parse --short HEAD
# eacda38         <- la del arreglo
```

Una sincronización atascada **no recoge los commits nuevos**: sigue intentando la revisión con
la que empezó, y un `refresh` no la cancela. Hay que terminar la operación (o recrear la
`Application`).

Lección de depuración: cuando un arreglo "no hace efecto", lo primero es comprobar **qué
revisión está aplicando realmente el agente**, no volver a leer el YAML.

### Intento 4 — el namespace zombi

Al limpiar para empezar de cero, el namespace se quedó en `Terminating`:

```
NamespaceFinalizersRemaining: Some content in the namespace has finalizers
remaining: argocd.argoproj.io/hook-finalizer in 1 resource instances
```

Los Jobs de hook llevan un finalizer de Argo CD. Al haber borrado la `Application` con
`--cascade=orphan`, quedó un Job huérfano con un finalizer que **ya no tenía quién lo
quitara**, y eso bloquea el borrado del namespace indefinidamente.

```bash
kubectl -n linkshort patch job linkshort-migrate --type merge -p '{"metadata":{"finalizers":null}}'
```

De ahí que la `Application` lleve ahora su propio finalizer de cascada: sin él, borrarla deja
huérfano todo lo que creó.

### El resultado

```
NAME                         READY   STATUS      RESTARTS   AGE
postgres-5494f49f8d-f4l5v    1/1     Running     0          32s
linkshort-migrate-2md4n      0/1     Completed   0          20s
linkshort-7bd48f9f56-2mk9p   1/1     Running     0          15s
```

Las edades cuentan la historia: Postgres primero, migración después, API al final.

Y de paso queda saldada la deuda del `field is immutable` de la Fase 4:
`hook-delete-policy: BeforeHookCreation` borra el Job anterior antes de crear el nuevo, en
cada sincronización.

---

## 5. Lo que NO se automatizó, y por qué

El ciclo ideal sería: haces push → el CI publica `sha-abc1234` → algo actualiza el tag en el
repositorio → Argo CD lo despliega. Falta ese tercer paso, y la razón es concreta:

**Un PR creado con `GITHUB_TOKEN` no dispara workflows.** Es una protección de GitHub contra
la recursión infinita de un CI que se dispara a sí mismo. Como `main` exige que `calidad` e
`imagen` pasen, ese PR se quedaría bloqueado para siempre sin poder mergearse.

Las salidas son tres, y ninguna sale gratis:

1. **Un PAT de larga vida** en los secretos del repo. Es exactamente la credencial que se
   evitó en la Fase 3, con más permisos de los necesarios y sin rotación.
2. **Argo CD Image Updater** con write-back al repositorio: mismo problema de credenciales.
   En su modo `argocd` no escribe en el repo, pero entonces el cluster tiene una versión que
   el repositorio no refleja — deja de ser GitOps.
3. **Dejarlo manual**, que es lo que se ha hecho:

   ```powershell
   cd k8s/overlays/dev
   kubectl kustomize edit set image ghcr.io/danzstorm/devops-project=*:sha-abc1234
   # commit, PR, merge -> Argo CD despliega solo
   ```

Y conviene decir que la opción 3 no es solo el mal menor: muchas organizaciones **quieren** que
el cambio de versión en producción sea un commit revisado por una persona. Lo que sí está
automatizado es lo que viene después del merge, que es la parte donde se rompen las cosas.

---

## 6. Acceso a la interfaz

```powershell
kubectl -n argocd port-forward svc/argocd-server 8080:80
# usuario: admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Argo CD se instala con `server.insecure=true`: sirve HTTP en vez de HTTPS con certificado
autofirmado. Se accede por un túnel local que nunca sale de la máquina, así que el TLS solo
añadiría un aviso de certificado inválido. **En un cluster real no se pone**: allí el servidor
está detrás de un Ingress con certificado de verdad y el tráfico cruza una red.

Esa contraseña inicial debería rotarse y el Secret borrarse en cuanto haya usuarios reales.

---

## 7. Verificación

```powershell
terraform -chdir=terraform apply                    # instala Argo CD
kubectl apply -f k8s/argocd/application.yaml        # arranca el bucle, una sola vez
kubectl -n argocd get application linkshort         # Synced / Healthy
curl.exe http://localhost:8000/ready
```

El self-heal:

```powershell
kubectl -n linkshort delete deploy linkshort
kubectl -n linkshort get deploy linkshort           # vuelve solo en ~10s
```

El orden de las waves:

```powershell
kubectl -n linkshort get pods                       # postgres > migrate > api, por edad
```

---

## 8. Deuda consciente

- **El bump de tag es manual.** Ver §5. Se automatiza el día que exista un PAT gestionado o
  se acepte Image Updater.
- **Una sola `Application`.** Con más servicios, el patrón es *app-of-apps* o un
  `ApplicationSet`: una Application que genera las demás. Con una, sería una abstracción con
  una sola implementación.
- **Sigue sin haber `overlays/prod`.** Argo CD despliega en el mismo cluster donde vive. El
  entorno de producción llega cuando haya un cluster que no sea el portátil.
- **Sin notificaciones.** Un sync fallido solo se ve entrando en la interfaz. `argocd-notifications`
  a Slack es la pieza que falta para enterarse sin mirar.
- **Sin RBAC de Argo CD.** El usuario `admin` puede todo. Con un equipo, hacen falta proyectos
  y roles: Fase 8.

---

## 9. Lo que viene

**Fase 7 — Observabilidad.** La aplicación expone `/metrics` desde la Fase 1 y nadie las lee.
Prometheus para recogerlas, Grafana para verlas, y las preguntas que de verdad importan: no
"¿está el pod arriba?" —eso ya lo sabemos— sino cuánta latencia tiene el p99, cuántos 5xx hay
por minuto, y si el despliegue de hace diez minutos empeoró algo.
