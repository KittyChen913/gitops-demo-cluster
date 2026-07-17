locals {
  openvpn_server_tunnel_ip = cidrhost(var.openvpn_tunnel_cidr, 1)
  internal_dns_server_ip   = local.openvpn_server_tunnel_ip
  argocd_internal_fqdn     = "argocd.${var.internal_domain}"
  openvpn_stackscript_data = {
    user_name         = var.openvpn_admin_username
    disable_root      = "Yes"
    soa_email_address = var.openvpn_contact_email
    add_ons           = "none"
  }
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
  tags                   = var.openvpn_tags
  enable_ipv6            = var.openvpn_enable_ipv6
  bootstrap_http_enabled = var.openvpn_bootstrap_http_enabled
  admin_port             = var.openvpn_admin_port
  trusted_admin_cidrs    = var.trusted_admin_cidrs
  expected_public_ipv4   = var.openvpn_public_ipv4
}
