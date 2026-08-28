# Fase 5 — Infraestructura como código

> **Estado:** completada
> **Archivos:** `terraform/main.tf`, `terraform/variables.tf`, `terraform/outputs.tf`

---

## 1. IaC no es "un script que crea cosas"

Es fácil confundir Terraform con un instalador. La diferencia está en que un script
**ejecuta pasos** y Terraform **mantiene un estado**.

Un script que crea un cluster sabe crearlo. No sabe si ya existe, si alguien le cambió algo a
mano, ni qué habría que borrar para deshacerlo. Terraform sí, porque guarda un registro de lo
que ha creado y lo compara con lo que pides:

```
código (lo que quieres) ←→ estado (lo que creaste) ←→ realidad (lo que hay)
```

De esa comparación salen las tres cosas que un script no puede darte: un **`plan`** que
enseña qué va a cambiar antes de cambiarlo, **idempotencia** (aplicar dos veces no duplica
nada) y **detección de deriva** (si alguien toca la infra a mano, se nota).

---

## 2. La frontera: qué gestiona Terraform y qué no

La decisión más importante de esta fase no es qué se escribe, sino **qué se deja fuera**.

| | Terraform | kustomize |
|---|---|---|
| Qué | cluster, complementos, y mañana red, registro, base gestionada | la aplicación |
| Cada cuánto cambia | rara vez | varias veces al día |
| Cuánto tarda | minutos | segundos |

El provider `kubernetes` de Terraform permitiría desplegar la app desde aquí. Sería un error:

- Cada despliegue pasaría por un `terraform apply`, que **bloquea el estado**. Dos despliegues
  simultáneos se hacen cola.
- Un rollback dependería de revertir código de infraestructura, en vez de cambiar un tag.
- Y lo peor: mezclaría en un mismo estado lo que tarda veinte minutos en crearse con lo que
  cambia veinte veces al día. Cualquier problema con lo segundo pone en riesgo lo primero.

Regla práctica: **si tiene ciclo de vida propio y sobrevive a los despliegues, es Terraform.
Si se despliega, no.**

---

## 3. El estado, y por qué nunca entra en git

`terraform.tfstate` está en `.gitignore` desde la Fase 0. Las razones son dos, y la primera
es seria:

1. **El estado guarda en claro todo lo que Terraform gestiona**, incluidas contraseñas,
   claves y certificados. Si Terraform creara una base de datos con contraseña, esa
   contraseña estaría en el estado en texto plano. Commitearlo sería la peor filtración
   posible del repositorio.
2. **Sin bloqueo, dos `apply` a la vez lo corrompen.** Git no sabe fusionar un `.tfstate`.

Aquí el backend es local, y se documenta como decisión: para una persona y un cluster
desechable, basta. En cuanto haya dos personas o infraestructura real, esto pasa a un backend
remoto (S3 + DynamoDB, GCS, Terraform Cloud) que aporta cifrado en reposo, versionado y
bloqueo. No se monta ahora porque **todavía no hay nada que proteger**, y montar un backend
remoto para un cluster de juguete es ceremonia.

Lo que **sí** se commitea es `.terraform.lock.hcl`, con los hashes exactos de los providers.
Es el mismo razonamiento que `uv.lock` y que las versiones fijas del `Dockerfile`: sin él,
dos personas pueden resolver versiones distintas de un provider y obtener infraestructuras
diferentes desde el mismo código.

---

## 4. El bucle: `plan` antes de `apply`

```bash
terraform -chdir=terraform init     # descarga providers, escribe el lock
terraform -chdir=terraform plan     # ¿qué va a pasar?
terraform -chdir=terraform apply    # que pase
```

```
Plan: 2 to add, 0 to change, 0 to destroy.
```

Esa línea es el hábito que hay que coger. Leerla antes de aplicar es lo que separa "cambié
una variable" de "destruí la base de datos de producción": un `plan` que dice `1 to destroy`
cuando esperabas `1 to change` es un aviso, y en Terraform los recursos que no se pueden
modificar en sitio **se recrean**, es decir, se borran primero.

En un equipo, ese `plan` va comentado en el PR y se revisa como se revisa el código. Es la
Fase 3 aplicada a la infraestructura.

### Idempotencia

```
$ terraform plan
No changes. Your infrastructure matches the configuration.
```

Aplicar dos veces no crea dos clusters. Parece obvio y es justo lo que un script no te da
gratis.

---

## 5. Deriva: el experimento

Este es el concepto que hace que IaC valga la pena. Alguien "arregla algo rápido" a mano:

```bash
helm uninstall metrics-server -n kube-system
# release "metrics-server" uninstalled
```

Sin tocar una línea de código:

```bash
terraform plan
#   # helm_release.metrics_server will be created
#   Plan: 1 to add, 0 to change, 0 to destroy.
```

Terraform compara su estado con la realidad y **detecta que alguien tocó la infraestructura
por fuera**. Un `apply` la devuelve a lo declarado:

```
helm_release.metrics_server: Creation complete after 23s
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

Sin esto, los cambios manuales se acumulan en silencio hasta que el entorno real no se parece
a nada de lo escrito, y recrearlo desde cero se vuelve imposible. Es el mismo mecanismo que
Argo CD aplicará a la aplicación en la Fase 6: comparar lo declarado con lo que hay, y
corregir la diferencia.

---

## 6. Versiones fijas en las cuatro capas

Ya es un patrón del proyecto, y aquí se cierra:

| Capa | Dónde |
|---|---|
| Dependencias de Python | `uv.lock` |
| Imágenes base | `python:3.12-slim`, `postgres:17-alpine` |
| Actions del CI | `@v7`, `@v10.0.1` |
| Providers de Terraform | `~> 0.11.0` + `.terraform.lock.hcl` |
| Chart de Helm | `version = "3.14.0"` |
| Imagen del nodo | con **digest**, no solo tag |

El digest merece una nota: `kindest/node` republica sus tags, así que dos `apply` con el
mismo tag pueden dar clusters con versiones distintas de Kubernetes. Un digest apunta a un
contenido concreto y no se puede reescribir.

### El tropiezo: la versión que manda no es la que tienes instalada

El primer `apply` falló así:

```
Error: failed to init node with kubeadm: command "docker exec --privileged
linkshort-control-plane kubeadm init --config=/kind/kubeadm.conf ..." failed
with error: exit status 1
```

Un error que no menciona versiones por ningún lado. Y lo confuso: el mismo cluster, con la
misma imagen, **funcionaba con `kind create cluster` desde la terminal**.

La causa estaba en el `go.mod` del provider:

```bash
gh api repos/tehcyx/terraform-provider-kind/contents/go.mod?ref=v0.11.0 \
  --jq .content | base64 -d | grep kind
#   sigs.k8s.io/kind v0.31.0
```

El provider **embebe la librería de kind v0.31.0**. El CLI instalado era v0.33.0. La imagen
de nodo `v1.37.0` viene con kind 0.33, y kind 0.31 no sabe generarle un `kubeadm.conf`
válido. Solución: usar una imagen de las que publicó la release v0.31.0 (`v1.34.3`).

La lección generaliza más allá de kind: **cuando una herramienta se usa a través de un
envoltorio, la versión que manda es la del envoltorio**, no la que tú tengas en el PATH. Y el
sitio donde comprobarlo es el manifiesto de dependencias del envoltorio.

---

## 7. Una excepción de seguridad, dicha en voz alta

```hcl
set = [{
  name  = "args[0]"
  value = "--kubelet-insecure-tls"
}]
```

kind genera los certificados del kubelet con nombres que no coinciden con la IP por la que
metrics-server lo consulta, así que la verificación TLS falla y el pod no llega a servir
métricas.

Esto **desactiva la verificación del certificado del kubelet**. Es aceptable en un cluster de
laboratorio que vive en tu portátil y se borra al terminar. En un cluster real no se pone:
allí los certificados son correctos, y esta bandera sería abrir una puerta por comodidad.

Se escribe aquí, con su motivo, precisamente para que no viaje a un `values.yaml` de
producción por copiar y pegar.

---

## 8. Outputs: el contrato hacia fuera

```
app_url         = "http://localhost:8000"
kubectl_context = "kind-linkshort"
siguiente_paso  = "kubectl apply -k k8s/overlays/dev"
```

`kubectl_context` no es decorativo: es la defensa contra el error clásico de aplicar
manifiestos en el cluster equivocado.

Y una ausencia deliberada: **el kubeconfig no se expone como output**, aunque el provider lo
ofrezca. Contiene la clave privada del cliente, y un output se escribe en el estado, se
imprime en pantalla y aparece en los logs de cualquier CI que ejecute `terraform output`.
Marcarlo `sensitive = true` lo oculta de la consola pero **no lo cifra en el estado**, así
que no arregla el problema de fondo. kind ya escribe el kubeconfig en `~/.kube/config`.

### El susto: el provider escribió un secreto en el repositorio

No basta con no exponerlo como output. Tras el primer `apply`, `git status` mostraba un
archivo nuevo:

```
terraform/linkshort-config
```

Es el kubeconfig del cluster, que el provider escribe por su cuenta en el directorio de
trabajo. Y contiene `client-key-data`: **la clave privada del cliente**, en claro. Iba camino
del commit sin que nada lo señalara.

```gitignore
terraform/*-config
```

Lo importante no es la línea, es el hábito que la produjo: **mirar `git status` antes de
`git add -A`**, y preguntarse qué es cada archivo que uno no escribió. Las herramientas
generan secretos como efecto secundario —kubeconfigs, tokens de service account, claves de
cuenta— y los dejan en el directorio de trabajo sin avisar. Esa es la vía por la que se
filtran las credenciales: no por descuido al escribirlas, sino por no mirar lo que apareció
solo.

Comprobado que nunca llegó a ningún commit:

```bash
git log --all --diff-filter=A --name-only --format="" | sort -u | grep -E "linkshort-config"
```

---

## 9. Una sola forma de crear el cluster

`k8s/kind-cluster.yaml` se ha **borrado**. Hacía lo mismo que `terraform/main.tf`, y dos
formas de crear la misma cosa son deriva garantizada: se arregla una, se olvida la otra, y
seis meses después nadie sabe cuál es la buena.

Borrar código es parte del trabajo. Cuando una fase absorbe lo que hacía la anterior, lo
anterior se va.

---

## 10. Verificación

```powershell
terraform -chdir=terraform init
terraform -chdir=terraform plan      # Plan: 2 to add
terraform -chdir=terraform apply
kubectl config current-context       # kind-linkshort
```

Que los complementos sirven de verdad:

```powershell
kubectl top nodes
# linkshort-control-plane   155m   0%   931Mi   5%
kubectl -n linkshort top pods
# linkshort-7bd48f9f56-f6jbs   3m   60Mi
```

De paso, esas cifras validan el dimensionado de la Fase 4: 60 Mi reales contra un `request`
de 128 Mi y un `limit` de 256 Mi.

La deriva:

```powershell
helm uninstall metrics-server -n kube-system
terraform -chdir=terraform plan      # Plan: 1 to add
terraform -chdir=terraform apply     # corregido
```

Y para llevárselo todo:

```powershell
terraform -chdir=terraform destroy
```

---

## 11. Deuda consciente

- **Backend local.** Sin cifrado, sin versionado, sin bloqueo. Se cambia cuando haya una
  segunda persona o infraestructura que no sea desechable, no antes.
- **No hay módulos.** Con un solo entorno, extraer módulos sería crear una abstracción con
  una sola implementación. Cuando existan `dev` y `prod` de verdad, el patrón (módulo +
  `terraform workspace` o directorios por entorno) tendrá algo que compartir.
- **No hay `terraform plan` en el CI.** Se valida sintaxis y formato, que es lo que se puede
  hacer sin credenciales ni estado remoto. Un `plan` automático en cada PR necesita ambas
  cosas: llega cuando llegue el backend remoto.
- **`tehcyx/kind` es un provider de comunidad**, no oficial. Es lo que hay para kind, y el
  riesgo se acota fijando la versión. En cuanto el destino sea un cloud real, los providers
  pasan a ser los oficiales.
- **Nada de esto cuesta dinero todavía.** El día que Terraform cree recursos de pago, hace
  falta `terraform plan` revisado en PR y alguna herramienta de estimación de coste. Es fácil
  destruir y recrear por accidente algo que factura.

---

## 12. Lo que viene

**Fase 6 — CD con GitOps (Argo CD).** La plataforma se declara y se reconcilia sola; la
aplicación todavía se despliega a mano con `kubectl apply`. Argo CD lleva a la aplicación el
mismo bucle que Terraform aplica a la infraestructura: observar el repositorio, compararlo
con el cluster y corregir la diferencia. Ahí es donde el tag `sha-xxxxxxx` que publica el CI
deja de actualizarse a mano, y donde el Job de migración pasa a ser un hook `PreSync` — la
deuda que la Fase 4 dejó anotada.
