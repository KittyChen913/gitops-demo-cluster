variable "openvpn_server_label" {
  description = "OpenVPN Linode label。"
  type        = string
  default     = "openvpn-dev"
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
  default     = ["gitops-demo", "dev", "openvpn"]
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

variable "openvpn_tunnel_cidr" {
  description = "Access Server VPN client IPv4 CIDR；採用官方預設位址池。"
  type        = string
  default     = "172.27.224.0/20"

  validation {
    condition     = can(cidrnetmask(var.openvpn_tunnel_cidr))
    error_message = "openvpn_tunnel_cidr 必須是有效 IPv4 CIDR。"
  }
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

variable "internal_domain" {
  description = "VPN-only DNS zone。"
  type        = string
  default     = "dev.gitops.internal"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", var.internal_domain))
    error_message = "internal_domain 必須是小寫 FQDN。"
  }
}

variable "argocd_endpoint_port" {
  description = "Argo CD restricted endpoint HTTPS port。"
  type        = number
  default     = 443

  validation {
    condition     = var.argocd_endpoint_port >= 1 && var.argocd_endpoint_port <= 65535
    error_message = "argocd_endpoint_port 必須介於 1 與 65535。"
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

variable "upstream_dns_servers" {
  description = "dnsmasq 的明確 upstream DNS servers。"
  type        = list(string)
  default     = ["1.1.1.1", "1.0.0.1"]

  validation {
    condition = length(var.upstream_dns_servers) > 0 && alltrue([
      for address in var.upstream_dns_servers : can(cidrnetmask("${address}/32"))
    ])
    error_message = "upstream_dns_servers 必須是非空的 IPv4 address list。"
  }
}

variable "openvpn_as_route_index" {
  description = "Access Server private-network route slot；若 slot 已被其他 CIDR 使用，Ansible 會停止。"
  type        = number
  default     = 99

  validation {
    condition     = var.openvpn_as_route_index >= 0 && var.openvpn_as_route_index <= 999 && floor(var.openvpn_as_route_index) == var.openvpn_as_route_index
    error_message = "openvpn_as_route_index 必須是 0 至 999 的整數。"
  }
}
