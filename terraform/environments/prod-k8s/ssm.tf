# ---------------------------------------------------------------------------
# AWS SSM Parameter Store－ArgoCD SA 權杖（階段 2）
#
# 路徑：/gitops/prod/clusters/<cluster-label>/token（SecureString）
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "mgmt_token" {
  count = var.write_ssm_parameters ? 1 : 0

  name  = "${local.ssm_path_prefix}/${local.mgmt_label}/token"
  type  = "SecureString"
  value = module.argocd_mgmt.token

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
  value = module.argocd_ateam.token

  tags = {
    Environment  = local.environment
    ClusterRole  = "worker"
    ClusterLabel = local.ateam_label
    Team         = "ATeam"
    ManagedBy    = "terraform"
  }
}
