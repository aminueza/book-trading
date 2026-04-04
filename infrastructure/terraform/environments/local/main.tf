# Local Kubernetes: KinD + Istio (Helm) + Redis (Helm) + orderbook (kustomize).
#
# Prerequisites: Docker, kind (CLI), kubectl, Helm 3, Terraform 1.7+.
# From repo root: docker build -t orderbook-service:latest .
# Then: cd infrastructure/terraform/environments/local && tofu init && tofu apply

locals {
  repo_root      = abspath("${path.module}/../../../..")
  overlay_dir    = "${local.repo_root}/infrastructure/deploy/kubernetes/overlays/local"
  monitoring_dir = "${local.repo_root}/infrastructure/deploy/kubernetes/monitoring/local"
  script_path    = abspath("${path.module}/scripts/bootstrap-workloads.sh")
}

resource "kind_cluster" "this" {
  name           = var.cluster_name
  wait_for_ready = true
  node_image     = var.node_image

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
      # Map host ports into the KinD node so the orderbook NodePort (30801) and
      # Grafana NodePort (30300) are reachable without kubectl port-forward.
      extra_port_mappings {
        container_port = 30801
        host_port      = 8001
      }
      extra_port_mappings {
        container_port = 30300
        host_port      = 3000
      }
    }
  }
}

resource "local_file" "kubeconfig" {
  content         = kind_cluster.this.kubeconfig
  filename        = abspath("${path.module}/kubeconfig.yaml")
  file_permission = "0600"

  depends_on = [kind_cluster.this]
}

# Always present so bootstrap_workloads can use a static depends_on (OpenTofu/Terraform
# disallow dynamic concat() in depends_on).
resource "null_resource" "load_orderbook_image" {
  triggers = {
    cluster         = kind_cluster.this.id
    image           = var.orderbook_image
    skip_image_load = tostring(var.skip_image_load)
  }

  provisioner "local-exec" {
    command = var.skip_image_load ? "true" : "kind load docker-image ${var.orderbook_image} --name ${var.cluster_name}"
  }

  depends_on = [kind_cluster.this]
}

resource "null_resource" "bootstrap_workloads" {
  triggers = {
    kubeconfig_sha = kind_cluster.this.id
    istio          = var.istio_chart_version
    redis          = var.redis_chart_version
    kustomize_sha = sha256(join("", concat(
      [for p in sort(fileset(local.overlay_dir, "**/*.yaml")) : filesha256("${local.overlay_dir}/${p}")],
      [for p in sort(fileset(local.overlay_dir, "**/*.json")) : filesha256("${local.overlay_dir}/${p}")],
      [for p in sort(fileset(local.monitoring_dir, "**/*.yaml")) : filesha256("${local.monitoring_dir}/${p}")],
      [for p in sort(fileset(local.monitoring_dir, "**/*.json")) : filesha256("${local.monitoring_dir}/${p}")],
    )))
    script_sha = filesha256(local.script_path)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      bash "${local.script_path}" \
        "${abspath(local_file.kubeconfig.filename)}" \
        "${var.istio_chart_version}" \
        "${var.redis_chart_version}" \
        "${local.overlay_dir}"
    EOT
  }

  depends_on = [
    kind_cluster.this,
    local_file.kubeconfig,
    null_resource.load_orderbook_image,
  ]
}
