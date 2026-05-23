output "id" {
  description = "LKE cluster ID."
  value       = linode_lke_cluster.this.id
}

output "label" {
  description = "LKE cluster label."
  value       = linode_lke_cluster.this.label
}

output "status" {
  description = "Cluster status."
  value       = linode_lke_cluster.this.status
}

output "k8s_version" {
  description = "Kubernetes version."
  value       = linode_lke_cluster.this.k8s_version
}

output "region" {
  description = "Cluster region."
  value       = linode_lke_cluster.this.region
}

output "api_endpoints" {
  description = "Kubernetes API endpoints."
  value       = linode_lke_cluster.this.api_endpoints
}

output "kubeconfig" {
  description = "Base64-encoded kubeconfig."
  value       = linode_lke_cluster.this.kubeconfig
  sensitive   = true
}

output "kubeconfig_decoded" {
  description = "Decoded kubeconfig YAML."
  value       = base64decode(linode_lke_cluster.this.kubeconfig)
  sensitive   = true
}

output "tags" {
  description = "Linode tags on the cluster."
  value       = linode_lke_cluster.this.tags
}

output "pool" {
  description = "Node pool metadata."
  value       = linode_lke_cluster.this.pool
}

output "cluster_role" {
  description = "Declared cluster role."
  value       = var.cluster_role
}

output "env" {
  description = "Declared environment."
  value       = var.env
}

output "team" {
  description = "Declared team (worker clusters only)."
  value       = var.team
}

output "kubeconfig_file" {
  description = "Local path when write_kubeconfig is enabled."
  value       = var.write_kubeconfig ? var.kubeconfig_path : null
}
