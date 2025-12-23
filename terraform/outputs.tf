# ==============================================================================
# Outputs
# ==============================================================================

output "cluster_name" {
  value       = var.cluster_name
  description = "Kubernetes cluster name"
}

output "cluster_endpoint" {
  value       = local.cluster_endpoint
  description = "Kubernetes API endpoint URL"
}

output "control_plane_ips" {
  value       = local.cp_ips
  description = "IP addresses of control plane nodes"
}

output "worker_ips" {
  value       = local.worker_ips
  description = "IP addresses of worker nodes"
}

output "talosconfig" {
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
  description = "Talos client configuration for talosctl"
}

output "kubeconfig" {
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
  description = "Kubernetes admin kubeconfig"
}