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

output "internal_dns_server_ip" {
  description = "VPN client 使用的 internal DNS server。"
  value       = local.internal_dns_server_ip
}

output "argocd_internal_fqdn" {
  description = "VPN-only Argo CD FQDN。"
  value       = local.argocd_internal_fqdn
}

output "openvpn_ansible_config" {
  description = "Ansible 所需的非機密 OpenVPN desired state；CI 直接從 Terraform state 讀取。"
  value = {
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
