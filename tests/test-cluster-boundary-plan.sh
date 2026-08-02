#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="${repo_root}/scripts/verify-cluster-boundary-plan.sh"
contract="${repo_root}/config/worker-firewall/dev.json"
vpn_server_cidr="203.0.113.10/32"
tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

pass_count=0

expect_accept() {
  local name=$1
  local contract_path=$2
  local plan_path=$3
  local vpn_cidr=${4:-${vpn_server_cidr}}

  if bash "${guard}" dev "${contract_path}" "${plan_path}" "${vpn_cidr}" >/dev/null; then
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
  local vpn_cidr=${4:-${vpn_server_cidr}}

  if bash "${guard}" dev "${contract_path}" "${plan_path}" "${vpn_cidr}" >/dev/null 2>&1; then
    echo "FAIL: ${name} should be rejected" >&2
    exit 1
  fi

  pass_count=$((pass_count + 1))
}

jq -n \
  --slurpfile contract "${contract}" \
  --arg vpn_server_cidr "${vpn_server_cidr}" '
  def firewall_rules($cluster_key):
    [
      $contract[0].clusters[$cluster_key].inbound_rules[] |
      {
        label: .label,
        action: "ACCEPT",
        protocol: (.protocol | ascii_upcase),
        ports: (.ports // null),
        ipv4: (
          if (.ipv4_source // "") == "platform_access_vpn_server"
          then [$vpn_server_cidr]
          else (.ipv4 // [])
          end
        ),
        ipv6: (.ipv6 // [])
      }
    ];
  {
    resource_changes: [
      {
        address: "module.mgmt.linode_lke_cluster.this",
        type: "linode_lke_cluster",
        change: {
          actions: ["create"],
          before: null,
          after: {
            control_plane: [
              {
                acl: [
                  {
                    enabled: true,
                    addresses: [
                      {ipv4: [$vpn_server_cidr], ipv6: []}
                    ]
                  }
                ]
              }
            ]
          }
        }
      },
      {
        address: "module.management_firewall.linode_firewall.workers[0]",
        type: "linode_firewall",
        change: {
          actions: ["create"],
          before: null,
          after: {inbound: firewall_rules("management")}
        }
      },
      {
        address: "module.worker_firewall[\"ateam\"].linode_firewall.workers[0]",
        type: "linode_firewall",
        change: {
          actions: ["create"],
          before: null,
          after: {inbound: firewall_rules("ateam")}
        }
      }
    ]
  }
' >"${tmp_dir}/active-boundary-create.json"

jq '
  .control_plane_acl.activation_enabled = false |
  .control_plane_acl.evidence_status = "NOT_RUNTIME_VERIFIED" |
  .control_plane_acl.ipv4_source = null |
  .clusters.management.activation_enabled = false |
  .clusters.management.evidence_status = "NOT_RUNTIME_VERIFIED" |
  .clusters.management.inbound_rules = [] |
  .clusters.ateam.activation_enabled = false |
  .clusters.ateam.evidence_status = "NOT_RUNTIME_VERIFIED" |
  .clusters.ateam.inbound_rules = []
' "${contract}" >"${tmp_dir}/disabled-contract.json"

cat >"${tmp_dir}/disabled-no-change.json" <<'JSON'
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
        "after": {"inbound": []}
      }
    }
  ]
}
JSON

jq '
  .resource_changes[0].change.actions = ["delete"] |
  .resource_changes[0].change.before = .resource_changes[0].change.after |
  .resource_changes[0].change.after = null
' "${tmp_dir}/active-boundary-create.json" >"${tmp_dir}/lke-delete.json"

jq '
  .resource_changes[0].change.after.control_plane[0].acl[0].addresses[0].ipv4 =
    ["198.51.100.10/32"]
' "${tmp_dir}/active-boundary-create.json" >"${tmp_dir}/acl-mismatch.json"

jq '
  .resource_changes[1].change.after.inbound[0].ipv4 = ["0.0.0.0/0"]
' "${tmp_dir}/active-boundary-create.json" >"${tmp_dir}/firewall-mismatch.json"

jq '
  .clusters.management.inbound_rules[0].ipv4_source = null |
  .clusters.management.inbound_rules[0].ipv4 = ["10.8.0.0/24"]
' "${contract}" >"${tmp_dir}/unapproved-source-contract.json"

expect_accept \
  "active LKE, Firewall and ACL create" \
  "${contract}" \
  "${tmp_dir}/active-boundary-create.json"
expect_accept \
  "disabled boundary no-op" \
  "${tmp_dir}/disabled-contract.json" \
  "${tmp_dir}/disabled-no-change.json"
expect_reject \
  "disabled Firewall create" \
  "${tmp_dir}/disabled-contract.json" \
  "${tmp_dir}/disabled-firewall-create.json"
expect_reject \
  "LKE delete" \
  "${contract}" \
  "${tmp_dir}/lke-delete.json"
expect_reject \
  "Control Plane ACL address mismatch" \
  "${contract}" \
  "${tmp_dir}/acl-mismatch.json"
expect_reject \
  "Cluster Firewall rule mismatch" \
  "${contract}" \
  "${tmp_dir}/firewall-mismatch.json"
expect_reject \
  "unapproved platform source" \
  "${tmp_dir}/unapproved-source-contract.json" \
  "${tmp_dir}/active-boundary-create.json"
expect_reject \
  "invalid VPN Server CIDR" \
  "${contract}" \
  "${tmp_dir}/active-boundary-create.json" \
  "203.0.113.0/24"

echo "PASS: ${pass_count} Cluster boundary guard cases"
