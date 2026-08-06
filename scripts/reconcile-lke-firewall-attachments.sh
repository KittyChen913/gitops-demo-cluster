#!/usr/bin/env bash
# =============================================================================
# reconcile-lke-firewall-attachments.sh — 收斂 LKE replacement Node Firewall attachment
# =============================================================================
#
# 從目前 Terraform root 的非機密 outputs 取得 Cluster／Firewall ID，並只補上
# 缺少的 Linode attachment。既有與多餘 attachment 不在此腳本刪除，避免把
# 短暫的 LKE inventory 變動放大成破壞性操作。
#
# 必要環境變數：
#   LINODE_TOKEN — 由既有 SSM /gitops/shared/LINODE_TOKEN 注入
#
# 選填：
#   LINODE_API_BASE — 測試用 API base URL；預設 https://api.linode.com/v4
# =============================================================================

set -euo pipefail

: "${LINODE_TOKEN:?Required env var: LINODE_TOKEN}"

LINODE_API_BASE="${LINODE_API_BASE:-https://api.linode.com/v4}"

for command_name in curl jq terraform; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  fi
done

CURL_CONFIG=$(umask 077 && mktemp /tmp/linode-curl.XXXXXX)
trap 'rm -f "${CURL_CONFIG}"' EXIT INT TERM

# Token 只寫入 Runner 的 0600 暫存設定，避免出現在 CLI argument 或 log。
printf 'header = "Authorization: Bearer %s"\n' "${LINODE_TOKEN}" > "${CURL_CONFIG}"
printf 'header = "Accept: application/json"\n' >> "${CURL_CONFIG}"

linode_api_get() {
  local api_path=$1
  curl --config "${CURL_CONFIG}" \
    --fail-with-body \
    --silent \
    --show-error \
    "${LINODE_API_BASE}${api_path}"
}

linode_api_post() {
  local api_path=$1
  local payload=$2
  curl --config "${CURL_CONFIG}" \
    --fail-with-body \
    --silent \
    --show-error \
    --request POST \
    --header "Content-Type: application/json" \
    --data "${payload}" \
    "${LINODE_API_BASE}${api_path}"
}

reconcile_firewall() {
  local cluster_id=$1
  local cluster_label=$2
  local firewall_id=$3
  local pool_response
  local firewall_response
  local device_response
  local node_ids
  local attached_ids
  local missing_ids

  if ! [[ "${cluster_id}" =~ ^[0-9]+$ && "${firewall_id}" =~ ^[0-9]+$ ]]; then
    echo "Cluster and Firewall IDs must be numeric for ${cluster_label}" >&2
    return 1
  fi

  firewall_response=$(linode_api_get "/networking/firewalls/${firewall_id}")
  if [ "$(jq -r '.status // empty' <<< "${firewall_response}")" != "enabled" ]; then
    echo "Firewall ${firewall_id} for ${cluster_label} is not enabled" >&2
    return 1
  fi

  pool_response=$(linode_api_get "/lke/clusters/${cluster_id}/pools?page_size=500")
  if ! jq -e '.data | type == "array"' <<< "${pool_response}" >/dev/null; then
    echo "LKE node pool response is invalid for ${cluster_label}" >&2
    return 1
  fi

  node_ids=$(jq -r '[.data[].nodes[]?.instance_id | select(. != null)] | unique | .[]' \
    <<< "${pool_response}")
  if [ -z "${node_ids}" ]; then
    echo "No current LKE nodes found for ${cluster_label}" >&2
    return 1
  fi

  device_response=$(linode_api_get "/networking/firewalls/${firewall_id}/devices?page_size=500")
  if ! jq -e '.data | type == "array"' <<< "${device_response}" >/dev/null; then
    echo "Firewall device response is invalid for ${cluster_label}" >&2
    return 1
  fi

  attached_ids=$(jq -r '[.data[] | select(.entity.type == "linode") | .entity.id] | unique | .[]' \
    <<< "${device_response}")
  missing_ids=$(jq -nr \
    --arg nodes "${node_ids}" \
    --arg attached "${attached_ids}" \
    '($nodes | split("\n") | map(select(length > 0))) -
     ($attached | split("\n") | map(select(length > 0))) | .[]')

  if [ -z "${missing_ids}" ]; then
    echo "Firewall attachments are current for ${cluster_label}"
    return 0
  fi

  while IFS= read -r node_id; do
    [ -n "${node_id}" ] || continue
    linode_api_post \
      "/networking/firewalls/${firewall_id}/devices" \
      "$(jq -cn --argjson id "${node_id}" '{type: "linode", id: $id}')" \
      >/dev/null
    echo "Attached replacement node ${node_id} to Firewall ${firewall_id} for ${cluster_label}"
  done <<< "${missing_ids}"

  device_response=$(linode_api_get "/networking/firewalls/${firewall_id}/devices?page_size=500")
  attached_ids=$(jq -r '[.data[] | select(.entity.type == "linode") | .entity.id] | unique | .[]' \
    <<< "${device_response}")
  missing_ids=$(jq -nr \
    --arg nodes "${node_ids}" \
    --arg attached "${attached_ids}" \
    '($nodes | split("\n") | map(select(length > 0))) -
     ($attached | split("\n") | map(select(length > 0))) | .[]')

  if [ -n "${missing_ids}" ]; then
    echo "Firewall attachment verification failed for ${cluster_label}" >&2
    return 1
  fi
}

management_cluster=$(terraform output -json management_cluster)
worker_clusters=$(terraform output -json worker_clusters)

targets=$(jq -cn \
  --argjson management "${management_cluster}" \
  --argjson workers "${worker_clusters}" \
  '[
    ($management | select(.firewall_active == true) | {
      cluster_id: .id,
      cluster_label: .label,
      firewall_id: .firewall_id
    })
  ] + [
    $workers[] |
    select(.firewall_active == true) |
    {
      cluster_id: .id,
      cluster_label: .label,
      firewall_id: .firewall_id
    }
  ]')

target_count=$(jq 'length' <<< "${targets}")
if [ "${target_count}" -eq 0 ]; then
  echo "No active Cluster Firewalls require reconciliation"
  exit 0
fi

while IFS= read -r target; do
  reconcile_firewall \
    "$(jq -r '.cluster_id' <<< "${target}")" \
    "$(jq -r '.cluster_label' <<< "${target}")" \
    "$(jq -r '.firewall_id' <<< "${target}")"
done < <(jq -c '.[]' <<< "${targets}")

echo "Reconciled Firewall attachments for ${target_count} Cluster(s)"
