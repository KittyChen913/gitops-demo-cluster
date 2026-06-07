# Bucket name must match bootstrap/variables.tf:tf_state_bucket (default: "gitops-demo-cluster-tfstate").
# Terraform backend blocks do not support variable interpolation — update here when renaming.
bucket = "gitops-demo-cluster-tfstate"
region = "ap-southeast-1"
