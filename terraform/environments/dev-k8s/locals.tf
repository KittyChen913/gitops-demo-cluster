# Reads cluster outputs from Phase 1 (dev/) remote state.
# terraform_remote_state is evaluated during the refresh step, before
# kubernetes provider initialization, making it safe to use in providers.tf.
data "terraform_remote_state" "clusters" {
  backend = "s3"
  config = {
    bucket = var.cluster_state_bucket
    key    = var.cluster_state_key
    region = var.aws_region
  }
}

locals {
  environment     = "dev"
  ssm_path_prefix = "/gitops/${local.environment}/clusters"

  # Management cluster – admin credentials used only to bootstrap SA creation.
  _mgmt_kc         = yamldecode(data.terraform_remote_state.clusters.outputs.kubeconfigs["lke-dev-mgmt"])
  mgmt_label       = data.terraform_remote_state.clusters.outputs.management_cluster.label
  mgmt_host        = data.terraform_remote_state.clusters.outputs.management_cluster.api_endpoints[0]
  mgmt_ca_cert     = base64decode(local._mgmt_kc.clusters[0].cluster["certificate-authority-data"])
  mgmt_admin_token = local._mgmt_kc.users[0].user.token

  _ateam_kc         = yamldecode(data.terraform_remote_state.clusters.outputs.kubeconfigs["lke-dev-ateam"])
  ateam_label       = data.terraform_remote_state.clusters.outputs.worker_clusters["ateam"].label
  ateam_host        = data.terraform_remote_state.clusters.outputs.worker_clusters["ateam"].api_endpoints[0]
  ateam_ca_cert     = base64decode(local._ateam_kc.clusters[0].cluster["certificate-authority-data"])
  ateam_admin_token = local._ateam_kc.users[0].user.token

  # When adding bteam/cteam:
  # 1. Add locals here for _bteam_kc, bteam_label, bteam_host, bteam_ca_cert, bteam_admin_token
  # 2. Add provider "kubernetes" { alias = "bteam" ... } in providers.tf
  # 3. Add SA resources in argocd_sa.tf
  # 4. Add SSM token parameter in ssm.tf
}
