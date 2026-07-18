locals {
  openvpn_server_tunnel_ip = cidrhost(var.openvpn_tunnel_cidr, 1)
  internal_dns_server_ip   = local.openvpn_server_tunnel_ip
  argocd_internal_fqdn     = "argocd.${var.internal_domain}"

  openvpn_network_ansible_config = {
    openvpn_host             = module.openvpn.public_ipv4
    openvpn_ssh_user         = var.openvpn_admin_username
    openvpn_tunnel_cidr      = var.openvpn_tunnel_cidr
    openvpn_server_tunnel_ip = local.openvpn_server_tunnel_ip
    internal_dns_server_ip   = local.internal_dns_server_ip
    internal_domain          = var.internal_domain
    argocd_internal_fqdn     = local.argocd_internal_fqdn
    argocd_endpoint_port     = var.argocd_endpoint_port
    upstream_dns_servers     = var.upstream_dns_servers
    openvpn_port             = module.openvpn.openvpn_port
    openvpn_protocol         = module.openvpn.openvpn_protocol
    openvpn_admin_port       = var.openvpn_admin_port
    openvpn_as_route_index   = var.openvpn_as_route_index
  }
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

output "internal_dns_server_ip" {
  description = "VPN client 使用的 internal DNS server。"
  value       = local.internal_dns_server_ip
}

output "argocd_internal_fqdn" {
  description = "VPN-only Argo CD FQDN。"
  value       = local.argocd_internal_fqdn
}

output "openvpn_network_ansible_config" {
  description = "Ansible 所需的非機密 OpenVPN network desired state；CI 直接從 Terraform state 讀取。"
  value       = local.openvpn_network_ansible_config
}
