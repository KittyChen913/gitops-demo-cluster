#!/usr/bin/env bash
# 從 Phase 1 Terraform remote state 解析單一環境的 Cluster 標籤，並輸出供
# GitHub Actions matrix 使用的 JSON 陣列。日誌寫入 stderr，確保 stdout
# 維持機器可讀格式。
set -euo pipefail

: "${CLUSTER_ENV:?Required env var: CLUSTER_ENV (dev|prod)}"
DISCOVERY_OUTPUT_MODE="${DISCOVERY_OUTPUT_MODE:-labels}"

case "${CLUSTER_ENV}" in
  dev | prod) ;;
  *)
    echo "::error title=Invalid Environment::Expected dev or prod, got: ${CLUSTER_ENV}" >&2
    exit 1
    ;;
esac

case "${DISCOVERY_OUTPUT_MODE}" in
  labels | targets) ;;
  *)
    echo "::error title=Invalid Output Mode::Expected labels or targets, got: ${DISCOVERY_OUTPUT_MODE}" >&2
    exit 1
    ;;
esac

for REQUIRED_COMMAND in terraform jq; do
  if ! command -v "${REQUIRED_COMMAND}" >/dev/null 2>&1; then
    echo "::error title=Missing Command::${REQUIRED_COMMAND} is required for cluster discovery" >&2
    exit 1
  fi
done

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
TF_DIR="${REPO_ROOT}/terraform/environments/${CLUSTER_ENV}"

if [ ! -f "${TF_DIR}/backend.hcl" ]; then
  echo "::error title=Missing Backend Config::${TF_DIR}/backend.hcl does not exist" >&2
  exit 1
fi

echo "Loading cluster inventory from Terraform state: ${CLUSTER_ENV}/cluster_ids" >&2
if ! terraform -chdir="${TF_DIR}" init \
  -backend-config=backend.hcl \
  -reconfigure \
  -input=false \
  -lockfile=readonly \
  -no-color >&2; then
  echo "::error title=Terraform Init Failed::Unable to initialize Phase 1 state for ${CLUSTER_ENV}" >&2
  exit 1
fi

if ! INVENTORY_JSON=$(terraform -chdir="${TF_DIR}" output -json cluster_ids); then
  echo "::error title=Terraform Output Failed::Unable to read cluster_ids for ${CLUSTER_ENV}" >&2
  exit 1
fi

if ! jq -e 'type == "object"' <<< "${INVENTORY_JSON}" >/dev/null; then
  echo "::error title=Invalid Cluster Inventory::cluster_ids must be a JSON object" >&2
  exit 1
fi

mapfile -t STATE_LABELS < <(jq -r 'keys[]' <<< "${INVENTORY_JSON}")
if [ "${#STATE_LABELS[@]}" -eq 0 ]; then
  echo "::error title=No Clusters::Terraform state contains no clusters for ${CLUSTER_ENV}" >&2
  exit 1
fi

declare -A INVENTORY=()
for LABEL in "${STATE_LABELS[@]}"; do
  if [[ ! "${LABEL}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo "::error title=Invalid Cluster Label::Invalid cluster label in Terraform state: ${LABEL}" >&2
    exit 1
  fi
  INVENTORY["${LABEL}"]=1
done

if [ -n "${CLUSTER_LABELS:-}" ]; then
  mapfile -t LABELS < <(
    printf '%s\n' "${CLUSTER_LABELS}" \
      | tr '[:space:]' '\n' \
      | awk 'NF' \
      | sort -u
  )

  if [ "${#LABELS[@]}" -eq 0 ]; then
    echo "::error title=No Clusters::No cluster labels were requested" >&2
    exit 1
  fi

  for LABEL in "${LABELS[@]}"; do
    if [[ ! "${LABEL}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      echo "::error title=Invalid Cluster Label::Invalid requested cluster label: ${LABEL}" >&2
      exit 1
    fi
    if [[ -z "${INVENTORY[${LABEL}]+x}" ]]; then
      echo "::error title=Unknown Cluster::${LABEL} is not managed by the ${CLUSTER_ENV} Terraform state" >&2
      exit 1
    fi
  done
else
  LABELS=("${STATE_LABELS[@]}")
fi

if [ "${DISCOVERY_OUTPUT_MODE}" = "labels" ]; then
  printf '%s\n' "${LABELS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
  exit 0
fi

if ! EXPECTED_NODE_COUNTS_JSON=$(terraform -chdir="${TF_DIR}" output -json expected_node_counts); then
  echo "::error title=Terraform Output Failed::Unable to read expected_node_counts for ${CLUSTER_ENV}" >&2
  exit 1
fi

if ! jq -e \
  --argjson inventory "${INVENTORY_JSON}" \
  'type == "object" and
   all(to_entries[]; (.value | type) == "number" and .value > 0 and (.value | floor) == .value) and
   (keys | sort) == ($inventory | keys | sort)' \
  <<< "${EXPECTED_NODE_COUNTS_JSON}" >/dev/null; then
  echo "::error title=Invalid Node Count Inventory::expected_node_counts must contain one positive integer for every managed cluster" >&2
  exit 1
fi

REQUESTED_LABELS_JSON=$(printf '%s\n' "${LABELS[@]}" |
  jq -Rsc 'split("\n") | map(select(length > 0))')

jq -cn \
  --argjson labels "${REQUESTED_LABELS_JSON}" \
  --argjson counts "${EXPECTED_NODE_COUNTS_JSON}" \
  '$labels | map({cluster_label: ., expected_node_count: $counts[.]})'
