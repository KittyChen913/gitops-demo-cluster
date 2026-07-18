variable "openvpn_server_label" {
  description = "OpenVPN Linode label。"
  type        = string
  default     = "openvpn-prod"
}

variable "openvpn_instance_type" {
  description = "OpenVPN Linode instance type。"
  type        = string
  default     = "g6-standard-1"
}

variable "openvpn_stackscript_id" {
  description = "OpenVPN One-Click StackScript ID；部署前須以 Linode API 重新驗證。"
  type        = number
  default     = 401719
}

variable "openvpn_admin_username" {
  description = "Marketplace 建立的受限 sudo 使用者名稱。"
  type        = string
  default     = "vpnadmin"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.openvpn_admin_username))
    error_message = "openvpn_admin_username 必須是有效的小寫 Linux 使用者名稱。"
  }
}

variable "openvpn_contact_email" {
  description = "Marketplace Let's Encrypt bootstrap 使用的聯絡信箱；CI 從 SSM /gitops/shared/OPENVPN_CONTACT_EMAIL 注入。"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.openvpn_contact_email))
    error_message = "openvpn_contact_email 必須是有效的 email address。"
  }
}

variable "openvpn_tags" {
  description = "OpenVPN Linode 與 Firewall tags。"
  type        = list(string)
  default     = ["gitops-demo", "prod", "openvpn"]
}

variable "openvpn_enable_ipv6" {
  description = "是否對 IPv6 開放 OpenVPN listener。"
  type        = bool
  default     = false
}

variable "openvpn_bootstrap_http_enabled" {
  description = "是否暫時開放 Marketplace certbot 所需 TCP/80；healthy 後必須改回 false 並 apply。"
  type        = bool
  default     = false
}

variable "openvpn_admin_port" {
  description = "OpenVPN Access Server Admin/Client Web UI port。"
  type        = number
  default     = 943
}

variable "openvpn_public_ipv4" {
  description = "選用的預期 public IPv4；只核對 instance 實際位址，不會保留、配置或重新附加 IP。"
  type        = string
  default     = null

  validation {
    condition     = var.openvpn_public_ipv4 == null ? true : can(cidrnetmask("${var.openvpn_public_ipv4}/32"))
    error_message = "openvpn_public_ipv4 必須是 null 或未帶 CIDR suffix 的 IPv4。"
  }
}

variable "trusted_admin_cidrs" {
  description = "僅供 workflow 暫時注入 GitHub runner /32；穩態必須為空，請勿寫入 terraform.tfvars。"
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.trusted_admin_cidrs : can(cidrhost(cidr, 0)) && !contains(["0.0.0.0/0", "::/0"], cidr)
    ])
    error_message = "trusted_admin_cidrs 只能包含有效且非全開的 CIDR。"
  }
}

locals {
  openvpn_stackscript_data = {
    user_name         = var.openvpn_admin_username
    disable_root      = "Yes"
    soa_email_address = var.openvpn_contact_email
    add_ons           = "none"
  }
}

resource "random_password" "openvpn_root" {
  length           = 32
  special          = true
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
  override_special = "_%@-"
}

resource "tls_private_key" "openvpn_ssh" {
  algorithm = "ED25519"
}

resource "tls_private_key" "openvpn_host" {
  algorithm = "ED25519"
}

module "openvpn" {
  source = "../../modules/openvpn-marketplace"

  label                  = var.openvpn_server_label
  region                 = var.region
  instance_type          = var.openvpn_instance_type
  stackscript_id         = var.openvpn_stackscript_id
  stackscript_data       = local.openvpn_stackscript_data
  root_password          = random_password.openvpn_root.result
  ssh_public_key         = tls_private_key.openvpn_ssh.public_key_openssh
  ssh_host_private_key   = tls_private_key.openvpn_host.private_key_openssh
  ssh_host_public_key    = tls_private_key.openvpn_host.public_key_openssh
  tags                   = var.openvpn_tags
  enable_ipv6            = var.openvpn_enable_ipv6
  bootstrap_http_enabled = var.openvpn_bootstrap_http_enabled
  admin_port             = var.openvpn_admin_port
  trusted_admin_cidrs    = var.trusted_admin_cidrs
  expected_public_ipv4   = var.openvpn_public_ipv4
}

output "openvpn_instance_id" {
  description = "OpenVPN Linode ID。"
  value       = module.openvpn.instance_id
}

output "openvpn_public_ipv4" {
  description = "OpenVPN Linode public IPv4；供 Infra NodeBalancer allowlist 使用。"
  value       = module.openvpn.public_ipv4
}

output "openvpn_public_ipv6" {
  description = "OpenVPN Linode public IPv6 host address（不含 /128）。"
  value       = module.openvpn.public_ipv6
}

output "openvpn_label" {
  description = "OpenVPN Linode label。"
  value       = module.openvpn.label
}

output "openvpn_ssh_target" {
  description = "OpenVPN SSH target；不含 private key 或 password。"
  value = module.openvpn.public_ipv4 == null ? null : format(
    "%s@%s",
    var.openvpn_admin_username,
    module.openvpn.public_ipv4,
  )
}
