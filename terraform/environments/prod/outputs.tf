output "environment" {
  description = "Environment name."
  value       = local.environment
}

output "management_cluster" {
  description = "Prod Management Cluster metadata."
  value = {
    id              = module.mgmt.id
    label           = module.mgmt.label
    status          = module.mgmt.status
    region          = module.mgmt.region
    k8s_version     = module.mgmt.k8s_version
    cluster_role    = module.mgmt.cluster_role
    api_endpoints   = module.mgmt.api_endpoints
    kubeconfig_file = module.mgmt.kubeconfig_file
    firewall_id     = module.management_firewall.firewall_id
    firewall_active = module.management_firewall.activation_enabled
    evidence_status = module.management_firewall.evidence_status
    control_plane_acl_active = (
      local.cluster_boundary_contract.control_plane_acl.activation_enabled
    )
    control_plane_acl_evidence_status = (
      local.cluster_boundary_contract.control_plane_acl.evidence_status
    )
  }
}

output "worker_clusters" {
  description = "Prod Worker Cluster metadata keyed by team slug."
  value = {
    for key, cluster in module.worker : key => {
      id              = cluster.id
      label           = cluster.label
      team            = cluster.team
      status          = cluster.status
      region          = cluster.region
      k8s_version     = cluster.k8s_version
      cluster_role    = cluster.cluster_role
      api_endpoints   = cluster.api_endpoints
      kubeconfig_file = cluster.kubeconfig_file
      firewall_id     = module.worker_firewall[key].firewall_id
      firewall_active = module.worker_firewall[key].activation_enabled
      evidence_status = module.worker_firewall[key].evidence_status
    }
  }
}

output "cluster_ids" {
  description = "Map of cluster label to LKE ID."
  value = merge(
    { (module.mgmt.label) = module.mgmt.id },
    { for key, cluster in module.worker : cluster.label => cluster.id }
  )
}

output "expected_node_counts" {
  description = "Desired node count keyed by cluster label."
  value = merge(
    { (module.mgmt.label) = var.mgmt_node_count },
    { for key, cluster in module.worker : cluster.label => var.worker_node_count }
  )
}

output "kubeconfigs" {
  description = "Decoded kubeconfigs (sensitive)."
  value = merge(
    { (module.mgmt.label) = module.mgmt.kubeconfig_decoded },
    { for key, cluster in module.worker : cluster.label => cluster.kubeconfig_decoded }
  )
  sensitive = true
}
