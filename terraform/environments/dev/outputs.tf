output "environment" {
  description = "Environment name."
  value       = local.environment
}

output "management_cluster" {
  description = "Dev management cluster metadata."
  value = {
    id            = module.mgmt.id
    label         = module.mgmt.label
    status        = module.mgmt.status
    region        = module.mgmt.region
    k8s_version   = module.mgmt.k8s_version
    cluster_role  = module.mgmt.cluster_role
    api_endpoints = module.mgmt.api_endpoints
    kubeconfig_file = module.mgmt.kubeconfig_file
  }
}

output "worker_clusters" {
  description = "Dev worker cluster metadata keyed by team slug (ateam, bteam, ...)."
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

output "kubeconfigs" {
  description = "Decoded kubeconfigs (sensitive). Use kubeconfig files or terraform output -raw."
  value = merge(
    { (module.mgmt.label) = module.mgmt.kubeconfig_decoded },
    { for key, cluster in module.worker : cluster.label => cluster.kubeconfig_decoded }
  )
  sensitive = true
}
