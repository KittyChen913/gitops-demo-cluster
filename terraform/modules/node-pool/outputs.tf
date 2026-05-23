output "id" {
  description = "Node pool ID."
  value       = linode_lke_node_pool.this.id
}

output "type" {
  description = "Instance type."
  value       = linode_lke_node_pool.this.type
}

output "count" {
  description = "Node count."
  value       = linode_lke_node_pool.this.count
}

output "labels" {
  description = "Kubernetes node labels."
  value       = linode_lke_node_pool.this.labels
}
