#!/usr/bin/env bash
# Cluster discovery desired Node 數量資料流的離線 regression test。

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT INT TERM

mkdir -p "${TEST_ROOT}/bin"

cat > "${TEST_ROOT}/bin/terraform" <<'MOCK_TERRAFORM'
#!/usr/bin/env bash
set -euo pipefail

if [ "${2:-}" = "init" ]; then
  exit 0
fi

if [ "${2:-}" = "output" ] && [ "${3:-}" = "-json" ]; then
  case "${4:-}" in
    cluster_ids)
      printf '%s\n' '{"lke-dev-ateam":202,"lke-dev-mgmt":101}'
      ;;
    expected_node_counts)
      printf '%s\n' '{"lke-dev-ateam":2,"lke-dev-mgmt":2}'
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi

echo "Unexpected terraform arguments: $*" >&2
exit 1
MOCK_TERRAFORM

chmod +x "${TEST_ROOT}/bin/terraform"

LABELS=$(PATH="${TEST_ROOT}/bin:${PATH}" \
  CLUSTER_ENV=dev \
  bash "${REPO_ROOT}/scripts/discover-clusters.sh")
jq -e '. == ["lke-dev-ateam", "lke-dev-mgmt"]' <<< "${LABELS}" >/dev/null

TARGETS=$(PATH="${TEST_ROOT}/bin:${PATH}" \
  CLUSTER_ENV=dev \
  CLUSTER_LABELS=lke-dev-mgmt \
  DISCOVERY_OUTPUT_MODE=targets \
  bash "${REPO_ROOT}/scripts/discover-clusters.sh")
jq -e '. == [{"cluster_label":"lke-dev-mgmt","expected_node_count":2}]' \
  <<< "${TARGETS}" >/dev/null

echo "Cluster discovery target tests passed"
