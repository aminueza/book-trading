variable "cluster_name" {
  type        = string
  description = "KinD cluster name (docker container prefix)."
  default     = "orderbook-local"
}

variable "node_image" {
  type        = string
  description = "kindest/node image pinned for reproducible local clusters."
  default     = "kindest/node:v1.29.2"
}

variable "orderbook_image" {
  type        = string
  description = "Image reference to load into the kind nodes (build first: docker build -t orderbook-service:latest .)."
  default     = "orderbook-service:latest"
}

variable "istio_chart_version" {
  type        = string
  description = "Istio Helm chart version (base / istiod / gateway)."
  default     = "1.22.6"
}

variable "redis_chart_version" {
  type        = string
  description = "Bitnami Redis Helm chart version."
  default     = "19.6.4"
}

variable "skip_image_load" {
  type        = bool
  description = "Set true to skip kind load docker-image (e.g. image already loaded)."
  default     = false
}
