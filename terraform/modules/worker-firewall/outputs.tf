output "firewall_id" {
  description = "Cluster Firewall ID when activation is enabled."
  value       = var.activation_enabled ? one(linode_firewall.workers[*].id) : null
}

output "activation_enabled" {
  description = "Whether the Cluster Firewall resource is enabled."
  value       = var.activation_enabled
}

output "evidence_status" {
  description = "Runtime evidence status governing activation."
  value       = var.evidence_status
}
