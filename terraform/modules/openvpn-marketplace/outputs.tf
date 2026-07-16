output "instance_id" {
  description = "OpenVPN Linode ID。"
  value       = try(linode_instance.openvpn[0].id, null)
}

output "public_ipv4" {
  description = "OpenVPN Linode public IPv4。"
  value       = try(linode_instance.openvpn[0].ip_address, null)
}

output "public_ipv6" {
  description = "OpenVPN Linode public IPv6 host address（不含 /128）。"
  value       = try(trimsuffix(linode_instance.openvpn[0].ipv6, "/128"), null)
}

output "label" {
  description = "OpenVPN Linode label。"
  value       = try(linode_instance.openvpn[0].label, null)
}

output "firewall_id" {
  description = "OpenVPN Linode Firewall ID。"
  value       = try(linode_firewall.openvpn[0].id, null)
}
