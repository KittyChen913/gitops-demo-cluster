# Kubernetes provider alias－每個 Cluster 各有一個明確的區塊。
# 階段 1 遠端 state 的管理員憑證僅用於初始化；
# ArgoCD 會使用 ssm.tf 寫入 SSM 的專用 SA 權杖。
#
# 新增 Cluster（例如 bteam）時，在此加入 provider 區塊，
# 並依照 locals.tf 的檢查清單處理。

provider "kubernetes" {
  alias                  = "mgmt"
  host                   = local.mgmt_host
  cluster_ca_certificate = local.mgmt_ca_cert
  token                  = local.mgmt_admin_token
}

provider "kubernetes" {
  alias                  = "ateam"
  host                   = local.ateam_host
  cluster_ca_certificate = local.ateam_ca_cert
  token                  = local.ateam_admin_token
}
