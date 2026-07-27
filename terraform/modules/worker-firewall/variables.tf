variable "environment" {
  description = "Environment owning this Cluster Firewall."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "cluster_label" {
  description = "LKE Cluster label."
  type        = string
}

variable "cluster_role" {
  description = "LKE Cluster role protected by this Firewall."
  type        = string

  validation {
    condition     = contains(["management", "worker"], var.cluster_role)
    error_message = "cluster_role must be management or worker."
  }
}

variable "firewall_label" {
  description = "Linode Firewall label."
  type        = string
}

variable "activation_enabled" {
  description = "Create and attach the Firewall only after runtime evidence is verified."
  type        = bool

  validation {
    condition     = !var.activation_enabled || var.evidence_status == "VERIFIED"
    error_message = "Cluster Firewall activation requires evidence_status=VERIFIED."
  }

  validation {
    condition     = !var.activation_enabled || length(var.required_runtime_evidence) > 0
    error_message = "Cluster Firewall activation requires recorded runtime evidence."
  }

  validation {
    condition     = !var.activation_enabled || length(var.inbound_rules) > 0
    error_message = "Cluster Firewall activation requires at least one evidence-backed inbound rule."
  }
}

variable "evidence_status" {
  description = "Runtime evidence status; only VERIFIED permits activation."
  type        = string

  validation {
    condition     = contains(["NOT_RUNTIME_VERIFIED", "VERIFIED"], var.evidence_status)
    error_message = "evidence_status must be NOT_RUNTIME_VERIFIED or VERIFIED."
  }
}

variable "required_runtime_evidence" {
  description = "Evidence identifiers supporting the active rule set."
  type        = list(string)
}

variable "node_instance_ids" {
  description = "Node Linode instance IDs derived from the LKE pool output."
  type        = list(number)
}

variable "inbound_policy" {
  description = "Cluster Firewall inbound policy."
  type        = string

  validation {
    condition     = var.inbound_policy == "DROP"
    error_message = "Cluster Firewall inbound policy must remain DROP."
  }
}

variable "outbound_policy" {
  description = "Cluster Firewall outbound policy."
  type        = string

  validation {
    condition     = var.outbound_policy == "ACCEPT"
    error_message = "Cluster Firewall outbound policy must remain ACCEPT."
  }
}

variable "inbound_rules" {
  description = "Evidence-backed inbound allow rules."
  type = list(object({
    label    = string
    protocol = string
    ports    = optional(string)
    ipv4     = optional(list(string), [])
    ipv6     = optional(list(string), [])
    purpose  = string
    evidence = string
  }))

  validation {
    condition = alltrue([
      for rule in var.inbound_rules :
      trimspace(rule.label) != "" &&
      contains(["TCP", "UDP", "ICMP", "IPENCAP"], upper(rule.protocol)) &&
      trimspace(rule.purpose) != "" &&
      trimspace(rule.evidence) != "" &&
      rule.evidence != "NOT_RUNTIME_VERIFIED" &&
      !contains(rule.ipv4, "0.0.0.0/0") &&
      !contains(rule.ipv6, "::/0")
    ])
    error_message = "Each rule requires a label, supported protocol, purpose, verified evidence, and non-global CIDRs."
  }
}
