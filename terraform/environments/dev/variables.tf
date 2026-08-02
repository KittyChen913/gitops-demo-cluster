variable "linode_token" {
  description = "Linode API token. Prefer LINODE_TOKEN env var; leave empty to use the environment."
  type        = string
  sensitive   = true
  default     = ""
}

variable "region" {
  description = "Linode region for all dev clusters."
  type        = string
  default     = "ap-south"
}

variable "k8s_version" {
  description = "Kubernetes version for all dev clusters."
  type        = string
  default     = "1.35"
}

variable "mgmt_node_type" {
  description = "Instance type for the Management Cluster node pool."
  type        = string
  default     = "g6-standard-2"
}

variable "mgmt_node_count" {
  description = "Node count for the Management Cluster."
  type        = number
  default     = 2
}

variable "worker_node_type" {
  description = "Default instance type for Worker Clusters."
  type        = string
  default     = "g6-standard-2"
}

variable "worker_node_count" {
  description = "Default node count for Worker Clusters."
  type        = number
  default     = 2
}

variable "write_kubeconfig_files" {
  description = "Write kubeconfig files under repo kubeconfigs/dev/."
  type        = bool
  default     = true
}

variable "aws_region" {
  description = "AWS region for SSM Parameter Store."
  type        = string
  default     = "ap-southeast-1"
}

variable "write_ssm_parameters" {
  description = "是否將 Cluster API endpoints 與 CA certificates 寫入 SSM。"
  type        = bool
  default     = true
}

variable "vpn_server_public_egress_ip" {
  description = "Platform Access 發布的 VPN Server public egress IPv4；由 CI 從 SSM canonical contract 注入。"
  type        = string

  validation {
    condition = (
      !strcontains(var.vpn_server_public_egress_ip, "/") &&
      can(cidrnetmask("${var.vpn_server_public_egress_ip}/32"))
    )
    error_message = "vpn_server_public_egress_ip must be a single IPv4 address without a CIDR suffix."
  }
}
