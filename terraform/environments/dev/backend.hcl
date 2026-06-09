# Bucket name must match bootstrap/variables.tf:tf_state_bucket (default: "kc-gitops-demo-tfstate").
# Terraform backend blocks do not support variable interpolation — update here when renaming.
bucket = "kc-gitops-demo-tfstate"
region = "ap-southeast-1"
