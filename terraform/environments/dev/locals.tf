locals {
  environment = "dev"

  # 擴充時在此加入 BTeam / CTeam 項目（取消註解後套用）。
  worker_clusters = {
    ateam = {
      label = "lke-dev-ateam"
      team  = "ATeam"
    }
    # bteam = {
    #   label = "lke-dev-bteam"
    #   team  = "BTeam"
    # }
  }

  kubeconfig_root = abspath("${path.module}/../../../kubeconfigs/${local.environment}")
  ssm_path_prefix = "/gitops/${local.environment}/clusters"
}
