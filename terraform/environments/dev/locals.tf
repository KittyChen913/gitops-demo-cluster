locals {
  environment = "dev"

  # Add BTeam / CTeam entries here when scaling (uncomment and apply).
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
}
