# Variables con valor por defecto util: `terraform apply` funciona sin pasar
# nada. Un modulo que exige rellenar diez variables para arrancar no se prueba,
# y lo que no se prueba se pudre.

variable "cluster_name" {
  description = "Nombre del cluster de kind. Tambien da nombre al contexto de kubectl (kind-<nombre>)."
  type        = string
  default     = "linkshort"
}

variable "node_image" {
  description = <<-EOT
    Imagen del nodo de kind, que fija la version de Kubernetes.

    Con digest y no solo tag: kindest/node republica los tags, asi que dos
    `apply` con el mismo tag pueden dar clusters con versiones distintas.

    La version la manda el PROVIDER, no el CLI de kind que tengas instalado.
    tehcyx/kind 0.11.0 embebe la libreria de kind v0.31.0, asi que solo sirven
    las imagenes que publico esa release. Una imagen mas nueva falla en
    `kubeadm init` con un error que no menciona versiones por ningun lado.
  EOT
  type        = string
  default     = "kindest/node:v1.34.3@sha256:08497ee19eace7b4b5348db5c6a1591d7752b164530a36f855cb0f2bdcbadd48"
}

variable "host_port" {
  description = "Puerto del host que se mapea al NodePort 30080 del cluster."
  type        = number
  default     = 8000

  validation {
    # Falla en `plan`, antes de crear nada. Un puerto por debajo de 1024 exige
    # privilegios y el error llegaria a mitad de la creacion del cluster.
    condition     = var.host_port > 1024 && var.host_port < 65536
    error_message = "host_port tiene que estar entre 1025 y 65535."
  }
}

variable "calico_version" {
  description = "Version del chart tigera-operator (Calico). Sustituye a kindnet, que no aplica NetworkPolicy."
  type        = string
  default     = "v3.32.1"
}

variable "argocd_version" {
  description = "Version del chart de Argo CD. El chart 10.4.1 instala Argo CD v3.5.2."
  type        = string
  default     = "10.4.1"
}

variable "kube_prometheus_stack_version" {
  description = "Version del chart kube-prometheus-stack (Prometheus Operator, Prometheus y Grafana)."
  type        = string
  default     = "88.6.1"
}

variable "metrics_server_version" {
  description = "Version del chart de metrics-server. Fija, nunca la ultima."
  type        = string
  default     = "3.14.0"
}
