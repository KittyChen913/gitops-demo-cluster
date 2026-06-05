terraform {
  backend "s3" {
    key          = "gitops-demo-cluster/prod/prod-k8s/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
