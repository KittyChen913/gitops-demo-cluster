variable "linode_token" {
  description = "Linode API token. Prefer LINODE_TOKEN env var; leave empty to use the environment."
  type        = string
  sensitive   = true
  default     = ""
}

variable "region" {
  description = "Linode region for all prod clusters."
  type        = string
  default     = "ap-west"
}

variable "k8s_version" {
  description = "Kubernetes version for all prod clusters."
  type        = string
  default     = "1.32"
}

variable "mgmt_node_type" {
  description = "Instance type for the management cluster node pool."
  type        = string
  default     = "g6-standard-4"
}

variable "mgmt_node_count" {
  description = "Node count for the management cluster."
  type        = number
  default     = 3
}

variable "worker_node_type" {
  description = "Default instance type for worker clusters."
  type        = string
  default     = "g6-standard-4"
}

variable "worker_node_count" {
  description = "Default node count for worker clusters."
  type        = number
  default     = 3
}

variable "write_kubeconfig_files" {
  description = "Write kubeconfig files under repo kubeconfigs/prod/."
  type        = bool
  default     = true
}
