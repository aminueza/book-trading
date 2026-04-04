output "cluster_name" {
  description = "KinD cluster name."
  value       = kind_cluster.this.name
}

output "kubeconfig_path" {
  description = "Absolute path to the kubeconfig written by Terraform (use with kubectl / validate.sh)."
  value       = abspath(local_file.kubeconfig.filename)
}

output "port_forward_command" {
  description = "Port-forward the Istio ingress gateway to localhost:8080 (run in a separate terminal)."
  value       = "kubectl --kubeconfig=${abspath(local_file.kubeconfig.filename)} port-forward -n istio-system svc/istio-ingressgateway 8080:80"
}

output "next_steps" {
  description = "Smoke-test the API after port-forward."
  value       = "From repo root, with port-forward running: ./scripts/validate.sh http://localhost:8080"
}
