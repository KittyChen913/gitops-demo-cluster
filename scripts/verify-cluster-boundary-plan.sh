#!/usr/bin/env bash
set -euo pipefail

reject() {
  echo "cluster boundary plan rejected: $*" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  reject "usage: verify-cluster-boundary-plan.sh <environment> <contract.json> <plan.json>"
fi

environment=$1
contract_path=$2
plan_path=$3

command -v jq >/dev/null 2>&1 || reject "jq is required"
jq -e . "${contract_path}" >/dev/null || reject "invalid contract JSON"
jq -e . "${plan_path}" >/dev/null || reject "invalid plan JSON"

[[ $(jq -r '.schema_version // 0' "${contract_path}") == "2" ]] ||
  reject "contract schema_version must be 2"
[[ $(jq -r '.environment // empty' "${contract_path}") == "${environment}" ]] ||
  reject "contract environment does not match workflow environment"
if [[ $(jq -r '.inbound_policy // empty' "${contract_path}") != "DROP" ]] ||
  [[ $(jq -r '.outbound_policy // empty' "${contract_path}") != "ACCEPT" ]]; then
  reject "policy must remain inbound DROP and outbound ACCEPT"
fi

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
    [[ $(jq -r '((.control_plane_acl.ipv4_addresses // []) + (.control_plane_acl.ipv6_addresses // [])) | length' "${contract_path}") -le 0 ]]; then
    reject "Control Plane ACL activation requires VERIFIED evidence and at least one address"
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
  [[ "${activation_enabled}" == "false" ]] || continue

  if [[ "${cluster_role}" == "management" ]]; then
    module_prefix="module.management_firewall."
  else
    module_prefix="module.worker_firewall[\"${cluster_key}\"]."
  fi

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
    jq -c '
      (
        (.control_plane_acl.ipv4_addresses // []) +
        (.control_plane_acl.ipv6_addresses // [])
      ) | unique | sort
    ' "${contract_path}"
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
