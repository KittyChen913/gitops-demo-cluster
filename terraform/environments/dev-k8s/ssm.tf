# ---------------------------------------------------------------------------
# AWS SSM Parameter Store – ArgoCD SA tokens (Phase 2)
#
# Writes the argocd-manager ServiceAccount token for each cluster.
# The api-endpoint and ca-cert parameters are managed by dev/ssm.tf (Phase 1).
#
# Path: /gitops/dev/clusters/<cluster-label>/token  (SecureString)
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "mgmt_token" {
  count = var.write_ssm_parameters ? 1 : 0

  name  = "${local.ssm_path_prefix}/${local.mgmt_label}/token"
  type  = "SecureString"
  value = data.kubernetes_secret_v1.argocd_token_mgmt.data["token"]

  tags = {
    Environment  = local.environment
    ClusterRole  = "management"
    ClusterLabel = local.mgmt_label
    ManagedBy    = "terraform"
  }
}

resource "aws_ssm_parameter" "ateam_token" {
  count = var.write_ssm_parameters ? 1 : 0

  name  = "${local.ssm_path_prefix}/${local.ateam_label}/token"
  type  = "SecureString"
  value = data.kubernetes_secret_v1.argocd_token_ateam.data["token"]

  tags = {
    Environment  = local.environment
    ClusterRole  = "worker"
    ClusterLabel = local.ateam_label
    Team         = "ATeam"
    ManagedBy    = "terraform"
  }
}
