# Fase 4 — Kubernetes local con kind

> **Estado:** completada
> **Archivos:** `k8s/kind-cluster.yaml`, `k8s/base/`, `k8s/overlays/dev/`

---

## 1. Qué añade Kubernetes que Compose no tenía

Compose ya levantaba los tres contenedores en el orden correcto. La diferencia no es *qué*
se ejecuta, es **quién decide** que siga ejecutándose.

Compose arranca lo que le pides y se aparta. Kubernetes recibe una **declaración del estado
deseado** —"quiero 2 réplicas de esta imagen, sanas"— y a partir de ahí trabaja
permanentemente para que la realidad coincida: si un pod muere lo recrea, si un nodo cae
mueve la carga, si un pod deja de estar listo lo saca del balanceador. Nadie le vuelve a
pedir nada.

Ese cambio de "ejecutar comandos" a "declarar un estado" es lo que hace posible la Fase 6:
si el estado deseado está escrito en el repositorio, un agente puede compararlo con el
cluster y corregir la diferencia solo.

Y es donde `/health` y `/ready` dejan de ser dos endpoints parecidos.

---

## 2. El cluster también es código

```bash
kind create cluster --config k8s/kind-cluster.yaml
```

`kind create cluster` a secas funciona, pero entonces la topología vive en la memoria de
quien lo tecleó. La regla de la Fase 0 —*"si no está en el repo, no existe"*— aplica también
al cluster.

El único detalle no obvio del archivo:

```yaml
extraPortMappings:
  - containerPort: 30080
    hostPort: 8000
```

kind ejecuta los nodos como contenedores de Docker, así que un NodePort no es alcanzable
desde el host a menos que se mapee. Es el `ports:` de Compose, con una diferencia importante:
**hay que declararlo al crear el cluster**. Añadirlo después obliga a recrearlo.

Un solo nodo a propósito. Añadir workers en local no enseña nada que un nodo no enseñe ya y
multiplica la RAM. Anti-afinidad, `drain` y topology spread llegan cuando haya un cluster
donde signifiquen algo.

---

## 3. Las sondas, por fin con consecuencias

Esta es la fase donde se cobra la decisión de la Fase 1. Recordando el diseño: `/health` no
toca la base de datos, `/ready` sí.

```yaml
livenessProbe:      # fallar aquí REINICIA el contenedor
  httpGet: { path: /health, port: http }
  periodSeconds: 10

readinessProbe:     # fallar aquí solo lo SACA del Service
  httpGet: { path: /ready, port: http }
  periodSeconds: 5
```

`periodSeconds` más corto en readiness es intencional: quitarle tráfico a un pod que no puede
servirlo es urgente; matarlo, no.

### El experimento

Se apaga Postgres y se mira qué hace cada sonda:

```bash
kubectl -n linkshort scale deploy/postgres --replicas=0
kubectl -n linkshort get pods -l app.kubernetes.io/name=linkshort
```

```
NAME                         READY   STATUS    RESTARTS   AGE
linkshort-645c979876-krkms   0/1     Running   0          98s
linkshort-645c979876-pptw4   0/1     Running   0          98s
```

Lo que hay que mirar es la columna **`RESTARTS`: cero**. Y a la vez, desde dentro del pod:

```
/health  200  {"status":"ok"}
/ready   503  {"status":"database unavailable"}
```

El Service dejó de enrutarles tráfico —sus endpoints pasaron a `ready: false`— pero **nadie
los mató**. Al devolver Postgres:

```bash
kubectl -n linkshort scale deploy/postgres --replicas=1
```

```
linkshort-645c979876-krkms   1/1     Running   0          2m15s
```

Vuelven solos. Sin reinicios, sin intervención, sin haber perdido nada.

Si `livenessProbe` apuntara a `/ready`, esos dos pods habrían entrado en CrashLoopBackOff:
cada reinicio vacía su estado, el arranque añade carga sobre una base que ya está sufriendo,
y una degradación temporal se convierte en una caída total con el reloj en contra. Esa es la
diferencia entre las dos sondas, y por eso se escribió así en la Fase 1 aunque entonces no se
notara.

---

## 4. `securityContext`: la deuda de la Fase 2, saldada

La Fase 2 dejó tres cosas pendientes "para cuando haya dónde declararlas". Aquí están:

```yaml
securityContext:            # a nivel de pod
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  seccompProfile: { type: RuntimeDefault }
```

```yaml
securityContext:            # a nivel de contenedor
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
```

El matiz que importa: el `Dockerfile` ya **creaba** el usuario 10001, pero eso era una
promesa de la imagen. Esto es lo que el cluster puede **verificar y exigir**. Con
`runAsNonRoot: true`, el kubelet se niega a arrancar el pod si la imagen intenta correr como
root — y por eso el `Dockerfile` usaba un UID numérico y no un nombre: el kubelet no puede
resolver nombres de usuario dentro de la imagen antes de arrancarla.

Comprobado en el pod:

```bash
kubectl -n linkshort exec <pod> -- id
# uid=10001(app) gid=10001(app)
kubectl -n linkshort exec <pod> -- touch /usr/local/x
# touch: cannot touch '/usr/local/x': Read-only file system
```

### El detalle que rompe `readOnlyRootFilesystem`

Un sistema de ficheros de solo lectura significa **ningún** sitio escribible, y hay
librerías que dan por hecho que `/tmp` existe y acepta escrituras. Cuesta cuatro líneas
evitarlo:

```yaml
volumeMounts: [{ name: tmp, mountPath: /tmp }]
volumes:      [{ name: tmp, emptyDir: {} }]
```

Un `emptyDir` vive y muere con el pod, que es exactamente lo que se quiere para temporales.

---

## 5. `resources`: por qué hay límite de memoria y no de CPU

```yaml
requests: { cpu: 50m, memory: 128Mi }
limits:   { memory: 256Mi }
```

**`requests`** es lo que el scheduler reserva; es lo que decide en qué nodo cabe el pod. Sin
ellas asume 0 y sobrecarga nodos alegremente.

**`limits` solo de memoria.** La memoria es incompresible: o la tienes o no. Superar el
límite mata el contenedor (OOMKill), que es la respuesta correcta ante una fuga.

La CPU es distinta: es *comprimible*. Un límite de CPU no evita nada — hace que el kernel
estrangule el proceso (*throttling*) aunque el nodo esté ocioso. El resultado típico es una
latencia p99 horrible sin ninguna alerta que la explique, porque no hay errores, ni
reinicios, ni nada roto: solo lentitud. Las `requests` ya garantizan el reparto justo bajo
contención.

---

## 6. `kustomize`: base y overlays

```
k8s/base/            la forma de la aplicación, sin decisiones de entorno
k8s/overlays/dev/    lo que solo tiene sentido en local
```

`base` no lleva el tag de la imagen, ni réplicas de producción, ni la contraseña de nadie. La
prueba de que la separación está bien hecha: **`kubectl apply -k k8s/base` no debería usarse
nunca** — base no describe ningún entorno, describe el patrón.

No hay `overlays/prod` todavía, y es a propósito. Un overlay que no se puede aplicar contra
ningún sitio no es infraestructura, es un borrador. Se creará en la Fase 6, cuando haya un
destino real y un Argo CD que lo consuma.

### Por qué `configMapGenerator` y no un ConfigMap suelto

```yaml
configMapGenerator:
  - name: linkshort-config
    literals: [LOG_LEVEL=INFO, ...]
```

kustomize le añade un sufijo con el hash del contenido (`linkshort-config-2cbbfcmgbb`) y
actualiza las referencias. Cambiar un valor cambia el nombre; cambiar el nombre modifica el
pod template; y eso **dispara un rolling update**.

Con un ConfigMap normal no ocurre nada de eso: editas el valor, `kubectl` lo aplica, y los
pods siguen corriendo con la configuración vieja hasta que alguien los reinicia a mano. Es de
los fallos más desconcertantes de Kubernetes, porque `kubectl get configmap` muestra el valor
nuevo y todo *parece* correcto.

Lo mismo aplica al `secretGenerator`.

### Los parches son quirúrgicos

`service-nodeport.yaml` no copia el Service entero: declara el nombre y los campos que
cambian. Si mañana base cambia las labels, el parche sigue siendo válido porque no habla de
ellas.

---

## 7. Los secretos, y por qué el de dev está en git a la vista

`devpassword` está en `overlays/dev/kustomization.yaml`, en claro. Es una decisión, no un
descuido, y conviene entender por qué la alternativa "correcta" habría sido peor:

**Un Secret de Kubernetes no está cifrado.** Es base64, que es codificación, no criptografía:

```bash
kubectl -n linkshort get secret linkshort-db-xxx -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
```

lo lee cualquiera con permisos de lectura sobre el namespace. Frente a un ConfigMap solo
aporta que no aparece por accidente en un `describe` y que RBAC lo trata aparte.

Así que commitear un `secret.yaml` escrito a mano sería **un secreto en git con un paso extra
de ofuscación**, cuyo único efecto real es dormir mejor sin motivo. Mejor un valor de
desarrollo evidente, que canta si aparece donde no debe — igual que en `docker-compose.yml`.

Los secretos de verdad llegan en la Fase 8 (Sealed Secrets o External Secrets): lo que se
commitea es un cifrado que **solo el cluster** puede abrir.

### Un aviso sobre cambiar esa contraseña

Cambiar `POSTGRES_PASSWORD` regenera el Secret y reinicia los pods, pero **no cambia la
contraseña de una base ya inicializada**: la imagen de Postgres solo la usa la primera vez,
cuando crea el directorio de datos. Si el PVC ya existe, la app quedará con la contraseña
nueva y la base con la vieja. Hace falta `kubectl delete pvc postgres-data` (que borra los
datos) o cambiarla por SQL.

---

## 8. Postgres como Deployment, no como StatefulSet

Con **una sola réplica**, un StatefulSet solo añadiría identidad de red estable y arranque
ordenado, que aquí no hacen falta. La complejidad se paga cuando compra algo.

Lo que sí hace falta:

```yaml
strategy:
  type: Recreate
```

El PVC es `ReadWriteOnce`: solo un pod puede montarlo. Con `RollingUpdate`, el pod nuevo
esperaría para siempre un volumen que el viejo no suelta, y el despliegue se queda colgado
sin un error que lo explique.

Y una decisión de seguridad que va en dirección contraria al resto: el pod de Postgres **no**
lleva `runAsNonRoot`. La imagen oficial arranca como root para crear y dar permisos al
directorio de datos, y luego baja al usuario `postgres` ella sola. Se acepta porque esto no
llega a producción. Si llegara, la respuesta correcta no sería pelearse con el
`securityContext`: sería no operar la base de datos uno mismo.

---

## 9. Kubernetes no tiene `depends_on`

Compose tenía `condition: service_healthy` y `service_completed_successfully`. Kubernetes no
tiene nada equivalente: todo se crea a la vez y cada cosa se las apaña.

Aquí se resuelve sin añadir una sola línea de espera, en dos sitios:

**El Job de migración** usa `restartPolicy: OnFailure` con `backoffLimit`. Si Postgres aún no
acepta conexiones, Alembic falla, y Kubernetes lo reintenta con backoff exponencial hasta que
entra. Se vio en directo — el pod del Job acumuló 2 reinicios antes de completar:

```
INFO  [alembic.runtime.migration] Context impl PostgresqlImpl.
INFO  [alembic.runtime.migration] Running upgrade  -> 278ef5198bc9, crear tabla links
```

Un initContainer con un bucle de `pg_isready` haría lo mismo con más YAML.

**La API** no necesita esperar a nada: arranca, su `readinessProbe` falla mientras la base no
esté, y el Service no le manda tráfico hasta que lo esté. El diseño de la Fase 1 ya resolvía
este problema antes de que existiera.

### La grieta honesta de ese razonamiento

`/ready` comprueba **conectividad**, no **esquema**: hace `SELECT 1`. En la ventana entre
"Postgres acepta conexiones" y "el Job terminó de migrar", un pod se declara listo y una
petición a `/links` fallaría con un 500.

Es una ventana de segundos en el primer despliegue y no se ha cerrado a propósito: hacer que
`/ready` verifique la revisión de Alembic lo acopla al esquema y convierte cada migración en
una caída de readiness de toda la flota. El arreglo de verdad —migraciones compatibles hacia
atrás, desplegadas antes que el código que las usa— es una disciplina, no un endpoint.

---

## 10. Verificación

```powershell
kind create cluster --config k8s/kind-cluster.yaml
kubectl apply -k k8s/overlays/dev
kubectl -n linkshort rollout status deploy/linkshort
kubectl -n linkshort wait --for=condition=complete job/linkshort-migrate --timeout=120s
```

La app, atravesando el NodePort desde el host:

```powershell
curl.exe http://localhost:8000/ready
# {"status":"ok"}
curl.exe -X POST http://localhost:8000/links -H "Content-Type: application/json" -d '{\"url\":\"https://kubernetes.io/docs/\"}'
curl.exe -i http://localhost:8000/<slug>     # 307
```

El experimento de las sondas:

```powershell
kubectl -n linkshort scale deploy/postgres --replicas=0
kubectl -n linkshort get pods -l app.kubernetes.io/name=linkshort   # 0/1 Running, RESTARTS 0
kubectl -n linkshort scale deploy/postgres --replicas=1             # vuelven solos
```

El `securityContext`:

```powershell
kubectl -n linkshort exec deploy/linkshort -- id                 # uid=10001(app)
kubectl -n linkshort exec deploy/linkshort -- touch /usr/local/x # Read-only file system
```

Limpiar del todo:

```powershell
kind delete cluster --name linkshort
```

---

## 11. Deuda consciente

- **El Job de migración tiene nombre fijo y `spec.template` es inmutable.** Al desplegar una
  imagen nueva, `kubectl apply` falla con `field is immutable` y hay que borrarlo antes:

  ```powershell
  kubectl -n linkshort delete job linkshort-migrate --ignore-not-found
  kubectl apply -k k8s/overlays/dev
  ```

  No se ha inventado un generador de nombres porque en la Fase 6 el problema desaparece: Argo
  CD ejecuta las migraciones como hook `PreSync`, que crea un Job nuevo por sincronización.
  Construir ahora a mano lo que la herramienta de la fase siguiente ya trae sería trabajo que
  se tira.

- **No hay Ingress.** Un NodePort mapeado por kind basta para un cluster local de un nodo.
  El Ingress entra cuando haya TLS y varios servicios que enrutar.

- **No hay `NetworkPolicy`.** Hoy cualquier pod del cluster puede hablar con Postgres. Fase 8.

- **No hay `PodDisruptionBudget` ni anti-afinidad.** Con un solo nodo no protegen de nada:
  ese nodo es el único dominio de fallo que existe.

- **No hay `startupProbe`.** La app arranca en un segundo. Haría falta si el arranque fuera
  lento e impredecible, para que la liveness no lo mate a mitad.

- **`/ready` no comprueba el esquema**, solo la conectividad. Ver §9.

---

## 12. Lo que viene

**Fase 5 — Infraestructura como código con Terraform.** El cluster de kind se crea con un
comando, pero un cluster de verdad tiene red, IAM, registro, base de datos gestionada y
reglas de acceso. Eso no se teclea: se declara, se planifica (`plan`) y se aplica, con un
estado versionado y revisable en un PR — el mismo trato que ya recibe el código.
