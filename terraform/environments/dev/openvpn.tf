module "openvpn" {
  source = "../../modules/openvpn-marketplace"

  enabled                = var.openvpn_enabled
  label                  = var.openvpn_server_label
  region                 = var.region
  instance_type          = var.openvpn_instance_type
  image                  = var.openvpn_image
  stackscript_id         = var.openvpn_stackscript_id
  stackscript_data       = var.openvpn_stackscript_data
  root_password          = try(random_password.openvpn_root[0].result, "")
  ssh_public_key         = try(tls_private_key.openvpn_ssh[0].public_key_openssh, "")
  ssh_host_private_key   = try(tls_private_key.openvpn_host[0].private_key_openssh, "")
  tags                   = var.openvpn_tags
  openvpn_port           = var.openvpn_port
  openvpn_protocol       = var.openvpn_protocol
  enable_ipv6            = var.openvpn_enable_ipv6
  bootstrap_http_enabled = var.openvpn_bootstrap_http_enabled
  admin_port             = var.openvpn_admin_port
  trusted_admin_cidrs    = var.trusted_admin_cidrs
  expected_public_ipv4   = var.openvpn_public_ipv4
}

check "openvpn_network_contract" {
  assert {
    condition = var.openvpn_enabled ? (
      var.internal_dns_server_ip == var.openvpn_server_tunnel_ip &&
      cidrcontains(var.openvpn_tunnel_cidr, var.openvpn_server_tunnel_ip) &&
      var.argocd_destination_cidr == "${var.argocd_endpoint_host}/32" &&
      var.argocd_internal_fqdn == "argocd.${var.internal_domain}"
    ) : true
    error_message = "OpenVPN network contract 無效：DNS IP 必須是 tunnel IP、IP 必須位於 tunnel CIDR、destination 必須等於 endpoint/32，且 FQDN 必須是 argocd.<internal_domain>。"
  }
}
