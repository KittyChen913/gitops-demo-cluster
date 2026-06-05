terraform {
  backend "s3" {
    key          = "gitops-demo-cluster/prod/prod-clusters/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
