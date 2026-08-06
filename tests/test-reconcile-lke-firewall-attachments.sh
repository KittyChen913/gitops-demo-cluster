#!/usr/bin/env bash
# LKE Firewall attachment reconciliation 的離線 regression test。

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT INT TERM

mkdir -p "${TEST_ROOT}/bin"
POSTED_NODES="${TEST_ROOT}/posted-nodes"
touch "${POSTED_NODES}"

cat > "${TEST_ROOT}/bin/terraform" <<'MOCK_TERRAFORM'
#!/usr/bin/env bash
set -euo pipefail

case "${4:-${3:-${2:-}}}" in
  management_cluster)
    printf '%s\n' '{"id":641543,"label":"lke-dev-mgmt","firewall_id":109304417,"firewall_active":true}'
    ;;
  worker_clusters)
    printf '%s\n' '{}'
    ;;
  *)
    echo "Unexpected Terraform arguments: $*" >&2
    exit 1
    ;;
esac
MOCK_TERRAFORM

cat > "${TEST_ROOT}/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

url="${*: -1}"
method="GET"
payload=""
previous=""
for argument in "$@"; do
  if [ "${previous}" = "--request" ]; then
    method="${argument}"
  elif [ "${previous}" = "--data" ]; then
    payload="${argument}"
  fi
  previous="${argument}"
done

case "${method} ${url}" in
  "GET http://linode.test/v4/networking/firewalls/109304417")
    printf '%s\n' '{"id":109304417,"status":"enabled"}'
    ;;
  "GET http://linode.test/v4/lke/clusters/641543/pools?page_size=500")
    printf '%s\n' '{"data":[{"nodes":[{"instance_id":102381395},{"instance_id":102381772}]}]}'
    ;;
  "GET http://linode.test/v4/networking/firewalls/109304417/devices?page_size=500")
    if grep -qx '102381772' "${MOCK_POSTED_NODES}"; then
      printf '%s\n' '{"data":[{"entity":{"type":"linode","id":102381395}},{"entity":{"type":"linode","id":102381772}}]}'
    else
      printf '%s\n' '{"data":[{"entity":{"type":"linode","id":102381395}}]}'
    fi
    ;;
  "POST http://linode.test/v4/networking/firewalls/109304417/devices")
    jq -r '.id' <<< "${payload}" >> "${MOCK_POSTED_NODES}"
    printf '%s\n' '{"id":1}'
    ;;
  *)
    echo "Unexpected curl request: ${method} ${url}" >&2
    exit 1
    ;;
esac
MOCK_CURL

chmod +x "${TEST_ROOT}/bin/terraform" "${TEST_ROOT}/bin/curl"

PATH="${TEST_ROOT}/bin:${PATH}" \
  LINODE_TOKEN="test-token" \
  LINODE_API_BASE="http://linode.test/v4" \
  MOCK_POSTED_NODES="${POSTED_NODES}" \
  bash "${REPO_ROOT}/scripts/reconcile-lke-firewall-attachments.sh"

if [ "$(wc -l < "${POSTED_NODES}" | tr -d ' ')" -ne 1 ] || \
  ! grep -qx '102381772' "${POSTED_NODES}"; then
  echo "Expected exactly the missing replacement node to be attached" >&2
  exit 1
fi

PATH="${TEST_ROOT}/bin:${PATH}" \
  LINODE_TOKEN="test-token" \
  LINODE_API_BASE="http://linode.test/v4" \
  MOCK_POSTED_NODES="${POSTED_NODES}" \
  bash "${REPO_ROOT}/scripts/reconcile-lke-firewall-attachments.sh"

if [ "$(wc -l < "${POSTED_NODES}" | tr -d ' ')" -ne 1 ]; then
  echo "Idempotent reconciliation unexpectedly added another attachment" >&2
  exit 1
fi

echo "LKE Firewall attachment reconciliation tests passed"
