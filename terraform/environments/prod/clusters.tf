module "mgmt" {
  source = "../../modules/lke-cluster"

  label          = "lke-${local.environment}-mgmt"
  k8s_version    = var.k8s_version
  region         = var.region
  env            = local.environment
  cluster_role   = "management"
  node_pools     = [{ type = var.mgmt_node_type, count = var.mgmt_node_count }]
  write_kubeconfig = var.write_kubeconfig_files
  kubeconfig_path  = "${local.kubeconfig_root}/lke-${local.environment}-mgmt.kubeconfig"
}

module "worker" {
  source   = "../../modules/lke-cluster"
  for_each = local.worker_clusters

  label          = each.value.label
  k8s_version    = var.k8s_version
  region         = var.region
  env            = local.environment
  cluster_role   = "worker"
  team           = each.value.team
  node_pools     = [{ type = var.worker_node_type, count = var.worker_node_count }]
  write_kubeconfig = var.write_kubeconfig_files
  kubeconfig_path  = "${local.kubeconfig_root}/${each.value.label}.kubeconfig"
}
