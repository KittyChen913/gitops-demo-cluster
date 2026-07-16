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
    lookup(var.openvpn_stackscript_data, "user_name", "root"),
    module.openvpn.public_ipv4,
  )
}

output "internal_dns_server_ip" {
  description = "VPN client 使用的 internal DNS server。"
  value       = var.openvpn_enabled ? var.internal_dns_server_ip : null
}

output "argocd_internal_fqdn" {
  description = "VPN-only Argo CD FQDN。"
  value       = var.openvpn_enabled ? var.argocd_internal_fqdn : null
}

output "openvpn_ansible_config" {
  description = "Ansible 所需的非機密 OpenVPN desired state；CI 直接從 Terraform state 讀取。"
  value = var.openvpn_enabled ? {
    openvpn_host             = module.openvpn.public_ipv4
    openvpn_ssh_user         = lookup(var.openvpn_stackscript_data, "user_name", "root")
    openvpn_tunnel_cidr      = var.openvpn_tunnel_cidr
    openvpn_server_tunnel_ip = var.openvpn_server_tunnel_ip
    internal_dns_server_ip   = var.internal_dns_server_ip
    internal_domain          = var.internal_domain
    argocd_internal_fqdn     = var.argocd_internal_fqdn
    argocd_endpoint_host     = var.argocd_endpoint_host
    argocd_endpoint_port     = var.argocd_endpoint_port
    argocd_destination_cidr  = var.argocd_destination_cidr
    upstream_dns_servers     = var.upstream_dns_servers
    trusted_admin_cidrs      = var.trusted_admin_cidrs
    openvpn_port             = var.openvpn_port
    openvpn_protocol         = var.openvpn_protocol
    openvpn_admin_port       = var.openvpn_admin_port
    openvpn_as_route_index   = var.openvpn_as_route_index
  } : null
}
