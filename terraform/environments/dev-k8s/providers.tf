# Kubernetes provider aliases – one explicit block per cluster.
# Admin credentials from Phase 1 remote state are used only for bootstrapping;
# ArgoCD will use the dedicated SA token written to SSM by ssm.tf.
#
# When adding a new cluster (e.g. bteam), add a provider block here and
# follow the checklist in locals.tf.

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
