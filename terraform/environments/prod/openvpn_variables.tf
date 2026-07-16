variable "openvpn_enabled" {
  description = "是否建立 prod Marketplace OpenVPN Server。預設關閉，避免未啟用環境產生額外資源與費用。"
  type        = bool
  default     = false
}

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

variable "openvpn_image" {
  description = "Marketplace OpenVPN StackScript 支援的 image。"
  type        = string
  default     = "linode/ubuntu24.04"
}

variable "openvpn_stackscript_id" {
  description = "OpenVPN One-Click StackScript ID；部署前須以 Linode API 重新驗證。"
  type        = number
  default     = 401719
}

variable "openvpn_stackscript_data" {
  description = "非機密 Marketplace UDF；只允許 user_name、disable_root、soa_email_address 與 add_ons。"
  type        = map(string)
  default     = {}
}

variable "openvpn_tags" {
  description = "OpenVPN Linode 與 Firewall tags。"
  type        = list(string)
  default     = ["gitops-demo", "prod", "openvpn"]
}

variable "openvpn_port" {
  description = "OpenVPN client listener port；目前 Marketplace contract 固定為 UDP/1194。"
  type        = number
  default     = 1194

  validation {
    condition     = var.openvpn_port == 1194
    error_message = "目前 openvpn_port 必須是 1194；變更前需同步實作 Access Server sacli listener 設定。"
  }
}

variable "openvpn_protocol" {
  description = "OpenVPN client listener protocol；目前 Marketplace contract 固定為 udp。"
  type        = string
  default     = "udp"

  validation {
    condition     = var.openvpn_protocol == "udp"
    error_message = "目前 openvpn_protocol 必須是 udp；尚未實作 TCP listener 的 sacli 設定。"
  }
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
  description = "Access Server 目前配置的 VPN client IPv4 CIDR；Ansible 只驗證，不改寫 core VPN subnet。"
  type        = string
  default     = ""

  validation {
    condition     = !var.openvpn_enabled || can(cidrnetmask(var.openvpn_tunnel_cidr))
    error_message = "啟用 OpenVPN 時，openvpn_tunnel_cidr 必須是有效 IPv4 CIDR。"
  }
}

variable "openvpn_server_tunnel_ip" {
  description = "Access Server tunnel interface IPv4，也是 dnsmasq 的 VPN-only listener。"
  type        = string
  default     = ""

  validation {
    condition     = !var.openvpn_enabled || can(cidrnetmask("${var.openvpn_server_tunnel_ip}/32"))
    error_message = "啟用 OpenVPN 時，openvpn_server_tunnel_ip 必須是未帶 CIDR suffix 的 IPv4。"
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
  default     = ""

  validation {
    condition     = !var.openvpn_enabled || can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", var.internal_domain))
    error_message = "啟用 OpenVPN 時，internal_domain 必須是小寫 FQDN。"
  }
}

variable "internal_dns_server_ip" {
  description = "dnsmasq 的 VPN-only IPv4 listener。"
  type        = string
  default     = ""

  validation {
    condition     = !var.openvpn_enabled || can(cidrnetmask("${var.internal_dns_server_ip}/32"))
    error_message = "啟用 OpenVPN 時，internal_dns_server_ip 必須是未帶 CIDR suffix 的 IPv4。"
  }
}

variable "argocd_internal_fqdn" {
  description = "VPN client 使用的 Argo CD internal FQDN。"
  type        = string
  default     = ""

  validation {
    condition     = !var.openvpn_enabled || can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", var.argocd_internal_fqdn))
    error_message = "啟用 OpenVPN 時，argocd_internal_fqdn 必須是小寫 FQDN。"
  }
}

variable "argocd_endpoint_host" {
  description = "受 Cloud Firewall 限制的 Argo CD NodeBalancer IPv4。"
  type        = string
  default     = ""

  validation {
    condition     = !var.openvpn_enabled || can(cidrnetmask("${var.argocd_endpoint_host}/32"))
    error_message = "啟用 OpenVPN 時，argocd_endpoint_host 必須是未帶 CIDR suffix 的 IPv4。"
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

variable "argocd_destination_cidr" {
  description = "Access Server 推送的 Argo CD split-tunnel route；必須等於 argocd_endpoint_host/32。"
  type        = string
  default     = ""

  validation {
    condition     = !var.openvpn_enabled || can(cidrnetmask(var.argocd_destination_cidr))
    error_message = "啟用 OpenVPN 時，argocd_destination_cidr 必須是有效 IPv4 CIDR。"
  }
}

variable "trusted_admin_cidrs" {
  description = "允許 SSH 與 Access Server Admin UI 的可信來源 CIDR。"
  type        = list(string)
  default     = []

  validation {
    condition = !var.openvpn_enabled || (
      length(var.trusted_admin_cidrs) > 0 && alltrue([
        for cidr in var.trusted_admin_cidrs : can(cidrhost(cidr, 0)) && !contains(["0.0.0.0/0", "::/0"], cidr)
      ])
    )
    error_message = "啟用 OpenVPN 時，trusted_admin_cidrs 必須包含至少一個有效且非全開的 CIDR。"
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
