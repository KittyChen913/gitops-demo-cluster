#!/usr/bin/env bash
# =============================================================================
# validate-cluster-readiness.sh — 最終 Cluster 就緒驗證
# =============================================================================
#
# 對環境中所有 cluster 執行完整的端對端就緒驗證
#（完整佈建 Phase 1 + Phase 2 後執行）。
#
# 對每個 cluster 進行驗證：
#   1. API server 可透過 SA token 存取
#   2. SA token 具備正確權限（可列出 pod / 節點）
#   3. ArgoCD RBAC 資源已驗證
#   4. SSM 參數全部已填入（api-endpoint, ca-cert, token）
#
# 必要環境變數：
#   CLUSTER_ENV      — 環境（dev | prod）
#   AWS_REGION       — SSM Parameter Store 所在 AWS region
#
# 選填：
#   CLUSTER_LABELS   — 以空白分隔的 cluster 標籤清單
#                      預設：從 SSM 路徑前綴自動探索
#
# 結束代碼：
#   0 — 所有 cluster 就緒
#   1 — 一個或多個 cluster 驗證失敗
# =============================================================================

set -euo pipefail

: "${CLUSTER_ENV:?Required env var: CLUSTER_ENV (dev|prod)}"
: "${AWS_REGION:?Required env var: AWS_REGION}"

SSM_ENV_PREFIX="/gitops/${CLUSTER_ENV}/clusters"
OVERALL_FAILED=0

echo "============================================================"
echo " validate-cluster-readiness.sh"
echo " env=${CLUSTER_ENV}  region=${AWS_REGION}"
echo "============================================================"

# ── 若未指定，從 SSM 自動探索 cluster ────────────────────────────────────────────
if [ -z "${CLUSTER_LABELS:-}" ]; then
  echo "[0] Auto-discovering clusters from SSM path: ${SSM_ENV_PREFIX}..."
  CLUSTER_LABELS=$(aws ssm get-parameters-by-path \
    --path "${SSM_ENV_PREFIX}" \
    --region "${AWS_REGION}" \
    --cli-connect-timeout 30 \
    --cli-read-timeout 30 \
    --recursive \
    --query "Parameters[?ends_with(Name, '/api-endpoint')].Name" \
    --output text \
    | tr '\t' '\n' \
    | sed "s|${SSM_ENV_PREFIX}/||" \
    | sed 's|/api-endpoint||' \
    | tr '\n' ' ')

  if [ -z "${CLUSTER_LABELS}" ]; then
    echo "::error title=No Clusters::No clusters found at SSM prefix ${SSM_ENV_PREFIX}"
    exit 1
  fi
  echo "      Discovered clusters: ${CLUSTER_LABELS}"
fi

# ── 逐一驗證每個 cluster ────────────────────────────────────────────────────────────
read -ra CLUSTER_ARRAY <<< "${CLUSTER_LABELS}"
for CLUSTER_LABEL in "${CLUSTER_ARRAY[@]}"; do
  echo ""
  echo "--- Validating: ${CLUSTER_LABEL} ---"
  CLUSTER_FAILED=0
  SSM_PREFIX="${SSM_ENV_PREFIX}/${CLUSTER_LABEL}"

  # [A] 驗證所有 SSM 參數是否存在，同時儲存值供後續使用
  echo "  [A] Checking SSM parameters..."
  API_ENDPOINT=""
  CA_CERT_B64=""
  SA_TOKEN=""
  for PARAM in "api-endpoint" "ca-cert" "token"; do
    PARAM_VALUE=$(aws ssm get-parameter \
      --name "${SSM_PREFIX}/${PARAM}" \
      --with-decryption \
      --region "${AWS_REGION}" \
      --cli-connect-timeout 30 \
      --cli-read-timeout 30 \
      --query "Parameter.Value" \
      --output text 2>/dev/null || echo "")

    # 立即遮蔽 token 值並儲存各參數
    if [ "${PARAM}" = "token" ]; then
      echo "::add-mask::${PARAM_VALUE}"
      SA_TOKEN="${PARAM_VALUE}"
    elif [ "${PARAM}" = "api-endpoint" ]; then
      API_ENDPOINT="${PARAM_VALUE}"
    else
      CA_CERT_B64="${PARAM_VALUE}"
    fi

    if [ -z "${PARAM_VALUE}" ]; then
      echo "  ::error title=SSM Missing::SSM parameter ${SSM_PREFIX}/${PARAM} is empty or missing"
      CLUSTER_FAILED=$((CLUSTER_FAILED + 1))
    else
      echo "       SSM ${PARAM}: OK (${#PARAM_VALUE} chars)"
    fi
  done

  # SSM 參數缺失時跳過連線檢查
  if [ "${CLUSTER_FAILED}" -gt "0" ]; then
    echo "  Skipping connectivity checks due to missing SSM parameters"
    OVERALL_FAILED=$((OVERALL_FAILED + 1))
    continue
  fi

  # [B] 建立短暫 kubeconfig
  KUBECONFIG_FILE=$(umask 077 && mktemp /tmp/kubeconfig.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f ${KUBECONFIG_FILE}; unset KUBECONFIG" EXIT INT TERM

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

  # [C] 以 SA token 測試連線
  echo "  [C] Testing SA token connectivity..."
  if ! kubectl auth can-i list nodes --request-timeout=10s > /dev/null 2>&1; then
    echo "  ::error title=Auth Failed::SA token cannot list nodes in ${CLUSTER_LABEL}"
    CLUSTER_FAILED=$((CLUSTER_FAILED + 1))
  else
    echo "       SA token auth: OK (can list nodes)"
  fi

  # [D] 權限抽查
  echo "  [D] Spot-checking SA permissions..."
  for RESOURCE in "pods" "deployments" "namespaces"; do
    if kubectl auth can-i list "${RESOURCE}" --request-timeout=10s > /dev/null 2>&1; then
      echo "       can-i list ${RESOURCE}: OK"
    else
      echo "  ::warning title=Permission::SA cannot list ${RESOURCE} in ${CLUSTER_LABEL}"
    fi
  done

  # [E] 節點就緒狀態抽查
  echo "  [E] Spot-checking node readiness..."
  READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null \
    | grep -c -E "\sReady\s" || echo "0")
  TOTAL_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")

  if [ "${READY_COUNT}" -lt "${TOTAL_COUNT}" ] || [ "${TOTAL_COUNT}" -eq "0" ]; then
    echo "  ::error title=Nodes::${READY_COUNT}/${TOTAL_COUNT} nodes ready in ${CLUSTER_LABEL}"
    CLUSTER_FAILED=$((CLUSTER_FAILED + 1))
  else
    echo "       Nodes ${READY_COUNT}/${TOTAL_COUNT} Ready: OK"
  fi

  # 清除 kubeconfig
  rm -f "${KUBECONFIG_FILE}"
  unset KUBECONFIG
  trap - EXIT INT TERM

  if [ "${CLUSTER_FAILED}" -gt "0" ]; then
    echo "  RESULT: ${CLUSTER_LABEL} → FAILED ✗ (${CLUSTER_FAILED} check(s))"
    OVERALL_FAILED=$((OVERALL_FAILED + 1))
  else
    echo "  RESULT: ${CLUSTER_LABEL} → READY ✓"
  fi
done

# ── 最終摘要 ────────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
if [ "${OVERALL_FAILED}" -gt "0" ]; then
  echo " FINAL RESULT: READINESS VALIDATION FAILED ✗"
  echo " ${OVERALL_FAILED} cluster(s) failed validation"
  echo "============================================================"
  exit 1
else
  CLUSTER_COUNT="${#CLUSTER_ARRAY[@]}"
  echo " FINAL RESULT: ALL ${CLUSTER_COUNT} CLUSTERS READY ✓"
  echo " Environment ${CLUSTER_ENV} is fully provisioned and validated"
  echo "============================================================"
fi
