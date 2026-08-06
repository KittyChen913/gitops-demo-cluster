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
#   EXPECTED_NODE_COUNT — Terraform desired state 中的 Node 數量
#
# 選填：
#   HEALTH_TIMEOUT                  — 單次 kubectl 請求逾時秒數（預設：15）
#   CLUSTER_STABILITY_WINDOW        — 必須連續健康的秒數（預設：300）
#   CLUSTER_STABILITY_TIMEOUT       — 等待穩定的總秒數（預設：900）
#   CLUSTER_STABILITY_POLL_INTERVAL — 取樣間隔秒數（預設：30）
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
: "${EXPECTED_NODE_COUNT:?Required env var: EXPECTED_NODE_COUNT}"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-15}"
CLUSTER_STABILITY_WINDOW="${CLUSTER_STABILITY_WINDOW:-300}"
CLUSTER_STABILITY_TIMEOUT="${CLUSTER_STABILITY_TIMEOUT:-900}"
CLUSTER_STABILITY_POLL_INTERVAL="${CLUSTER_STABILITY_POLL_INTERVAL:-30}"
CA_CERT_B64="${CA_CERT}"
SA_TOKEN="${TOKEN}"

for numeric_value in \
  "${HEALTH_TIMEOUT}" \
  "${CLUSTER_STABILITY_WINDOW}" \
  "${CLUSTER_STABILITY_TIMEOUT}" \
  "${CLUSTER_STABILITY_POLL_INTERVAL}"; do
  if ! [[ "${numeric_value}" =~ ^[0-9]+$ ]]; then
    echo "Health check timing values must be non-negative integers" >&2
    exit 1
  fi
done

if [ "${HEALTH_TIMEOUT}" -eq 0 ] || \
  [ "${CLUSTER_STABILITY_TIMEOUT}" -eq 0 ] || \
  [ "${CLUSTER_STABILITY_POLL_INTERVAL}" -eq 0 ] || \
  [ "${CLUSTER_STABILITY_WINDOW}" -gt "${CLUSTER_STABILITY_TIMEOUT}" ]; then
  echo "Health check timing values are inconsistent" >&2
  exit 1
fi

if ! [[ "${EXPECTED_NODE_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "EXPECTED_NODE_COUNT must be a positive integer" >&2
  exit 1
fi

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

# ── 步驟 3–5：等待 API、Node 與系統 Pod 連續穩定 ───────────────────────────────
echo "[3/5] Waiting for API server connectivity..."
echo "[4/5] Requiring a stable Ready node set..."
echo "[5/5] Requiring stable kube-system pods..."
echo "      Stability window=${CLUSTER_STABILITY_WINDOW}s, timeout=${CLUSTER_STABILITY_TIMEOUT}s"

START_TIME=$(date +%s)
DEADLINE=$((START_TIME + CLUSTER_STABILITY_TIMEOUT))
STABLE_SINCE=0
STABLE_NODE_SET=""
ATTEMPT=0
TOTAL_NODES=0
NOT_READY=0
FAILED_PODS=0
LAST_FAILURE="Cluster has not produced a health sample"

while true; do
  ATTEMPT=$((ATTEMPT + 1))
  NOW=$(date +%s)
  SAMPLE_HEALTHY=true
  NODE_STATUS=""
  SYSTEM_PODS=""

  if ! kubectl cluster-info --request-timeout="${HEALTH_TIMEOUT}s" >/dev/null 2>&1; then
    SAMPLE_HEALTHY=false
    LAST_FAILURE="API server is unreachable"
  elif ! NODE_STATUS=$(kubectl get nodes \
    --request-timeout="${HEALTH_TIMEOUT}s" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
    2>/dev/null); then
    SAMPLE_HEALTHY=false
    LAST_FAILURE="Node query failed"
  elif [ -z "${NODE_STATUS}" ]; then
    SAMPLE_HEALTHY=false
    LAST_FAILURE="No nodes were returned"
  else
    TOTAL_NODES=$(awk 'NF > 0 { count++ } END { print count + 0 }' <<< "${NODE_STATUS}")
    NOT_READY=$(awk -F '\t' '$2 != "True" { count++ } END { print count + 0 }' <<< "${NODE_STATUS}")
    CURRENT_NODE_SET=$(awk -F '\t' 'NF > 0 { print $1 }' <<< "${NODE_STATUS}" | sort | tr '\n' ',')

    if [ "${TOTAL_NODES}" -ne "${EXPECTED_NODE_COUNT}" ]; then
      SAMPLE_HEALTHY=false
      LAST_FAILURE="Expected ${EXPECTED_NODE_COUNT} nodes but found ${TOTAL_NODES}"
    elif [ "${NOT_READY}" -gt 0 ]; then
      SAMPLE_HEALTHY=false
      LAST_FAILURE="${NOT_READY}/${TOTAL_NODES} nodes are not Ready"
    elif ! SYSTEM_PODS=$(kubectl get pods -n kube-system --no-headers \
      --request-timeout="${HEALTH_TIMEOUT}s" 2>/dev/null); then
      SAMPLE_HEALTHY=false
      LAST_FAILURE="kube-system pod query failed"
    elif [ -z "${SYSTEM_PODS}" ]; then
      SAMPLE_HEALTHY=false
      LAST_FAILURE="No kube-system pods were returned"
    else
      FAILED_PODS=$(awk '$3 !~ /^(Running|Completed|Succeeded)$/ { count++ } END { print count + 0 }' \
        <<< "${SYSTEM_PODS}")
      if [ "${FAILED_PODS}" -gt 0 ]; then
        SAMPLE_HEALTHY=false
        LAST_FAILURE="${FAILED_PODS} kube-system pods are not healthy"
      fi
    fi
  fi

  if [ "${SAMPLE_HEALTHY}" = true ]; then
    if [ "${CURRENT_NODE_SET}" != "${STABLE_NODE_SET}" ]; then
      STABLE_NODE_SET="${CURRENT_NODE_SET}"
      STABLE_SINCE="${NOW}"
      echo "      Attempt ${ATTEMPT}: Ready node set changed; stability timer restarted"
    fi

    STABLE_FOR=$((NOW - STABLE_SINCE))
    if [ "${STABLE_FOR}" -ge "${CLUSTER_STABILITY_WINDOW}" ]; then
      echo "      Cluster remained healthy with the expected ${TOTAL_NODES} node(s) for ${STABLE_FOR}s"
      break
    fi
    LAST_FAILURE="Healthy sample has only been stable for ${STABLE_FOR}s"
  else
    STABLE_SINCE=0
    STABLE_NODE_SET=""
  fi

  if [ "${NOW}" -ge "${DEADLINE}" ]; then
    echo "::error title=Cluster Stability Timeout::${CLUSTER_LABEL} did not remain healthy for ${CLUSTER_STABILITY_WINDOW}s: ${LAST_FAILURE}"
    echo ""
    echo "--- Node Status ---"
    kubectl get nodes --request-timeout="${HEALTH_TIMEOUT}s" || true
    echo "--- Unhealthy kube-system Pods ---"
    kubectl get pods -n kube-system --no-headers --request-timeout="${HEALTH_TIMEOUT}s" 2>/dev/null |
      awk '$3 !~ /^(Running|Completed|Succeeded)$/ { print }' || true
    echo "-------------------"
    exit 1
  fi

  REMAINING=$((DEADLINE - NOW))
  echo "      Attempt ${ATTEMPT}: ${LAST_FAILURE}; ${REMAINING}s remaining"
  sleep "${CLUSTER_STABILITY_POLL_INTERVAL}"
done

# ── 摘要 ────────────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " RESULT: ${CLUSTER_LABEL} → HEALTHY ✓"
echo " Nodes=${TOTAL_NODES}/Ready, System-Pods-Failed=${FAILED_PODS}"
echo "============================================================"
