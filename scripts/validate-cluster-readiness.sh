#!/usr/bin/env bash
# =============================================================================
# validate-cluster-readiness.sh — 單一 Cluster 最終就緒驗證
# =============================================================================
#
# 認證資料由呼叫端從單一 cluster SSM path 載入。此 script 驗證：
#   1. 必要的 api-endpoint、ca-cert、token 皆已注入
#   2. API server 可透過 SA token 存取
#   3. SA token 具備預期的讀取權限
#   4. Cluster 至少有一個節點且所有節點 Ready
#
# 必要環境變數：
#   CLUSTER_ENV      — 環境（dev | prod）
#   CLUSTER_LABEL    — Cluster 標籤
#   API_ENDPOINT     — Cluster API 端點
#   CA_CERT          — Base64 編碼的 cluster CA
#   TOKEN            — ArgoCD ServiceAccount 權杖
# =============================================================================

set -euo pipefail

: "${CLUSTER_ENV:?Required env var: CLUSTER_ENV (dev|prod)}"
: "${CLUSTER_LABEL:?Required env var: CLUSTER_LABEL}"
: "${API_ENDPOINT:?Required env var: API_ENDPOINT}"
: "${CA_CERT:?Required env var: CA_CERT}"
: "${TOKEN:?Required env var: TOKEN}"

CA_CERT_B64="${CA_CERT}"
SA_TOKEN="${TOKEN}"
CLUSTER_FAILED=0

echo "============================================================"
echo " validate-cluster-readiness.sh"
echo " env=${CLUSTER_ENV}  cluster=${CLUSTER_LABEL}"
echo "============================================================"
echo "::add-mask::${SA_TOKEN}"

echo "[A] Cluster credentials loaded from AWS SSM: OK"

KUBECONFIG_FILE=$(umask 077 && mktemp /tmp/kubeconfig.XXXXXX)
trap 'rm -f "${KUBECONFIG_FILE}"; unset KUBECONFIG' EXIT INT TERM

cat > "${KUBECONFIG_FILE}" <<KUBECONFIG_EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_LABEL}
  cluster:
    server: ${API_ENDPOINT}
    certificate-authority-data: ${CA_CERT_B64}
contexts:
- name: ${CLUSTER_LABEL}
  context:
    cluster: ${CLUSTER_LABEL}
    user: argocd-manager
current-context: ${CLUSTER_LABEL}
users:
- name: argocd-manager
  user:
    token: ${SA_TOKEN}
KUBECONFIG_EOF

chmod 600 "${KUBECONFIG_FILE}"
export KUBECONFIG="${KUBECONFIG_FILE}"

echo "[B] Testing SA token connectivity..."
if ! kubectl auth can-i list nodes --request-timeout=10s > /dev/null 2>&1; then
  echo "::error title=Auth Failed::SA token cannot list nodes in ${CLUSTER_LABEL}"
  CLUSTER_FAILED=$((CLUSTER_FAILED + 1))
else
  echo "    SA token auth: OK"
fi

echo "[C] Spot-checking SA permissions..."
for RESOURCE in "pods" "deployments" "namespaces"; do
  if kubectl auth can-i list "${RESOURCE}" --request-timeout=10s > /dev/null 2>&1; then
    echo "    can-i list ${RESOURCE}: OK"
  else
    echo "::warning title=Permission::SA cannot list ${RESOURCE} in ${CLUSTER_LABEL}"
  fi
done

echo "[D] Checking node readiness..."
NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null || true)
if [ -z "${NODE_STATUS}" ]; then
  READY_COUNT=0
  TOTAL_COUNT=0
else
  READY_COUNT=$(grep -c -E "[[:space:]]Ready[[:space:]]" <<< "${NODE_STATUS}" || true)
  TOTAL_COUNT=$(wc -l <<< "${NODE_STATUS}" | tr -d ' ')
fi

if [ "${TOTAL_COUNT}" -eq 0 ] || [ "${READY_COUNT}" -lt "${TOTAL_COUNT}" ]; then
  echo "::error title=Nodes::${READY_COUNT}/${TOTAL_COUNT} nodes ready in ${CLUSTER_LABEL}"
  CLUSTER_FAILED=$((CLUSTER_FAILED + 1))
else
  echo "    Nodes ${READY_COUNT}/${TOTAL_COUNT} Ready: OK"
fi

echo ""
echo "============================================================"
if [ "${CLUSTER_FAILED}" -gt 0 ]; then
  echo " RESULT: ${CLUSTER_LABEL} → FAILED ✗ (${CLUSTER_FAILED} check(s))"
  echo "============================================================"
  exit 1
fi

echo " RESULT: ${CLUSTER_LABEL} → READY ✓"
echo "============================================================"
