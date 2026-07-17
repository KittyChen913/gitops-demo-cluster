#!/usr/bin/env bash
# =============================================================================
# check-cluster-health.sh — Kubernetes Cluster 健康檢查
# =============================================================================
#
# 驗證 Terraform 佈建後 cluster 是否正常運作：
#   1. API server 連線能力
#   2. 所有節點處於 Ready 狀態
#   3. 關鍵系統 pod 正常運行（kube-system）
#
# 認證資料由呼叫端從 AWS SSM Parameter Store 注入，使用 ArgoCD
# ServiceAccount token（呼叫此指令前必須完成 Phase 2 apply）。
#
# 必要環境變數：
#   CLUSTER_ENV      — 環境（dev | prod）
#   CLUSTER_LABEL    — Cluster 標籤（例如 lke-dev-mgmt, lke-dev-ateam）
#   API_ENDPOINT     — Cluster API 端點
#   CA_CERT          — Base64 編碼的 cluster CA
#   TOKEN            — ArgoCD ServiceAccount 權杖
#
# 選填：
#   HEALTH_TIMEOUT   — kubectl 請求逾時秒數（預設：15）
#
# 結束代碼：
#   0 — Cluster 健康
#   1 — Cluster 不健康或發生錯誤
# =============================================================================

set -euo pipefail

: "${CLUSTER_ENV:?Required env var: CLUSTER_ENV (dev|prod)}"
: "${CLUSTER_LABEL:?Required env var: CLUSTER_LABEL (e.g. lke-dev-mgmt)}"
: "${API_ENDPOINT:?Required env var: API_ENDPOINT}"
: "${CA_CERT:?Required env var: CA_CERT}"
: "${TOKEN:?Required env var: TOKEN}"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-15}"
CA_CERT_B64="${CA_CERT}"
SA_TOKEN="${TOKEN}"

echo "============================================================"
echo " check-cluster-health.sh"
echo " env=${CLUSTER_ENV}  cluster=${CLUSTER_LABEL}"
echo "============================================================"

# ── 步驟 1：確認呼叫端已載入認證資料 ─────────────────────────────────────────
echo "[1/5] Using cluster credentials loaded from AWS SSM..."
echo "::add-mask::${SA_TOKEN}"
echo "      Credentials available"

# ── 步驟 2：建立短暫 kubeconfig ────────────────────────────────────────────────────────────────
echo "[2/5] Building temporary kubeconfig..."
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

# ── 步驟 3：檢查 API server 連線能力 ────────────────────────────────────────────
echo "[3/5] Checking API server connectivity (timeout=${HEALTH_TIMEOUT}s)..."

if ! kubectl cluster-info --request-timeout="${HEALTH_TIMEOUT}s" > /dev/null 2>&1; then
  echo "::error title=API Server Unreachable::Cannot reach API server for ${CLUSTER_LABEL}"
  exit 1
fi
echo "      API server: OK"

# ── 步驟 4：檢查節點狀態 ────────────────────────────────────────────────────────────────
echo "[4/5] Checking node status..."

NODE_STATUS=$(kubectl get nodes --no-headers --request-timeout="${HEALTH_TIMEOUT}s" 2>/dev/null || echo "")
if [ -z "${NODE_STATUS}" ]; then
  echo "::error title=No Nodes::No nodes found in cluster ${CLUSTER_LABEL}"
  exit 1
fi

TOTAL_NODES=$(echo "${NODE_STATUS}" | wc -l | tr -d ' ')
NOT_READY=$(grep -vc -E "[[:space:]]Ready[[:space:]]" <<< "${NODE_STATUS}" || true)

echo "      Nodes: ${TOTAL_NODES} total, ${NOT_READY} not-ready"

if [ "${NOT_READY}" -gt "0" ]; then
  echo "::error title=Nodes Not Ready::${NOT_READY}/${TOTAL_NODES} node(s) not Ready in ${CLUSTER_LABEL}"
  echo ""
  echo "--- Node Status ---"
  kubectl get nodes --no-headers --request-timeout="${HEALTH_TIMEOUT}s" | grep -v -E "\sReady\s" || true
  echo "-------------------"
  exit 1
fi
echo "      All ${TOTAL_NODES} nodes are Ready"

# ── 步驟 5：檢查系統 pod ────────────────────────────────────────────────────────────────
echo "[5/5] Checking critical system pods (kube-system)..."

if ! SYSTEM_PODS=$(kubectl get pods -n kube-system --no-headers \
  --request-timeout="${HEALTH_TIMEOUT}s" 2>/dev/null); then
  echo "::error title=System Pod Query Failed::Unable to query kube-system pods in ${CLUSTER_LABEL}"
  exit 1
fi

FAILED_PODS=$(awk '$3 !~ /^(Running|Completed|Succeeded)$/ { count++ } END { print count + 0 }' \
  <<< "${SYSTEM_PODS}")

if [ "${FAILED_PODS}" -gt "0" ]; then
  echo "::error title=System Pods Degraded::${FAILED_PODS} system pod(s) not running in ${CLUSTER_LABEL}"
  awk '$3 !~ /^(Running|Completed|Succeeded)$/ { print }' <<< "${SYSTEM_PODS}"
  echo ""
  echo "============================================================"
  echo " RESULT: ${CLUSTER_LABEL} → UNHEALTHY ✗"
  echo " Nodes=${TOTAL_NODES}/Ready, System-Pods-Failed=${FAILED_PODS}"
  echo "============================================================"
  exit 1
fi
echo "      System pods: OK"

# ── 摘要 ────────────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " RESULT: ${CLUSTER_LABEL} → HEALTHY ✓"
echo " Nodes=${TOTAL_NODES}/Ready, System-Pods-Failed=${FAILED_PODS}"
echo "============================================================"
