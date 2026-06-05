terraform {
  backend "s3" {
    key          = "gitops-demo-cluster/dev/dev-clusters/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
