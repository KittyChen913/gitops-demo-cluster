locals {
  environment = "prod"

  worker_clusters = {
    ateam = {
      label = "lke-prod-ateam"
      team  = "ATeam"
    }
    # bteam = {
    #   label = "lke-prod-bteam"
    #   team  = "BTeam"
    # }
  }

  kubeconfig_root  = abspath("${path.module}/../../../kubeconfigs/${local.environment}")
  ssm_path_prefix  = "/gitops/${local.environment}/clusters"
}
