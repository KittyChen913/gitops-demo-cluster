# Management Cluster 與 ATeam Worker Cluster 使用相同 RBAC module；
# provider alias 仍在環境層明確指定，避免跨 Cluster 套用。
module "argocd_mgmt" {
  source = "../../modules/argocd-cluster-access"

  providers = {
    kubernetes = kubernetes.mgmt
  }
}

module "argocd_ateam" {
  source = "../../modules/argocd-cluster-access"

  providers = {
    kubernetes = kubernetes.ateam
  }
}
