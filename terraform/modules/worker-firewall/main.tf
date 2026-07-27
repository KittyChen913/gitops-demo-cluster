resource "linode_firewall" "workers" {
  count = var.activation_enabled ? 1 : 0

  label           = var.firewall_label
  inbound_policy  = var.inbound_policy
  outbound_policy = var.outbound_policy
  linodes         = var.node_instance_ids
  tags = [
    "env:${var.environment}",
    "cluster:${var.cluster_label}",
    "cluster-role:${var.cluster_role}",
    "managed-by:terraform",
    "repo:gitops-demo-cluster",
  ]

  dynamic "inbound" {
    for_each = var.inbound_rules

    content {
      label    = inbound.value.label
      action   = "ACCEPT"
      protocol = upper(inbound.value.protocol)
      ports    = inbound.value.ports
      ipv4     = length(inbound.value.ipv4) > 0 ? inbound.value.ipv4 : null
      ipv6     = length(inbound.value.ipv6) > 0 ? inbound.value.ipv6 : null
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.node_instance_ids) > 0
      error_message = "An active Cluster Firewall must attach to at least one LKE node."
    }
  }
}
