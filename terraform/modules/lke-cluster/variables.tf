variable "label" {
  description = "LKE cluster label (e.g. lke-dev-mgmt)."
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes version in major.minor format."
  type        = string
}

variable "region" {
  description = "Linode region slug (e.g. us-ord, ap-west)."
  type        = string
}

variable "env" {
  description = "Environment name embedded in tags and node labels (dev or prod)."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env must be dev or prod."
  }
}

variable "cluster_role" {
  description = "Cluster role: management or worker."
  type        = string

  validation {
    condition     = contains(["management", "worker"], var.cluster_role)
    error_message = "cluster_role must be management or worker."
  }
}

variable "team" {
  description = "Team identifier for Worker Clusters (e.g. ATeam). Omit for Management Clusters."
  type        = string
  default     = null

  validation {
    condition     = var.team == null || var.cluster_role != "management"
    error_message = "team must not be set on Management Clusters."
  }
}

variable "node_pools" {
  description = "Node pool definitions for the cluster."
  type = list(object({
    type   = string
    count  = number
    labels = optional(map(string), {})
    tags   = optional(list(string), [])
    autoscaler = optional(object({
      min = number
      max = number
    }))
  }))
}

variable "control_plane_acl" {
  description = "Optional LKE Control Plane ACL. Use null until VPN access evidence is verified."
  type = object({
    enabled        = bool
    ipv4_addresses = set(string)
    ipv6_addresses = optional(set(string), [])
  })
  default = null

  validation {
    # && / || 在 HCL 不會 short-circuit，兩側運算元都會被求值；
    # 若右側對 null 值取屬性會直接報錯，因此改用三元運算式讓未選中的分支不被求值。
    condition = var.control_plane_acl == null ? true : (
      var.control_plane_acl.enabled &&
      length(setunion(
        var.control_plane_acl.ipv4_addresses,
        var.control_plane_acl.ipv6_addresses
      )) > 0 &&
      !contains(var.control_plane_acl.ipv4_addresses, "0.0.0.0/0") &&
      !contains(var.control_plane_acl.ipv6_addresses, "::/0")
    )
    error_message = "control_plane_acl must be null or enabled with at least one non-global CIDR."
  }
}

variable "tags" {
  description = "Additional Linode tags applied to the cluster."
  type        = list(string)
  default     = []
}

variable "write_kubeconfig" {
  description = "Write decoded kubeconfig to a local file via the local provider."
  type        = bool
  default     = false
}

variable "kubeconfig_path" {
  description = "Destination path when write_kubeconfig is true."
  type        = string
  default     = ""
}
