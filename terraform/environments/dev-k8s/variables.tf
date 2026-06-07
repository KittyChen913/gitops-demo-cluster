variable "aws_region" {
  description = "AWS region for SSM Parameter Store and cluster remote state bucket."
  type        = string
  default     = "ap-southeast-1"
}

variable "write_ssm_parameters" {
  description = "Push ArgoCD ServiceAccount tokens to AWS SSM Parameter Store."
  type        = bool
  default     = true
}

variable "cluster_state_bucket" {
  description = "S3 bucket holding the dev/ Terraform state (output of Phase 1)."
  type        = string
  default     = "gitops-demo-cluster-tfstate"
}

variable "cluster_state_key" {
  description = "S3 key of the dev/ Terraform state."
  type        = string
  default     = "gitops-demo-cluster/dev/dev-clusters/terraform.tfstate"
}
