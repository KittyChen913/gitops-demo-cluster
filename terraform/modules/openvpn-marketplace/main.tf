locals {
  marketplace_stackscript_data = merge(
    {
      disable_root = "Yes"
      add_ons      = "none"
    },
    var.stackscript_data,
  )
}

resource "linode_instance" "openvpn" {
  count = var.enabled ? 1 : 0

  label  = var.label
  region = var.region
  type   = var.instance_type
  image  = var.image

  root_pass        = var.root_password
  stackscript_id   = var.stackscript_id
  stackscript_data = local.marketplace_stackscript_data
  authorized_keys  = [var.ssh_public_key]
  firewall_id      = linode_firewall.openvpn[0].id
  tags             = var.tags

  metadata {
    user_data = base64encode(templatefile("${path.module}/templates/cloud-config.yaml.tftpl", {
      ssh_host_private_key_b64 = base64encode(var.ssh_host_private_key)
    }))
  }

  lifecycle {
    precondition {
      condition = (
        length(var.root_password) >= 16 &&
        trimspace(var.ssh_public_key) != "" &&
        trimspace(var.ssh_host_private_key) != "" &&
        can(regex("^[a-z_][a-z0-9_-]{0,31}$", lookup(var.stackscript_data, "user_name", ""))) &&
        can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", lookup(var.stackscript_data, "soa_email_address", ""))) &&
        local.marketplace_stackscript_data.disable_root == "Yes"
      )
      error_message = "啟用 OpenVPN 時，Terraform 必須提供至少 16 字元 root password、SSH user/host keys、user_name 與 soa_email_address，並保持 disable_root=Yes。"
    }

    postcondition {
      condition     = var.expected_public_ipv4 == null || self.ip_address == var.expected_public_ipv4
      error_message = "OpenVPN Linode 取得的 public IPv4 與 expected_public_ipv4 不同；不得繼續發布 allowlist 或 internal DNS。"
    }
  }
}

resource "linode_firewall" "openvpn" {
  count = var.enabled ? 1 : 0

  label           = "${var.label}-firewall"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
  tags            = var.tags

  inbound {
    label    = "allow-openvpn-clients"
    action   = "ACCEPT"
    protocol = upper(var.openvpn_protocol)
    ports    = tostring(var.openvpn_port)
    ipv4     = ["0.0.0.0/0"]
    ipv6     = var.enable_ipv6 ? ["::/0"] : []
  }

  dynamic "inbound" {
    for_each = var.bootstrap_http_enabled ? [1] : []

    content {
      label    = "allow-certbot-bootstrap"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = "80"
      ipv4     = ["0.0.0.0/0"]
      ipv6     = var.enable_ipv6 ? ["::/0"] : []
    }
  }

  inbound {
    label    = "allow-ssh-from-trusted-admins"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = [for cidr in var.trusted_admin_cidrs : cidr if !strcontains(cidr, ":")]
    ipv6     = [for cidr in var.trusted_admin_cidrs : cidr if strcontains(cidr, ":")]
  }

  inbound {
    label    = "allow-access-server-admin"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = tostring(var.admin_port)
    ipv4     = [for cidr in var.trusted_admin_cidrs : cidr if !strcontains(cidr, ":")]
    ipv6     = [for cidr in var.trusted_admin_cidrs : cidr if strcontains(cidr, ":")]
  }
}
