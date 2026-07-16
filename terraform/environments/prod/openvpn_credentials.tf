resource "random_password" "openvpn_root" {
  count = var.openvpn_enabled ? 1 : 0

  length           = 32
  special          = true
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
  override_special = "_%@-"
}

resource "tls_private_key" "openvpn_ssh" {
  count = var.openvpn_enabled ? 1 : 0

  algorithm = "ED25519"
}

resource "tls_private_key" "openvpn_host" {
  count = var.openvpn_enabled ? 1 : 0

  algorithm = "ED25519"
}

resource "aws_ssm_parameter" "openvpn_root_password" {
  count = var.openvpn_enabled && var.write_ssm_parameters ? 1 : 0

  name  = "/gitops/${local.environment}/openvpn/terraform/OPENVPN_ROOT_PASSWORD"
  type  = "SecureString"
  value = random_password.openvpn_root[0].result

  tags = {
    Environment = local.environment
    Component   = "openvpn"
    ManagedBy   = "terraform"
  }
}

resource "aws_ssm_parameter" "openvpn_ssh_private_key" {
  count = var.openvpn_enabled && var.write_ssm_parameters ? 1 : 0

  name  = "/gitops/${local.environment}/openvpn/ansible/OPENVPN_SSH_PRIVATE_KEY_B64"
  type  = "SecureString"
  value = base64encode(tls_private_key.openvpn_ssh[0].private_key_openssh)

  tags = {
    Environment = local.environment
    Component   = "openvpn"
    ManagedBy   = "terraform"
  }
}

resource "aws_ssm_parameter" "openvpn_ssh_host_key" {
  count = var.openvpn_enabled && var.write_ssm_parameters ? 1 : 0

  name  = "/gitops/${local.environment}/openvpn/ansible/OPENVPN_SSH_HOST_KEY"
  type  = "String"
  value = trimspace(tls_private_key.openvpn_host[0].public_key_openssh)

  tags = {
    Environment = local.environment
    Component   = "openvpn"
    ManagedBy   = "terraform"
  }
}
