variable "cluster_id" {
  description = "Target LKE cluster ID."
  type        = number
}

variable "type" {
  description = "Linode instance type for pool nodes."
  type        = string
}

variable "count" {
  description = "Number of nodes in the pool."
  type        = number
}

variable "labels" {
  description = "Kubernetes labels applied to nodes in this pool."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Linode tags applied to nodes in this pool."
  type        = list(string)
  default     = []
}

variable "autoscaler" {
  description = "Optional autoscaler configuration."
  type = object({
    min = number
    max = number
  })
  default = null
}
