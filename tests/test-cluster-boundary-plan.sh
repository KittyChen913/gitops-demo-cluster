#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="${repo_root}/scripts/verify-cluster-boundary-plan.sh"
contract="${repo_root}/config/worker-firewall/dev.json"
tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

pass_count=0

expect_accept() {
  local name=$1
  local contract_path=$2
  local plan_path=$3

  if bash "${guard}" dev "${contract_path}" "${plan_path}" >/dev/null; then
    pass_count=$((pass_count + 1))
    return
  fi

  echo "FAIL: ${name} should be accepted" >&2
  exit 1
}

expect_reject() {
  local name=$1
  local contract_path=$2
  local plan_path=$3

  if bash "${guard}" dev "${contract_path}" "${plan_path}" >/dev/null 2>&1; then
    echo "FAIL: ${name} should be rejected" >&2
    exit 1
  fi

  pass_count=$((pass_count + 1))
}

cat >"${tmp_dir}/no-change.json" <<'JSON'
{
  "resource_changes": [
    {
      "address": "module.mgmt.linode_lke_cluster.this",
      "type": "linode_lke_cluster",
      "change": {
        "actions": ["no-op"],
        "before": {"control_plane": []},
        "after": {"control_plane": []}
      }
    }
  ]
}
JSON

cat >"${tmp_dir}/disabled-firewall-create.json" <<'JSON'
{
  "resource_changes": [
    {
      "address": "module.management_firewall.linode_firewall.workers[0]",
      "type": "linode_firewall",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": {}
      }
    }
  ]
}
JSON

cat >"${tmp_dir}/lke-delete.json" <<'JSON'
{
  "resource_changes": [
    {
      "address": "module.mgmt.linode_lke_cluster.this",
      "type": "linode_lke_cluster",
      "change": {
        "actions": ["delete"],
        "before": {"control_plane": []},
        "after": null
      }
    }
  ]
}
JSON

jq '
  .control_plane_acl = {
    "activation_enabled": true,
    "evidence_status": "VERIFIED",
    "required_runtime_evidence": ["vpn-egress-and-ci-route-verified"],
    "ipv4_addresses": ["203.0.113.10/32"],
    "ipv6_addresses": []
  }
' "${contract}" >"${tmp_dir}/active-acl-contract.json"

cat >"${tmp_dir}/active-acl.json" <<'JSON'
{
  "resource_changes": [
    {
      "address": "module.mgmt.linode_lke_cluster.this",
      "type": "linode_lke_cluster",
      "change": {
        "actions": ["update"],
        "before": {"control_plane": []},
        "after": {
          "control_plane": [
            {
              "acl": [
                {
                  "enabled": true,
                  "addresses": [
                    {
                      "ipv4": ["203.0.113.10/32"],
                      "ipv6": []
                    }
                  ]
                }
              ]
            }
          ]
        }
      }
    }
  ]
}
JSON

cat >"${tmp_dir}/disable-acl.json" <<'JSON'
{
  "resource_changes": [
    {
      "address": "module.mgmt.linode_lke_cluster.this",
      "type": "linode_lke_cluster",
      "change": {
        "actions": ["update"],
        "before": {
          "control_plane": [
            {"acl": [{"enabled": true, "addresses": [{"ipv4": ["203.0.113.10/32"]}]}]}
          ]
        },
        "after": {"control_plane": []}
      }
    }
  ]
}
JSON

jq '
  .clusters.management.activation_enabled = true |
  .clusters.management.evidence_status = "VERIFIED" |
  .clusters.management.required_runtime_evidence = ["management-runtime-verified"] |
  .clusters.management.inbound_rules = [{
    "label": "vpn-management",
    "protocol": "TCP",
    "ports": "443",
    "ipv4": ["10.8.0.0/24"],
    "ipv6": [],
    "purpose": "VPN-only management access",
    "evidence": "management-runtime-verified"
  }]
' "${contract}" >"${tmp_dir}/active-firewall-contract.json"

cat >"${tmp_dir}/active-firewall-create.json" <<'JSON'
{
  "resource_changes": [
    {
      "address": "module.management_firewall.linode_firewall.workers[0]",
      "type": "linode_firewall",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": {}
      }
    }
  ]
}
JSON

expect_accept "disabled boundary no-op" "${contract}" "${tmp_dir}/no-change.json"
expect_reject "disabled Firewall create" "${contract}" "${tmp_dir}/disabled-firewall-create.json"
expect_reject "LKE delete" "${contract}" "${tmp_dir}/lke-delete.json"
expect_accept "matching active ACL" "${tmp_dir}/active-acl-contract.json" "${tmp_dir}/active-acl.json"
expect_reject "ACL address mismatch" "${tmp_dir}/active-acl-contract.json" "${tmp_dir}/no-change.json"
expect_reject "ACL disable" "${contract}" "${tmp_dir}/disable-acl.json"
expect_accept "verified Management Firewall create" "${tmp_dir}/active-firewall-contract.json" "${tmp_dir}/active-firewall-create.json"

echo "PASS: ${pass_count} Cluster boundary guard cases"
