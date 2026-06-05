terraform {
  backend "s3" {
    key          = "gitops-demo-cluster/dev/dev-k8s/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
