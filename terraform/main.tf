# Infraestructura como codigo: la PLATAFORMA, no la aplicacion.
#
# La frontera de este directorio es la decision mas importante de la fase:
#
#   Terraform  ->  lo que existe UNA VEZ y cambia poco: el cluster, sus
#                  complementos, y manana la red, el registro y la base
#                  gestionada. Cosas con ciclo de vida propio.
#
#   kustomize  ->  la aplicacion, que se despliega varias veces al dia.
#
# Se podria desplegar la app con el provider kubernetes de Terraform. Seria un
# error: cada despliegue pasaria por un `terraform apply` que bloquea el estado,
# y un rollback dependeria de revertir codigo de infraestructura. Peor aun,
# mezclaria en un mismo estado lo que tarda 20 minutos en crearse con lo que
# cambia veinte veces al dia.

terraform {
  required_version = ">= 1.9"

  # Versiones acotadas, igual que las imagenes base y las actions del CI. El
  # operador ~> permite parches (0.11.1) pero no saltos de minor (0.12.0), que
  # en providers 0.x suelen traer cambios incompatibles.
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.11.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
  }

  # Backend local: el estado vive en terraform.tfstate, aqui al lado, y esta en
  # .gitignore. NO se commitea, y no por costumbre:
  #
  #   1. El estado guarda en CLARO todo lo que Terraform gestiona, incluidas
  #      contrasenas y claves. Es el archivo mas sensible del repositorio si
  #      alguna vez entra en el.
  #   2. Sin bloqueo, dos `apply` a la vez lo corrompen.
  #
  # Para una sola persona y un cluster desechable, local basta. En cuanto haya
  # dos personas o infraestructura real, esto pasa a un backend remoto (S3 con
  # DynamoDB, GCS, Terraform Cloud) que aporta cifrado, versionado y bloqueo.
  # Se deja anotado y no se monta ahora: no hay nada que proteger todavia.
}

provider "kind" {}

# -----------------------------------------------------------------------------
# El cluster
# -----------------------------------------------------------------------------
# Sustituye a `kind create cluster --config k8s/kind-cluster.yaml`. La topologia
# ya estaba versionada; lo que cambia es que ahora tambien esta el ESTADO: qué
# existe de verdad, para poder comparar y corregir la diferencia.
resource "kind_cluster" "linkshort" {
  name           = var.cluster_name
  node_image     = var.node_image
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    networking {
      # Fase 8: fuera kindnet, el CNI que trae kind de serie.
      #
      # kindnet NO implementa NetworkPolicy. Y no falla: acepta el recurso, lo
      # guarda, `kubectl get networkpolicy` lo lista tan tranquilo... y no filtra
      # absolutamente nada. Comprobado: con una policy de "denegar toda entrada"
      # sobre Postgres, la aplicacion seguia respondiendo 200 en /ready.
      #
      # Es el peor fallo posible en seguridad: no una puerta abierta, sino una
      # puerta que parece cerrada. Se cambia por Calico, que si las aplica.
      disable_default_cni = true
    }

    node {
      role = "control-plane"

      # El mismo mapeo que en k8s/kind-cluster.yaml y por el mismo motivo: kind
      # corre los nodos como contenedores de Docker, asi que un NodePort no es
      # alcanzable desde el host si no se mapea al crear el cluster.
      extra_port_mappings {
        container_port = 30080
        host_port      = var.host_port
        protocol       = "TCP"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Complementos de plataforma
# -----------------------------------------------------------------------------
# Las credenciales salen del recurso anterior, no de un kubeconfig del disco.
# Asi Terraform sabe que el cluster tiene que existir ANTES de instalar nada:
# la dependencia es real y no hay que declararla con depends_on.
provider "helm" {
  kubernetes = {
    host                   = kind_cluster.linkshort.endpoint
    cluster_ca_certificate = kind_cluster.linkshort.cluster_ca_certificate
    client_certificate     = kind_cluster.linkshort.client_certificate
    client_key             = kind_cluster.linkshort.client_key
  }
}

# Calico: el CNI que sustituye a kindnet.
#
# Va antes que todo lo demas por una razon fisica: sin CNI, ningun pod obtiene
# IP y todo se queda en Pending. Por eso el resto de complementos declaran
# depends_on contra este recurso -- es de los pocos sitios donde la dependencia
# no se deduce sola de las referencias.
resource "helm_release" "calico" {
  name             = "calico"
  repository       = "https://docs.tigera.io/calico/charts"
  chart            = "tigera-operator"
  version          = var.calico_version
  namespace        = "tigera-operator"
  create_namespace = true
  timeout          = 600
}

# metrics-server: sin el, `kubectl top` no funciona y un HorizontalPodAutoscaler
# no tiene de donde leer. Kubernetes no lo trae de serie.
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_version
  namespace  = "kube-system"

  # kind genera los certificados del kubelet con nombres que no coinciden con la
  # IP por la que metrics-server lo consulta, asi que la verificacion TLS falla y
  # el pod se queda sin arrancar del todo.
  #
  # Es una excepcion de laboratorio y hay que decirlo claro: desactiva la
  # verificacion del certificado del kubelet. En un cluster de verdad NO se pone
  # -- alli los certificados son correctos y esto seria abrir una puerta por
  # comodidad.
  set = [{
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }]

  depends_on = [helm_release.calico]
}

# Argo CD: la HERRAMIENTA es plataforma, asi que se instala aqui.
#
# Lo que Argo CD despliega -- la Application que apunta al repositorio -- NO va
# en Terraform: vive en k8s/argocd/application.yaml y se aplica una vez para
# arrancar el bucle. Esa separacion es la misma frontera de la Fase 5. Si la
# Application viviera aqui, cambiar a que rama apunta seria un `terraform
# apply`, y volveriamos a mezclar infraestructura con despliegue.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  namespace        = "argocd"
  create_namespace = true

  # server.insecure: el servidor sirve HTTP en vez de HTTPS con certificado
  # autofirmado. Se accede por `kubectl port-forward`, es decir por un tunel
  # local que nunca sale de la maquina, asi que el TLS aqui solo anadiria un
  # aviso de certificado invalido en el navegador.
  #
  # En un cluster real esto NO se pone: alli el servidor esta detras de un
  # Ingress con certificado de verdad, y el trafico si cruza una red.
  set = [{
    name  = "configs.params.server\\.insecure"
    value = "true"
  }]
  depends_on = [helm_release.calico]

}

# Prometheus + Grafana + Prometheus Operator.
#
# Va en Terraform por la misma razon que Argo CD: es plataforma. La aplicacion
# declara QUE exponer (un ServiceMonitor, en k8s/base/) y la plataforma se
# encarga de recogerlo. Ese reparto es lo que permite que un equipo anada
# monitorizacion a su servicio sin tocar la configuracion de Prometheus.
resource "helm_release" "kube_prometheus_stack" {
  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.kube_prometheus_stack_version
  namespace        = "monitoring"
  create_namespace = true

  values = [file("${path.module}/values/kube-prometheus-stack.yaml")]

  # Ojo con la frontera: aqui se instala Grafana (plataforma), NO se despliega
  # nada de la aplicacion -- ni siquiera su dashboard, que viaja con ella en
  # k8s/base y lo recoge el sidecar de Grafana por su label.

  # El chart instala CRDs (ServiceMonitor, PrometheusRule...) y tarda en dejar
  # los webhooks listos. Sin margen, el primer apply falla de forma
  # intermitente, que es el peor tipo de fallo: se arregla reintentando y nadie
  # investiga por que.
  timeout = 600

  depends_on = [helm_release.calico]
}
