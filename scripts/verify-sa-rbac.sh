#!/usr/bin/env bash
# =============================================================================
# verify-sa-rbac.sh — ArgoCD ServiceAccount & RBAC 驗證
# =============================================================================
#
# 驗證 Terraform Phase 2（dev-k8s / prod-k8s）是否成功建立：
#   1. ServiceAccount     : argocd-manager（kube-system）
#   2. Secret             : argocd-manager-token（kube-system）
#   3. ClusterRole        : argocd-manager
#   4. ClusterRoleBinding : argocd-manager
#   5. Token 功能驗證：SSM 中的 SA token 能否對 cluster 進行身分驗證
#
# 必要環境變數：
#   CLUSTER_ENV      — 環境（dev | prod）
#   CLUSTER_LABEL    — Cluster 標籤（例如 lke-dev-mgmt）
#   AWS_REGION       — SSM Parameter Store 所在 AWS region
#
# 結束代碼：
#   0 — SA 與 RBAC 驗證通過
#   1 — 驗證失敗
# =============================================================================

set -euo pipefail

: "${CLUSTER_ENV:?Required env var: CLUSTER_ENV (dev|prod)}"
: "${CLUSTER_LABEL:?Required env var: CLUSTER_LABEL (e.g. lke-dev-mgmt)}"
: "${AWS_REGION:?Required env var: AWS_REGION}"

SA_NAME="argocd-manager"
SA_NAMESPACE="kube-system"
TOKEN_SECRET_NAME="argocd-manager-token"
SSM_PREFIX="/gitops/${CLUSTER_ENV}/clusters/${CLUSTER_LABEL}"

FAILED=0

echo "============================================================"
echo " verify-sa-rbac.sh"
echo " env=${CLUSTER_ENV}  cluster=${CLUSTER_LABEL}"
echo "============================================================"

# ── Step 1：從 SSM 取得認證資料 ────────────────────────────────────────────────────
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

SA_TOKEN=$(aws ssm get-parameter \
  --name "${SSM_PREFIX}/token" \
  --with-decryption \
  --region "${AWS_REGION}" \
  --cli-connect-timeout 30 \
  --cli-read-timeout 30 \
  --query "Parameter.Value" \
  --output text)

echo "::add-mask::${SA_TOKEN}"
echo "      Credentials fetched"

# ── 建立短暫 kubeconfig ─────────────────────────────────────────────────────────────
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

# ── Step 2：驗證 ServiceAccount ──────────────────────────────────────────────────────
echo "[2/5] Verifying ServiceAccount: ${SA_NAMESPACE}/${SA_NAME}..."

if kubectl get serviceaccount "${SA_NAME}" -n "${SA_NAMESPACE}" \
    --request-timeout=10s > /dev/null 2>&1; then
  echo "      ServiceAccount: OK"
else
  echo "::error title=SA Missing::ServiceAccount ${SA_NAMESPACE}/${SA_NAME} not found in ${CLUSTER_LABEL}"
  FAILED=$((FAILED + 1))
fi

# ── Step 3：驗證 token Secret ────────────────────────────────────────────────────────
echo "[3/5] Verifying token Secret: ${SA_NAMESPACE}/${TOKEN_SECRET_NAME}..."

if kubectl get secret "${TOKEN_SECRET_NAME}" -n "${SA_NAMESPACE}" \
    --request-timeout=10s > /dev/null 2>&1; then
  # 驗證 Secret 類型
  SECRET_TYPE=$(kubectl get secret "${TOKEN_SECRET_NAME}" -n "${SA_NAMESPACE}" \
    -o jsonpath='{.type}' 2>/dev/null || echo "unknown")
  if [ "${SECRET_TYPE}" = "kubernetes.io/service-account-token" ]; then
    echo "      Token Secret: OK (type=${SECRET_TYPE})"
  else
    echo "::warning title=Secret Type::Secret type is '${SECRET_TYPE}', expected 'kubernetes.io/service-account-token'"
  fi
else
  echo "::error title=Token Secret Missing::Secret ${SA_NAMESPACE}/${TOKEN_SECRET_NAME} not found in ${CLUSTER_LABEL}"
  FAILED=$((FAILED + 1))
fi

# ── Step 4：驗證 ClusterRole ─────────────────────────────────────────────────────────
echo "[4/5] Verifying ClusterRole: ${SA_NAME}..."

if kubectl get clusterrole "${SA_NAME}" \
    --request-timeout=10s > /dev/null 2>&1; then
  # 逐行列出所有 verb，精確比對 "get"（避免誤中子字串如 gettoken）
  RULE_COUNT=$(kubectl get clusterrole "${SA_NAME}" \
    -o jsonpath='{range .rules[*]}{range .verbs[*]}{@}{"\n"}{end}{end}' 2>/dev/null \
    | grep -cx "get" || echo "0")
  echo "      ClusterRole: OK (${RULE_COUNT} rule(s) with exact 'get' verb)"
else
  echo "::error title=ClusterRole Missing::ClusterRole ${SA_NAME} not found in ${CLUSTER_LABEL}"
  FAILED=$((FAILED + 1))
fi

# ── Step 5：驗證 ClusterRoleBinding ─────────────────────────────────────────────────
echo "[5/5] Verifying ClusterRoleBinding: ${SA_NAME}..."

if kubectl get clusterrolebinding "${SA_NAME}" \
    --request-timeout=10s > /dev/null 2>&1; then
  BOUND_SA=$(kubectl get clusterrolebinding "${SA_NAME}" \
    -o jsonpath='{.subjects[0].name}' 2>/dev/null || echo "")
  BOUND_NS=$(kubectl get clusterrolebinding "${SA_NAME}" \
    -o jsonpath='{.subjects[0].namespace}' 2>/dev/null || echo "")
  BOUND_KIND=$(kubectl get clusterrolebinding "${SA_NAME}" \
    -o jsonpath='{.subjects[0].kind}' 2>/dev/null || echo "")
  if [ "${BOUND_SA}" != "${SA_NAME}" ] || \
     [ "${BOUND_NS}" != "${SA_NAMESPACE}" ] || \
     [ "${BOUND_KIND}" != "ServiceAccount" ]; then
    echo "::error title=CRB Subject Mismatch::ClusterRoleBinding ${SA_NAME} subject mismatch: kind=${BOUND_KIND}, namespace=${BOUND_NS}, name=${BOUND_SA}"
    FAILED=$((FAILED + 1))
  else
    echo "      ClusterRoleBinding: OK (bound to ${BOUND_KIND}/${BOUND_NS}/${BOUND_SA})"
  fi
else
  echo "::error title=CRB Missing::ClusterRoleBinding ${SA_NAME} not found in ${CLUSTER_LABEL}"
  FAILED=$((FAILED + 1))
fi

# ── 摘要 ──────────────────────────────────────────────────────────────────────────────
echo ""
if [ "${FAILED}" -gt "0" ]; then
  echo "============================================================"
  echo " RESULT: ${CLUSTER_LABEL} → SA/RBAC VERIFICATION FAILED ✗"
  echo " ${FAILED} check(s) failed"
  echo "============================================================"
  exit 1
else
  echo "============================================================"
  echo " RESULT: ${CLUSTER_LABEL} → SA/RBAC VERIFIED ✓"
  echo " SA, Token, ClusterRole, ClusterRoleBinding: all present"
  echo "============================================================"
fi
