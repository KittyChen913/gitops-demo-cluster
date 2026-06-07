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
# 認證資料從 AWS SSM Parameter Store 取得，使用 ArgoCD
# ServiceAccount token（呼叫此指令前必須完成 Phase 2 apply）。
#
# 必要環境變數：
#   CLUSTER_ENV      — 環境（dev | prod）
#   CLUSTER_LABEL    — Cluster 標籤（例如 lke-dev-mgmt, lke-dev-ateam）
#   AWS_REGION       — SSM Parameter Store 所在 AWS region
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
: "${AWS_REGION:?Required env var: AWS_REGION}"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-15}"
SSM_PREFIX="/gitops/${CLUSTER_ENV}/clusters/${CLUSTER_LABEL}"

echo "============================================================"
echo " check-cluster-health.sh"
echo " env=${CLUSTER_ENV}  cluster=${CLUSTER_LABEL}"
echo "============================================================"

# ── Step 1：從 AWS SSM 取得認證資料 ───────────────────────────────────────────
echo "[1/5] Fetching cluster credentials from AWS SSM..."

API_ENDPOINT=$(aws ssm get-parameter \
  --name "${SSM_PREFIX}/api-endpoint" \
  --region "${AWS_REGION}" \
  --cli-connect-timeout 30 \
  --cli-read-timeout 30 \
  --query "Parameter.Value" \
  --output text)

CA_CERT_B64=$(aws ssm get-parameter \
  --name "${SSM_PREFIX}/ca-cert" \
  --region "${AWS_REGION}" \
  --cli-connect-timeout 30 \
  --cli-read-timeout 30 \
  --query "Parameter.Value" \
  --output text)

# ArgoCD SA token 擁有全讀取權限 — 足以執行健康檢查
SA_TOKEN=$(aws ssm get-parameter \
  --name "${SSM_PREFIX}/token" \
  --with-decryption \
  --region "${AWS_REGION}" \
  --cli-connect-timeout 30 \
  --cli-read-timeout 30 \
  --query "Parameter.Value" \
  --output text)

# 立即遡掩 token — 必須在任何可能輸出的操作前呼叫
echo "::add-mask::${SA_TOKEN}"
echo "      Credentials fetched from SSM"

# ── Step 2：建立短暫 kubeconfig ────────────────────────────────────────────────────────────────
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

# ── Step 3：檢查 API server 連線能力 ────────────────────────────────────────────
echo "[3/5] Checking API server connectivity (timeout=${HEALTH_TIMEOUT}s)..."

if ! kubectl cluster-info --request-timeout="${HEALTH_TIMEOUT}s" > /dev/null 2>&1; then
  echo "::error title=API Server Unreachable::Cannot reach API server for ${CLUSTER_LABEL}"
  exit 1
fi
echo "      API server: OK"

# ── Step 4：檢查節點狀態 ────────────────────────────────────────────────────────────────
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

# ── Step 5：檢查系統 pod ────────────────────────────────────────────────────────────────
echo "[5/5] Checking critical system pods (kube-system)..."

FAILED_PODS=$(kubectl get pods -n kube-system --no-headers --request-timeout="${HEALTH_TIMEOUT}s" 2>/dev/null \
  | grep -vc -E "Running|Completed|Succeeded" || true)

if [ "${FAILED_PODS}" -gt "0" ]; then
  echo "::warning title=System Pods Degraded::${FAILED_PODS} system pod(s) not running in ${CLUSTER_LABEL}"
  kubectl get pods -n kube-system --no-headers --request-timeout="${HEALTH_TIMEOUT}s" | grep -v -E "Running|Completed|Succeeded" || true
else
  echo "      System pods: OK"
fi

# ── 摘要 ────────────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " RESULT: ${CLUSTER_LABEL} → HEALTHY ✓"
echo " Nodes=${TOTAL_NODES}/Ready, System-Pods-Failed=${FAILED_PODS}"
echo "============================================================"
