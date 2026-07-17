# 從階段 1（dev/）的遠端 state 讀取 Cluster 輸出。
# terraform_remote_state 會在 refresh 階段、Kubernetes provider 初始化前求值，
# 因此可安全地在 providers.tf 中使用。
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

  # Management Cluster－管理員憑證僅用於初始化建立 SA。
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

  # 新增 bteam/cteam 時：
  # 1. 在此加入 _bteam_kc、bteam_label、bteam_host、bteam_ca_cert、bteam_admin_token 等 locals
  # 2. 在 providers.tf 加入 provider "kubernetes" { alias = "bteam" ... }
  # 3. 在 argocd_sa.tf 加入 SA 資源
  # 4. 在 ssm.tf 加入 SSM 權杖參數
}
