output "instance_id" {
  description = "OpenVPN Linode ID。"
  value       = linode_instance.openvpn.id
}

output "public_ipv4" {
  description = "OpenVPN Linode public IPv4。"
  value       = linode_instance.openvpn.ip_address
}

output "public_ipv6" {
  description = "OpenVPN Linode public IPv6 host address（不含 /128）。"
  value       = trimsuffix(linode_instance.openvpn.ipv6, "/128")
}

output "label" {
  description = "OpenVPN Linode label。"
  value       = linode_instance.openvpn.label
}

output "openvpn_port" {
  description = "OpenVPN listener port。"
  value       = var.openvpn_port
}

output "openvpn_protocol" {
  description = "OpenVPN listener protocol。"
  value       = var.openvpn_protocol
}
