#!/usr/bin/env bash
# Cluster stability window 的離線 regression test。

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT INT TERM

mkdir -p "${TEST_ROOT}/bin"

cat > "${TEST_ROOT}/bin/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "cluster-info" ]; then
  exit 0
fi

if [ "${1:-}" = "get" ] && [ "${2:-}" = "nodes" ]; then
  if [[ " $* " == *" jsonpath="* ]]; then
    call_count=0
    if [ -f "${MOCK_NODE_CALLS}" ]; then
      call_count=$(cat "${MOCK_NODE_CALLS}")
    fi
    call_count=$((call_count + 1))
    printf '%s' "${call_count}" > "${MOCK_NODE_CALLS}"

    if [ "${MOCK_MODE}" = "flapping" ] && [ $((call_count % 2)) -eq 0 ]; then
      printf 'node-b\tTrue\n'
    else
      printf 'node-a\tTrue\n'
    fi
  else
    printf 'node-a Ready\n'
  fi
  exit 0
fi

if [ "${1:-}" = "get" ] && [ "${2:-}" = "pods" ]; then
  printf 'kube-proxy-1 1/1 Running 0 1m\n'
  exit 0
fi

echo "Unexpected kubectl arguments: $*" >&2
exit 1
MOCK_KUBECTL

chmod +x "${TEST_ROOT}/bin/kubectl"

run_health_check() {
  local mode=$1
  local stability_window=$2
  local stability_timeout=$3
  local expected_node_count=${4:-1}
  local node_calls="${TEST_ROOT}/node-calls-${mode}"

  PATH="${TEST_ROOT}/bin:${PATH}" \
    CLUSTER_ENV="dev" \
    CLUSTER_LABEL="lke-dev-mgmt" \
    EXPECTED_NODE_COUNT="${expected_node_count}" \
    API_ENDPOINT="https://cluster.test:443" \
    CA_CERT="test-ca" \
    TOKEN="test-token" \
    MOCK_MODE="${mode}" \
    MOCK_NODE_CALLS="${node_calls}" \
    CLUSTER_STABILITY_WINDOW="${stability_window}" \
    CLUSTER_STABILITY_TIMEOUT="${stability_timeout}" \
    CLUSTER_STABILITY_POLL_INTERVAL="1" \
    bash "${REPO_ROOT}/scripts/check-cluster-health.sh"
}

run_health_check stable 1 4

if run_health_check flapping 2 3; then
  echo "A changing replacement node set unexpectedly passed stability validation" >&2
  exit 1
fi

if run_health_check stable 1 2 2; then
  echo "A cluster with fewer nodes than Terraform desired state unexpectedly passed" >&2
  exit 1
fi

echo "Cluster health stability tests passed"
