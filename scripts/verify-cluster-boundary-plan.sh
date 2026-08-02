#!/usr/bin/env bash
set -euo pipefail

reject() {
  echo "cluster boundary plan rejected: $*" >&2
  exit 1
}

if [[ $# -ne 4 ]]; then
  reject "usage: verify-cluster-boundary-plan.sh <environment> <contract.json> <plan.json> <vpn-server-cidr>"
fi

environment=$1
contract_path=$2
plan_path=$3
vpn_server_cidr=$4

validate_ipv4_32() {
  local cidr=$1
  local ip
  local octet
  local -a octets

  [[ "${cidr}" == */32 ]] || return 1
  ip=${cidr%/32}
  IFS='.' read -r -a octets <<<"${ip}"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    ((10#${octet} >= 0 && 10#${octet} <= 255)) || return 1
  done
}

command -v jq >/dev/null 2>&1 || reject "jq is required"
jq -e . "${contract_path}" >/dev/null || reject "invalid contract JSON"
jq -e . "${plan_path}" >/dev/null || reject "invalid plan JSON"
validate_ipv4_32 "${vpn_server_cidr}" ||
  reject "VPN Server source must be a single IPv4 /32"

[[ $(jq -r '.schema_version // 0' "${contract_path}") == "2" ]] ||
  reject "contract schema_version must be 2"
[[ $(jq -r '.environment // empty' "${contract_path}") == "${environment}" ]] ||
  reject "contract environment does not match workflow environment"
if [[ $(jq -r '.inbound_policy // empty' "${contract_path}") != "DROP" ]] ||
  [[ $(jq -r '.outbound_policy // empty' "${contract_path}") != "ACCEPT" ]]; then
  reject "policy must remain inbound DROP and outbound ACCEPT"
fi
[[ $(jq -r '.vpn_server.ssm_parameter_path // empty' "${contract_path}") == \
  "/gitops/platform-access/network/VPN_PUBLIC_EGRESS_IP" ]] ||
  reject "VPN Server source must use the Platform Access SSM canonical contract"

invalid_cluster=$(
  jq -r '
    [
      .clusters | to_entries[] |
      select(
        ((.value.firewall_label // "") == "") or
        ((.value.role // "") | IN("management", "worker") | not) or
        ((.key == "management") != (.value.role == "management")) or
        ((.value.evidence_status // "") | IN("NOT_RUNTIME_VERIFIED", "VERIFIED") | not)
      )
    ] |
    if length == 0 then empty else .[0].key end
  ' "${contract_path}"
)
[[ -z "${invalid_cluster}" ]] ||
  reject "cluster ${invalid_cluster} has an invalid boundary contract"

[[ $(jq -r '.clusters.management.role // empty' "${contract_path}") == "management" ]] ||
  reject "clusters.management with role=management is required"

invalid_rule=$(
  jq -r '
    [
      .clusters | to_entries[] as $cluster |
      $cluster.value.inbound_rules[]? |
      select(
        ((.label // "") == "") or
        ((.protocol // "" | ascii_upcase) | IN("TCP", "UDP", "ICMP", "IPENCAP") | not) or
        ((.purpose // "") == "") or
        ((.evidence // "") == "") or
        (.evidence == "NOT_RUNTIME_VERIFIED") or
        (
          ((.ipv4_source // "") != "") and
          ((.ipv4_source // "") != "platform_access_vpn_server")
        ) or
        (((.ipv4 // []) | index("0.0.0.0/0")) != null) or
        (((.ipv6 // []) | index("::/0")) != null)
      ) |
      {cluster: $cluster.key, label: (.label // "<missing>")}
    ] |
    if length == 0 then empty else "\(.[0].cluster)/\(.[0].label)" end
  ' "${contract_path}"
)
[[ -z "${invalid_rule}" ]] ||
  reject "rule ${invalid_rule} is unsafe or lacks verified evidence"

invalid_platform_source=$(
  jq -r '
    [
      .clusters | to_entries[] as $cluster |
      $cluster.value.inbound_rules[]? as $rule |
      ($rule.ipv4 // [])[]? |
      select(
        . != "192.168.128.0/17" and
        . != "192.168.255.0/24"
      ) |
      {cluster: $cluster.key, label: ($rule.label // "<missing>"), source: .}
    ] |
    if length == 0 then empty
    else "\(.[0].cluster)/\(.[0].label)=\(.[0].source)"
    end
  ' "${contract_path}"
)
[[ -z "${invalid_platform_source}" ]] ||
  reject "rule source is outside the approved LKE platform ranges: ${invalid_platform_source}"

invalid_activation=$(
  jq -r '
    [
      .clusters | to_entries[] |
      select(
        (.value.activation_enabled // false) and (
          (.value.evidence_status != "VERIFIED") or
          (((.value.required_runtime_evidence // []) | length) == 0) or
          (((.value.inbound_rules // []) | length) == 0)
        )
      )
    ] |
    if length == 0 then empty else .[0].key end
  ' "${contract_path}"
)
[[ -z "${invalid_activation}" ]] ||
  reject "cluster ${invalid_activation} activation requires VERIFIED evidence and inbound rules"

acl_unsafe_address=$(
  jq -r '
    (.control_plane_acl.ipv4_addresses // []) +
    (.control_plane_acl.ipv6_addresses // []) |
    map(select(. == "0.0.0.0/0" or . == "::/0")) |
    .[0] // empty
  ' "${contract_path}"
)
[[ -z "${acl_unsafe_address}" ]] ||
  reject "Control Plane ACL permits global Internet ingress: ${acl_unsafe_address}"

acl_activation_enabled=$(jq -r '.control_plane_acl.activation_enabled // false' "${contract_path}")
if [[ "${acl_activation_enabled}" == "true" ]]; then
  if [[ $(jq -r '.control_plane_acl.evidence_status // empty' "${contract_path}") != "VERIFIED" ]] ||
    [[ $(jq -r '(.control_plane_acl.required_runtime_evidence // []) | length' "${contract_path}") -le 0 ]] ||
    [[ $(jq -r '.control_plane_acl.ipv4_source // empty' "${contract_path}") != "platform_access_vpn_server" ]] ||
    [[ $(jq -r '(.control_plane_acl.ipv4_addresses // []) | length' "${contract_path}") -ne 0 ]] ||
    [[ $(jq -r '(.control_plane_acl.ipv6_addresses // []) | length' "${contract_path}") -ne 0 ]]; then
    reject "Control Plane ACL activation requires VERIFIED evidence and the dynamic VPN Server source only"
  fi
fi

lke_delete=$(
  jq -r '
    [
      .resource_changes[]? |
      select(
        .type == "linode_lke_cluster" and
        ((.change.actions // []) | index("delete") != null)
      )
    ] |
    if length == 0 then empty else (.[0].address // "<missing>") end
  ' "${plan_path}"
)
[[ -z "${lke_delete}" ]] ||
  reject "LKE delete/replace is forbidden: ${lke_delete}"

firewall_delete=$(
  jq -r '
    [
      .resource_changes[]? |
      select(
        .type == "linode_firewall" and
        (
          ((.address // "") | startswith("module.management_firewall.")) or
          ((.address // "") | startswith("module.worker_firewall["))
        ) and
        ((.change.actions // []) | index("delete") != null)
      )
    ] |
    if length == 0 then empty else (.[0].address // "<missing>") end
  ' "${plan_path}"
)
[[ -z "${firewall_delete}" ]] ||
  reject "Cluster Firewall delete/replace is forbidden: ${firewall_delete}"

while IFS=$'\t' read -r cluster_key cluster_role activation_enabled; do
  [[ -n "${cluster_key}" ]] || continue

  if [[ "${cluster_role}" == "management" ]]; then
    module_prefix="module.management_firewall."
  else
    module_prefix="module.worker_firewall[\"${cluster_key}\"]."
  fi

  if [[ "${activation_enabled}" == "false" ]]; then
    disabled_change=$(
      jq -r --arg module_prefix "${module_prefix}" '
        [
          .resource_changes[]? |
          select(
            ((.address // "") | startswith($module_prefix)) and
            ((.change.actions // []) != ["no-op"])
          )
        ] |
        if length == 0 then empty else (.[0].address // "<missing>") end
      ' "${plan_path}"
    )
    [[ -z "${disabled_change}" ]] ||
      reject "disabled Cluster Firewall contract has resource actions: ${disabled_change}"
  else
    expected_firewall_rules=$(
      jq -c \
        --arg cluster_key "${cluster_key}" \
        --arg vpn_server_cidr "${vpn_server_cidr}" '
        [
          .clusters[$cluster_key].inbound_rules[] |
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
        ] | sort_by(.label)
      ' "${contract_path}"
    )
    planned_firewall_rules=$(
      jq -c --arg module_prefix "${module_prefix}" '
        [
          .resource_changes[]? |
          select((.address // "") | startswith($module_prefix)) |
          .change.after.inbound[]? |
          {
            label: .label,
            action: .action,
            protocol: .protocol,
            ports: (.ports // null),
            ipv4: (.ipv4 // []),
            ipv6: (.ipv6 // [])
          }
        ] | sort_by(.label)
      ' "${plan_path}"
    )
    [[ "${planned_firewall_rules}" == "${expected_firewall_rules}" ]] ||
      reject "active Cluster Firewall ${cluster_key} rules do not match the VPN and LKE platform contract"
  fi
done < <(
  jq -r '
    .clusters | to_entries[] |
    [.key, .value.role, (.value.activation_enabled // false)] |
    @tsv
  ' "${contract_path}"
)

management_acl_before=$(
  jq -r '
    [
      .resource_changes[]? |
      select(.address == "module.mgmt.linode_lke_cluster.this") |
      .change.before.control_plane[]?.acl[]?.enabled
    ] |
    any(. == true)
  ' "${plan_path}"
)
management_acl_after=$(
  jq -r '
    [
      .resource_changes[]? |
      select(.address == "module.mgmt.linode_lke_cluster.this") |
      .change.after.control_plane[]?.acl[]?.enabled
    ] |
    any(. == true)
  ' "${plan_path}"
)

if [[ "${management_acl_before}" == "true" && "${management_acl_after}" != "true" ]]; then
  reject "disabling the Management Cluster Control Plane ACL is forbidden"
fi

if [[ "${acl_activation_enabled}" == "true" ]]; then
  [[ "${management_acl_after}" == "true" ]] ||
    reject "active Control Plane ACL contract is missing from the Management Cluster plan"

  expected_acl_addresses=$(
    jq -cn --arg vpn_server_cidr "${vpn_server_cidr}" \
      '[$vpn_server_cidr] | unique | sort'
  )
  planned_acl_addresses=$(
    jq -c '
      [
        .resource_changes[]? |
        select(.address == "module.mgmt.linode_lke_cluster.this") |
        .change.after.control_plane[]?.acl[]?.addresses[]? |
        ((.ipv4 // []) + (.ipv6 // []))[]
      ] | unique | sort
    ' "${plan_path}"
  )
  [[ "${planned_acl_addresses}" == "${expected_acl_addresses}" ]] ||
    reject "Management Cluster Control Plane ACL addresses do not match the contract"
elif [[ "${management_acl_after}" == "true" ]]; then
  reject "disabled Control Plane ACL contract cannot produce an enabled ACL"
fi

echo "cluster boundary plan accepted for ${environment}"
