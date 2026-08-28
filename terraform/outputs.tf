# Los outputs son el contrato de este directorio hacia fuera: lo que otras
# piezas necesitan saber sin tener que leer el estado ni el codigo.

output "cluster_name" {
  description = "Nombre del cluster creado."
  value       = kind_cluster.linkshort.name
}

output "kubectl_context" {
  description = "Contexto de kubectl. Util para no aplicar manifiestos en el cluster equivocado."
  value       = "kind-${kind_cluster.linkshort.name}"
}

output "app_url" {
  description = "URL de la aplicacion una vez desplegada."
  value       = "http://localhost:${var.host_port}"
}

output "siguiente_paso" {
  description = "Terraform deja la plataforma lista; la aplicacion se despliega aparte."
  value       = "kubectl apply -k k8s/overlays/dev"
}

# El kubeconfig NO se expone como output aunque el provider lo ofrezca: contiene
# la clave privada del cliente, y un output se escribe en el estado, se imprime
# en pantalla y aparece en los logs de cualquier CI que ejecute `terraform
# output`. Marcarlo `sensitive = true` lo oculta de la consola pero NO lo cifra
# en el estado, asi que no arregla el problema de fondo.
# kind ya escribe el kubeconfig en ~/.kube/config al crear el cluster.
