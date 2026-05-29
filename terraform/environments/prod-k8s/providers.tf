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
