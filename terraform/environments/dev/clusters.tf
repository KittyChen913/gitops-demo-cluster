module "mgmt" {
  source = "../../modules/lke-cluster"

  label        = "lke-${local.environment}-mgmt"
  k8s_version  = var.k8s_version
  region       = var.region
  env          = local.environment
  cluster_role = "management"
  control_plane_acl = local.cluster_boundary_contract.control_plane_acl.activation_enabled ? {
    enabled        = true
    ipv4_addresses = [local.vpn_server_public_egress_cidr]
    ipv6_addresses = local.cluster_boundary_contract.control_plane_acl.ipv6_addresses
  } : null
  node_pools       = [{ type = var.mgmt_node_type, count = var.mgmt_node_count }]
  write_kubeconfig = var.write_kubeconfig_files
  kubeconfig_path  = "${local.kubeconfig_root}/lke-${local.environment}-mgmt.kubeconfig"
}

module "worker" {
  source   = "../../modules/lke-cluster"
  for_each = local.worker_clusters

  label            = each.value.label
  k8s_version      = var.k8s_version
  region           = var.region
  env              = local.environment
  cluster_role     = "worker"
  team             = each.value.team
  node_pools       = [{ type = var.worker_node_type, count = var.worker_node_count }]
  write_kubeconfig = var.write_kubeconfig_files
  kubeconfig_path  = "${local.kubeconfig_root}/${each.value.label}.kubeconfig"
}

locals {
  cluster_boundary_contract     = jsondecode(file("${path.module}/../../../config/worker-firewall/${local.environment}.json"))
  vpn_server_public_egress_cidr = "${var.vpn_server_public_egress_ip}/32"
  cluster_inbound_rules = {
    for cluster_key, cluster in local.cluster_boundary_contract.clusters :
    cluster_key => [
      for rule in cluster.inbound_rules : merge(
        rule,
        {
          ipv4 = try(rule.ipv4_source, "") == "platform_access_vpn_server" ? [
            local.vpn_server_public_egress_cidr
          ] : try(rule.ipv4, [])
        }
      )
    ]
  }
}

module "management_firewall" {
  source = "../../modules/worker-firewall"

  environment               = local.environment
  cluster_label             = module.mgmt.label
  cluster_role              = "management"
  firewall_label            = local.cluster_boundary_contract.clusters.management.firewall_label
  activation_enabled        = local.cluster_boundary_contract.clusters.management.activation_enabled
  evidence_status           = local.cluster_boundary_contract.clusters.management.evidence_status
  required_runtime_evidence = local.cluster_boundary_contract.clusters.management.required_runtime_evidence
  node_instance_ids         = module.mgmt.node_instance_ids
  inbound_policy            = local.cluster_boundary_contract.inbound_policy
  outbound_policy           = local.cluster_boundary_contract.outbound_policy
  inbound_rules             = local.cluster_inbound_rules.management
}

module "worker_firewall" {
  source   = "../../modules/worker-firewall"
  for_each = local.worker_clusters

  environment               = local.environment
  cluster_label             = each.value.label
  cluster_role              = "worker"
  firewall_label            = local.cluster_boundary_contract.clusters[each.key].firewall_label
  activation_enabled        = local.cluster_boundary_contract.clusters[each.key].activation_enabled
  evidence_status           = local.cluster_boundary_contract.clusters[each.key].evidence_status
  required_runtime_evidence = local.cluster_boundary_contract.clusters[each.key].required_runtime_evidence
  node_instance_ids         = module.worker[each.key].node_instance_ids
  inbound_policy            = local.cluster_boundary_contract.inbound_policy
  outbound_policy           = local.cluster_boundary_contract.outbound_policy
  inbound_rules             = local.cluster_inbound_rules[each.key]
}
