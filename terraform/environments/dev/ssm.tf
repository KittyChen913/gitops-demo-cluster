# ---------------------------------------------------------------------------
# AWS SSM Parameter Store – cluster registration (Phase 1)
#
# Stores API endpoint and CA certificate for each cluster.
# The ArgoCD SA token (Phase 2) is written by dev-k8s/ssm.tf after
# dedicated ServiceAccounts are created in each cluster.
#
# Path schema:
#   /gitops/<env>/clusters/<cluster-label>/api-endpoint  (String)
#   /gitops/<env>/clusters/<cluster-label>/ca-cert       (String, base64)
#   /gitops/<env>/clusters/<cluster-label>/token         (SecureString) ← dev-k8s/
# ---------------------------------------------------------------------------

locals {
  # Parse each kubeconfig to extract the CA certificate.
  _mgmt_kc     = yamldecode(module.mgmt.kubeconfig_decoded)
  mgmt_ca_cert = local._mgmt_kc.clusters[0].cluster["certificate-authority-data"]

  _worker_kc = {
    for key, _ in local.worker_clusters :
    key => yamldecode(module.worker[key].kubeconfig_decoded)
  }
  worker_ca_cert = {
    for key, kc in local._worker_kc :
    key => kc.clusters[0].cluster["certificate-authority-data"]
  }
}

# ── Management cluster ──────────────────────────────────────────────────────

resource "aws_ssm_parameter" "mgmt_api_endpoint" {
  count = var.write_ssm_parameters ? 1 : 0

  name  = "${local.ssm_path_prefix}/${module.mgmt.label}/api-endpoint"
  type  = "String"
  value = module.mgmt.api_endpoints[0]

  tags = {
    Environment  = local.environment
    ClusterRole  = "management"
    ClusterLabel = module.mgmt.label
    ManagedBy    = "terraform"
  }
}

resource "aws_ssm_parameter" "mgmt_ca_cert" {
  count = var.write_ssm_parameters ? 1 : 0

  name  = "${local.ssm_path_prefix}/${module.mgmt.label}/ca-cert"
  type  = "String"
  value = local.mgmt_ca_cert

  tags = {
    Environment  = local.environment
    ClusterRole  = "management"
    ClusterLabel = module.mgmt.label
    ManagedBy    = "terraform"
  }
}

# ── Worker clusters (one set of parameters per team) ────────────────────────

resource "aws_ssm_parameter" "worker_api_endpoint" {
  for_each = var.write_ssm_parameters ? local.worker_clusters : {}

  name  = "${local.ssm_path_prefix}/${module.worker[each.key].label}/api-endpoint"
  type  = "String"
  value = module.worker[each.key].api_endpoints[0]

  tags = {
    Environment  = local.environment
    ClusterRole  = "worker"
    ClusterLabel = module.worker[each.key].label
    Team         = module.worker[each.key].team
    ManagedBy    = "terraform"
  }
}

resource "aws_ssm_parameter" "worker_ca_cert" {
  for_each = var.write_ssm_parameters ? local.worker_clusters : {}

  name  = "${local.ssm_path_prefix}/${module.worker[each.key].label}/ca-cert"
  type  = "String"
  value = local.worker_ca_cert[each.key]

  tags = {
    Environment  = local.environment
    ClusterRole  = "worker"
    ClusterLabel = module.worker[each.key].label
    Team         = module.worker[each.key].team
    ManagedBy    = "terraform"
  }
}


