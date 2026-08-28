# Fase 7 — Observabilidad

> **Estado:** completada
> **Archivos:** `terraform/values/kube-prometheus-stack.yaml`, `k8s/base/servicemonitor.yaml`, `observability/dashboards/linkshort.json`

---

## 1. La pregunta que ya sabíamos responder, y la que no

Desde la Fase 4 sabemos si un pod está arriba. Es información útil y es casi inútil por sí
sola, porque un servicio puede estar "arriba" y ser inservible: respondiendo en ocho
segundos, o devolviendo 500 a una de cada veinte peticiones.

Las preguntas que importan son otras:

- ¿Cuánto tarda el usuario que peor lo está pasando?
- ¿Qué proporción de peticiones falla por nuestra culpa?
- ¿El despliegue de hace diez minutos empeoró algo?

La aplicación expone `/metrics` desde la Fase 1 y nadie lo leía. Esta fase pone quien lo lea.

---

## 2. El reparto: quién declara y quién recoge

Se mantiene la frontera de la Fase 5, aplicada a monitorización:

| | Dónde | Qué dice |
|---|---|---|
| Prometheus, Grafana, el Operator | Terraform | *cómo* se recogen y se miran las métricas |
| `ServiceMonitor` | `k8s/base/`, lo despliega Argo CD | *qué* expone esta aplicación |

Ese reparto es lo que permite que un equipo añada monitorización a su servicio **sin tocar la
configuración de Prometheus**. La alternativa clásica —una lista de destinos en un
`prometheus.yml` que alguien mantiene a mano— siempre está desactualizada, porque cada
servicio nuevo depende de que otra persona edite un archivo central.

```yaml
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: linkshort
  endpoints:
    - port: http        # por NOMBRE, no por número
```

El `ServiceMonitor` no nombra pods ni IPs: selecciona un Service, y Prometheus descubre solo
los pods que hay detrás. Un despliegue cambia todas las IPs y aquí no se toca nada.

---

## 3. Tres fallos silenciosos, que son la parte útil de esta fase

Los tres comparten una característica que los hace caros: **no producen ningún error**. Todo
"funciona", solo que no hay datos.

### 3.1 El selector por defecto ignora tu ServiceMonitor

Por defecto, kube-prometheus-stack solo descubre los `ServiceMonitor` que llevan la label de
su propio release de Helm. El de la aplicación —que vive en otro sitio y lo despliega Argo
CD— sería ignorado **en silencio**.

```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
```

Es el fallo número uno con este chart y cuesta horas encontrarlo, porque no hay nada roto que
mirar.

### 3.2 El Service necesita una label, no solo un selector

El `ServiceMonitor` selecciona **Services por label**. El Service de la Fase 4 tenía
`selector` (que lo enlaza con sus *pods*) pero ninguna label propia, así que no casaba con
nada.

```
ServiceMonitor --(labels)--> Service --(selector)--> Pods
```

Son dos relaciones distintas que usan la misma pareja clave/valor, y es fácil dar por hecho
que basta con una.

### 3.3 `sum()` de un conjunto vacío no es cero

El panel de tasa de error mostraba `sin datos` en lugar de `0`:

```promql
sum(rate(http_requests_total{status=~"5.."}[5m])) / clamp_min(sum(rate(...)), 0.001)
```

Cuando no hay ningún 5xx —o sea, **cuando todo va bien**— el numerador no tiene series, y una
división sin series no da cero: no da nada.

```promql
(sum(rate(http_requests_total{status=~"5.."}[5m])) or vector(0)) / clamp_min(...)
```

El detalle importa más de lo que parece: un panel que dice "No data" cuando el sistema está
sano enseña a la gente a ignorarlo, y entonces tampoco lo mirarán el día que diga 5%.

---

## 4. Verificado con datos reales

Tras generar 25 POST y 25 peticiones a un slug inexistente:

```
peticiones registradas: 656
p99 latencia:   0.099 s
p50 latencia:   0.05  s
tasa error 5xx: 0
replicas listas: 2
memoria pod:    65 MB
```

Dos lecturas que sirven para algo:

- **p50 = 50 ms y p99 = 99 ms.** La cola es el doble que la mediana, no veinte veces. Es un
  perfil sano; cuando esa distancia se dispara es que algo se satura (el pool de conexiones,
  normalmente).
- **65 MB reales** contra un `request` de 128 Mi y un `limit` de 256 Mi. El dimensionado de la
  Fase 4 estaba bien puesto.

---

## 5. Por qué la media no aparece en ningún panel

El dashboard muestra p50, p95 y p99, y ninguna media. No es purismo:

Con 99 peticiones de 10 ms y una de 10 segundos, la media sale ~110 ms. Suena bien y esconde
exactamente el caso que hay que arreglar. El p99, en cambio, **es** ese usuario. Los
percentiles no promedian el dolor, lo localizan.

Y por eso el histograma de la aplicación importa: `histogram_quantile` necesita los *buckets*
que expone `prometheus-fastapi-instrumentator`. Una métrica que solo publicara la media no
permitiría calcular nada de esto después.

---

## 6. El dashboard es un archivo, no un dibujo

```hcl
resource "kubernetes_config_map" "dashboard_linkshort" {
  metadata { labels = { grafana_dashboard = "1" } }
  data = { "linkshort.json" = file(".../observability/dashboards/linkshort.json") }
}
```

El sidecar de Grafana descubre cualquier ConfigMap con esa label y lo carga solo:

```
{"level": "INFO", "msg": "Writing /tmp/dashboards/linkshort.json (ascii)"}
```

Un dashboard hecho clicando en la interfaz existe **solo en esa Grafana**: no se revisa en un
PR, no sobrevive a recrear el cluster, y nadie sabe quién cambió ese umbral ni por qué. Como
archivo, es código: tiene historial, autor y revisión.

---

## 7. Alertmanager está apagado, a propósito

```yaml
alertmanager:
  enabled: false
```

Sin un destino de notificación, Alertmanager solo acumula alertas en una interfaz que nadie
mira. **Una alerta que no despierta a nadie no es una alerta, es una fila en una tabla.**

Se enciende cuando haya un canal real (Slack, PagerDuty) y —más importante— cuando haya
alguien de guardia y un criterio de qué merece interrumpir a una persona. Encenderlo antes
solo entrena a ignorar avisos.

---

## 8. Verificación

```powershell
terraform -chdir=terraform apply
kubectl -n monitoring get pods
```

Prometheus (la interfaz, y las consultas):

```powershell
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
# http://localhost:9090/targets  -> el destino "linkshort" debe estar UP
```

Grafana:

```powershell
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# admin / devpassword  -> Dashboards -> linkshort
```

Generar tráfico y ver moverse los paneles:

```powershell
1..25 | ForEach-Object { curl.exe -s -X POST http://localhost:8000/links -H "Content-Type: application/json" -d '{\"url\":\"https://prometheus.io/\"}' > $null }
```

> **Nota:** el contenedor de Prometheus es *distroless* — no tiene shell, así que
> `kubectl exec ... -- wget` falla. Para consultar su API hay que hacer `port-forward`.

---

## 9. Deuda consciente

- **Métricas, pero no trazas ni logs agregados.** Prometheus dice *que* el p99 subió; una
  traza diría *dónde*. OpenTelemetry + Tempo/Jaeger es el paso siguiente, y con un solo
  servicio aporta poco: el valor de las trazas aparece cuando hay saltos entre servicios.
- **Los logs siguen en stdout.** La Fase 1 los dejó en JSON preparados para un agregador
  (Loki), que no se ha montado. En un cluster de un nodo, `kubectl logs` alcanza.
- **Sin alertas ni SLO.** Los paneles existen pero nadie vigila. Definir un SLO
  (p. ej. 99,9% de peticiones bajo 300 ms) y alertar sobre el consumo de *error budget* es el
  paso que convierte los gráficos en operación.
- **Sin persistencia en Prometheus.** Retención de 2 días en disco efímero: al reiniciarse, se
  pierde el histórico. Suficiente en local, inútil para investigar un incidente de la semana
  pasada.
- **La contraseña de Grafana es `devpassword`**, en claro y en el repositorio, igual que el
  resto de credenciales de desarrollo. Fase 8.

---

## 10. Lo que viene

**Fase 8 — Seguridad.** Es la fase donde se pagan casi todas las deudas anotadas: `gitleaks`
para que la regla *"ningún secreto en git"* deje de ser un sistema de honor, las reglas `S`
de ruff, firma de imágenes con `cosign` y SBOM, `NetworkPolicy` (hoy cualquier pod del
cluster puede hablar con Postgres) y secretos de verdad con Sealed Secrets.
