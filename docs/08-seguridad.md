# Fase 8 — Seguridad

> **Estado:** completada
> **Archivos:** `k8s/base/networkpolicy.yaml`, `terraform/main.tf`, `.github/workflows/ci.yml`, `Dockerfile`, `pyproject.toml`

---

## 1. La fase donde se pagan las deudas

Casi todas las fases anteriores dejaron algo anotado "para la Fase 8". Esto no fue pereza:
cada pieza de seguridad necesita el contexto donde significa algo. Un `securityContext` sin
cluster es teoría; una `NetworkPolicy` sin servicios que se hablen no protege de nada.

| Deuda | De la fase | Estado |
|---|---|---|
| Reglas `S` de ruff | 1 | ✅ |
| Quitar `pip` de la imagen | 2 | ✅ |
| `gitleaks` en el CI | 0 y 3 | ✅ |
| SBOM y firma de imágenes | 3 | ✅ |
| `NetworkPolicy` | 4 | ✅ |
| Secretos de verdad | 4 y 6 | ⏳ ver §7 |

---

## 2. El hallazgo: seguridad que parece puesta y no lo está

Antes de escribir las `NetworkPolicy`, una comprobación que resultó ser la más valiosa de la
fase. Se aplicó una política de "denegar toda entrada" a Postgres:

```yaml
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: postgres }
  policyTypes: [Ingress]
  ingress: []          # nadie puede entrar
```

```
networkpolicy.networking.k8s.io/prueba-denegar-todo created
/ready responde: 200
```

La aplicación seguía hablando con la base de datos tan tranquila.

**`kindnet`, el CNI que trae kind de serie, no implementa NetworkPolicy.** Y no falla: acepta
el recurso, lo guarda, `kubectl get networkpolicy` lo lista, `kubectl describe` muestra las
reglas… y no filtra absolutamente nada.

Esto es peor que no tener seguridad, porque es indistinguible de tenerla. Un panel verde y un
recurso en el cluster dicen que la base de datos está aislada. No lo está.

La lección generaliza más allá de kind: **un control de seguridad que no se ha comprobado en
funcionamiento no es un control, es una intención**. La forma de comprobarlo es siempre la
misma —intentar hacer lo que debería estar prohibido— y casi nunca se hace, porque el recurso
"ya está creado".

### El arreglo, y tres intentos fallidos por el camino

Fuera kindnet, dentro un CNI que sí aplique políticas:

```hcl
kind_config {
  networking {
    disable_default_cni = true    # fuera kindnet
  }
}
```

Con una consecuencia que el `plan` avisó por adelantado:

```
Plan: 5 to add, 0 to change, 1 to destroy.
  # kind_cluster.linkshort must be replaced
```

El CNI no se cambia en caliente: hay que recrear el cluster. Es exactamente el caso de "leer
el plan antes de aplicar" de la Fase 5, y el momento donde GitOps demuestra que vale: se
destruyó el cluster entero y **Argo CD volvió a desplegar la aplicación solo**, sin que nadie
recordara qué había.

La primera elección fue Calico, y falló tres veces seguidas:

```
unable to build kubernetes objects from release manifest:
no matches for kind "APIServer" in version "operator.tigera.io/v1"
```

Su chart (`tigera-operator`) declara recursos `operator.tigera.io/v1` cuyos CRDs **instala el
propio chart**, y Helm no espera a que queden registrados antes de aplicar los recursos que
los usan. Es el problema clásico de un chart que mezcla CRDs con sus consumidores; se arregla
instalando en dos pasos, pero eso significa dos `helm_release` y un `depends_on` extra para
algo que no es el objetivo de la fase.

**Cilium** no tiene ese problema y se instaló en 24 segundos. La decisión aquí no es "Cilium
es mejor que Calico": es que cuando una herramienta pelea por razones ajenas al problema que
resuelves, la salida barata suele ser cambiar de herramienta, no domarla.

Y como el CNI tiene que existir antes que cualquier otro pod —sin él nadie obtiene IP—, es uno
de los pocos sitios donde `depends_on` es imprescindible: la dependencia no se deduce de
ninguna referencia.

---

## 3. Las políticas: denegar por defecto

```yaml
podSelector: {}        # todos los pods
policyTypes: [Ingress] # sin reglas ingress = nada entra
```

El modelo funciona al revés de lo que parece: **mientras ningún `NetworkPolicy` seleccione un
pod, todo le está permitido**. En cuanto uno lo selecciona, se deniega todo lo que no esté
explícitamente permitido. Por eso la primera regla es la de denegación: sin ella, las demás
permitirían tráfico que ya estaba permitido y no cambiarían nada.

La regla que importa:

```yaml
# Postgres solo acepta a la API y al Job de migración
ingress:
  - from:
      - podSelector: { matchLabels: { app.kubernetes.io/name: linkshort } }
      - podSelector: { matchLabels: { batch.kubernetes.io/job-name: linkshort-migrate } }
    ports: [{ port: 5432 }]
```

Esa segunda entrada es fácil de olvidar y cara: sin ella la migración no conecta, la wave 0
no termina, y el despliegue se queda bloqueado. Es el tipo de fallo que se descubre en
producción a las tres de la mañana.

### DNS: la excepción que todo el mundo olvida

La regla de salida para el puerto 53 está escrita aunque hoy el `egress` siga abierto. El día
que alguien cierre la salida sin acordarse de DNS, la aplicación no podrá ni resolver el
nombre `postgres`, y el síntoma será un *timeout* que parece un problema de base de datos y
no de red. Se pierde una tarde en el sitio equivocado.

---

## 4. `gitleaks`: la regla de la Fase 0 deja de ser un sistema de honor

```yaml
- uses: actions/checkout@v7
  with:
    fetch-depth: 0        # historial completo
- uses: gitleaks/gitleaks-action@v3
```

`fetch-depth: 0` no es un detalle: **un secreto borrado en el último commit sigue estando en
los anteriores**, y ahí es donde hay que buscarlo. Con el checkout superficial por defecto,
gitleaks miraría un solo commit y no encontraría nada.

Merece recordar el susto de la Fase 5: el provider de Terraform escribió un kubeconfig con la
clave privada del cliente dentro del repositorio, y solo lo pilló mirar `git status` a mano.
Esto es lo que evita depender de eso.

Y el recordatorio que acompaña siempre a este tipo de escaneo: si aparece un secreto real, el
orden correcto es **rotar la credencial primero** y limpiar el historial después. Al revés no
sirve de nada — está comprometida desde el commit que la introdujo.

---

## 5. Firma y SBOM: qué demuestra cada cosa

```yaml
- uses: sigstore/cosign-installer@v4.1.2
- run: cosign sign --yes "$digest"
```

**Firma keyless.** No hay ninguna clave privada que guardar, rotar ni filtrar. `cosign` pide
un certificado efímero a Fulcio presentando el token OIDC que GitHub emite para *este*
workflow, firma, y registra la firma en un log público y append-only (Rekor). El certificado
caduca en minutos.

Por eso el job necesita `id-token: write` — y solo ese job.

Lo que demuestra la firma no es "esta imagen no tiene bugs", sino algo más útil: **esta imagen
la construyó este repositorio, en este workflow, a partir de este commit**. Sin eso,
cualquiera con acceso de escritura al registro puede subir una imagen con el mismo tag y nadie
lo nota.

Se firma **por digest, nunca por tag**. Un tag se puede reapuntar a otra imagen; la firma
dejaría de significar nada.

**SBOM** (CycloneDX) responde a otra pregunta, la que llega el día de una CVE grave: *"¿nos
afecta?"*. Sin inventario, contestarla exige reconstruir imágenes viejas e inspeccionarlas.
Con SBOM es una consulta sobre un archivo.

---

## 6. Menos superficie: reglas `S` y fuera `pip`

```toml
select = ["E", "F", "I", "UP", "B", "S"]

[tool.ruff.lint.per-file-ignores]
"tests/**" = ["S101"]
```

Las reglas `S` (bandit) pasaron **sin un solo cambio en el código**. No es suerte: la decisión
de la Fase 1 de usar `secrets` en vez de `random` para los slugs es justo una de las cosas que
`S` detecta. Decisiones tomadas por el motivo correcto siguen siendo correctas cuando llega la
herramienta que las verifica.

`S101` se ignora en tests porque los tests *usan* `assert`: es su forma de trabajar. La regla
existe porque un `assert` en código de producción **desaparece al ejecutar con `-O`**, y una
validación que se evapora según cómo arranques el proceso es peor que no tenerla.

```dockerfile
RUN rm -rf /usr/local/lib/python3.12/site-packages/pip* ...
```

La aplicación corre desde `/app/.venv`, que `uv` construyó sin `pip`. Los que quedaban venían
de la imagen base. Lo que le aportan a un atacante que consiga ejecución dentro del
contenedor: una forma cómoda de descargar e instalar código arbitrario. Sin ellos hace falta
traerse las herramientas, que es más ruidoso y más difícil.

---

## 7. Lo que NO se hizo, y por qué

**Sealed Secrets no entra en esta fase.** La contraseña de desarrollo sigue en claro en
`overlays/dev`, como desde la Fase 4.

El motivo es de honestidad más que de tiempo: montar el cifrado de secretos aquí protegería
`devpassword`, una contraseña que **está puesta para ser vista** y que no da acceso a nada.
Sería la ceremonia sin el contenido — el equivalente de poner una caja fuerte para guardar una
nota que dice "hola".

Sealed Secrets (o External Secrets contra un gestor real) tiene sentido cuando exista un
entorno con credenciales que valga la pena proteger, es decir cuando exista `overlays/prod`.
Ese es el momento correcto, y llega con la Fase 9.

Lo que sí está resuelto hoy es lo que hacía falta: que **no se cuele un secreto de verdad**
(gitleaks) y que los que hay sean evidentemente falsos.

---

## 8. Verificación

Que Calico está y kindnet no:

```powershell
kubectl get daemonset -A | Select-String -Pattern "cilium|kindnet"
```

Que las políticas **de verdad** bloquean. La prueba necesita las dos mitades, porque un
"no conecta" a secas también lo produce un pod roto:

```powershell
# 1. Sin las labels permitidas -> debe quedarse colgado
kubectl -n linkshort run intruso --restart=Never --image=postgres:17-alpine --command -- `
  sh -c 'timeout 20 psql "postgresql://linkshort:devpassword@postgres:5432/linkshort" -c "select 1"; echo EXIT=$?'

# 2. El MISMO pod, con la label permitida -> debe conectar
kubectl -n linkshort run permitido --restart=Never --image=postgres:17-alpine `
  --labels="app.kubernetes.io/name=linkshort" --command -- `
  sh -c 'timeout 20 psql "postgresql://linkshort:devpassword@postgres:5432/linkshort" -c "select 1"; echo EXIT=$?'
```

Resultado real:

| | resultado |
|---|---|
| sin label permitida | `EXIT=143` — colgado hasta que el timeout lo mató |
| con label permitida | `EXIT=0`, `select 1` devuelve `1` |

Misma imagen, mismo comando, mismo namespace. La única diferencia es una label. **Con kindnet,
los dos conectaban.**

Ese segundo caso es lo que convierte la prueba en prueba: sin él, un `EXIT=143` podría
significar simplemente que el pod no arranca.

Y la aplicación sigue funcionando, porque sí está permitida:

```powershell
curl.exe http://localhost:8000/ready
# {"status":"ok"}
```

La imagen, sin `pip`:

```powershell
docker run --rm ghcr.io/danzstorm/devops-project:latest pip --version
# executable file not found
```

Y la firma, desde cualquier máquina y sin credenciales:

```powershell
$digest = docker buildx imagetools inspect ghcr.io/danzstorm/devops-project:latest --format '{{json .Manifest.Digest}}'
docker run --rm ghcr.io/sigstore/cosign/cosign:v3.0.2 verify `
  "ghcr.io/danzstorm/devops-project@$digest" `
  --certificate-identity-regexp "https://github.com/Danzstorm/devops-project/.*" `
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

```
The cosign claims were validated
Existence of the claims in the transparency log was verified offline
The code-signing certificate was verified using trusted certificate authority certificates
```

### El susto final: "no signatures found" sobre una imagen bien firmada

El primer intento de verificación, con `cosign v2.4.1`, dijo:

```
Error: no signatures found
```

La firma estaba bien y el CI la había subido. **cosign v3 cambió dónde la guarda**: en lugar
de publicar un tag `sha256-<digest>.sig` junto a la imagen, la adjunta como *referrer* OCI. Un
verificador v2 mira donde ya no está y concluye que no hay nada.

Merece la pena por lo que enseña sobre verificar: un "no" de una herramienta de seguridad no
siempre significa que el control falle — a veces significa que estás preguntando mal. Y la
consecuencia práctica es concreta: **la versión del verificador es parte de la cadena de
confianza**, no un detalle del entorno de quien comprueba.

---

## 9. Deuda consciente

- **Secretos cifrados.** Ver §7. Llega con un entorno que tenga credenciales reales.
- **Nadie verifica la firma antes de desplegar.** Hoy se firma, pero el cluster aceptaría una
  imagen sin firma igualmente. Cerrarlo requiere un admission controller (Kyverno, Gatekeeper)
  que rechace lo que no venga firmado por este repositorio. Es la mitad que falta.
- **Sin RBAC de Argo CD.** El usuario `admin` puede todo. Con un equipo hacen falta proyectos
  y roles.
- **Sin `PodSecurityAdmission` a nivel de namespace.** Los `securityContext` están puestos pod
  a pod; una etiqueta `pod-security.kubernetes.io/enforce=restricted` en el namespace lo haría
  obligatorio para cualquier pod futuro, en vez de depender de que quien escriba el siguiente
  Deployment se acuerde.
- **La imagen sigue sin ser distroless.** Se evaluó en la Fase 2 y se pospuso: baja mucho la
  superficie, pero sin shell dentro depurar un incidente es notablemente más difícil. Con
  `pip` fuera, la mayor parte del beneficio ya está capturada.
- **Egress abierto.** Las políticas cierran la entrada, no la salida. Un pod comprometido
  todavía puede llamar a casa. La regla de DNS ya está escrita para cuando se cierre.

---

## 10. Lo que viene

**Fase 9 — Nube (opcional).** Todo lo construido corre en un portátil. Llevarlo a un proveedor
real cambia las respuestas de varias fases: la base de datos deja de ser un pod y pasa a ser
un servicio gestionado, el estado de Terraform pasa a un backend remoto con bloqueo, los
secretos pasan a un gestor de verdad, y aparecen cosas que en local no existen — IAM, redes,
y una factura.
