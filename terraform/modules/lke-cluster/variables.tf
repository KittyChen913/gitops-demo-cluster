variable "label" {
  description = "LKE cluster label (e.g. lke-dev-mgmt)."
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes version in major.minor format (e.g. 1.32)."
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
  description = "Team identifier for worker clusters (e.g. ATeam). Omit for management clusters."
  type        = string
  default     = null

  validation {
    condition     = var.team == null || var.cluster_role != "management"
    error_message = "team must not be set on management clusters."
  }
}

variable "node_pools" {
  description = "Node pool definitions for the cluster."
  type = list(object({
    type  = string
    count = number
    labels = optional(map(string), {})
    tags   = optional(list(string), [])
    autoscaler = optional(object({
      min = number
      max = number
    }))
  }))
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
