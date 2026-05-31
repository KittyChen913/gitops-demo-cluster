# ---------------------------------------------------------------------------
# ArgoCD ServiceAccount setup
#
# Each cluster gets:
#   - A custom ClusterRole: read all resources + write common app resource types
#   - A ClusterRoleBinding for the argocd-manager SA
#   - A long-lived token Secret (kubernetes.io/service-account-token)
# ---------------------------------------------------------------------------

# ── Management cluster ──────────────────────────────────────────────────────

resource "kubernetes_cluster_role_v1" "argocd_mgmt" {
  provider = kubernetes.mgmt
  metadata {
    name = "argocd-manager"
  }

  # Read-all: needed to compare desired vs actual state of all resources.
  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }
  # Write: scoped to resources created by ArgoCD's own installation manifests.
  rule {
    api_groups = [""]
    resources  = ["namespaces", "configmaps", "secrets", "serviceaccounts", "services"]
    verbs      = ["create", "delete", "patch", "update"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets"]
    verbs      = ["create", "delete", "patch", "update"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
    verbs      = ["create", "delete", "patch", "update", "escalate", "bind"]
  }
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["create", "delete", "patch", "update"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["networkpolicies", "ingresses", "ingressclasses"]
    verbs      = ["create", "delete", "patch", "update"]
  }
}

resource "kubernetes_service_account_v1" "argocd_mgmt" {
  provider = kubernetes.mgmt
  metadata {
    name      = "argocd-manager"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding_v1" "argocd_mgmt" {
  provider = kubernetes.mgmt
  metadata {
    name = "argocd-manager"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.argocd_mgmt.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.argocd_mgmt.metadata[0].name
    namespace = kubernetes_service_account_v1.argocd_mgmt.metadata[0].namespace
  }
}

resource "kubernetes_secret_v1" "argocd_token_mgmt" {
  provider = kubernetes.mgmt
  metadata {
    name      = "argocd-manager-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.argocd_mgmt.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

# Read back the secret so Kubernetes-populated fields (token, ca.crt) are available.
data "kubernetes_secret_v1" "argocd_token_mgmt" {
  provider = kubernetes.mgmt
  metadata {
    name      = kubernetes_secret_v1.argocd_token_mgmt.metadata[0].name
    namespace = kubernetes_secret_v1.argocd_token_mgmt.metadata[0].namespace
  }
  depends_on = [kubernetes_secret_v1.argocd_token_mgmt]
}

# ── ATeam worker cluster ─────────────────────────────────────────────────────

resource "kubernetes_cluster_role_v1" "argocd_ateam" {
  provider = kubernetes.ateam
  metadata {
    name = "argocd-manager"
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces", "configmaps", "secrets", "serviceaccounts", "services"]
    verbs      = ["create", "delete", "patch", "update"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets"]
    verbs      = ["create", "delete", "patch", "update"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
    verbs      = ["create", "delete", "patch", "update", "escalate", "bind"]
  }
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["create", "delete", "patch", "update"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["networkpolicies", "ingresses", "ingressclasses"]
    verbs      = ["create", "delete", "patch", "update"]
  }
}

resource "kubernetes_service_account_v1" "argocd_ateam" {
  provider = kubernetes.ateam
  metadata {
    name      = "argocd-manager"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding_v1" "argocd_ateam" {
  provider = kubernetes.ateam
  metadata {
    name = "argocd-manager"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.argocd_ateam.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.argocd_ateam.metadata[0].name
    namespace = kubernetes_service_account_v1.argocd_ateam.metadata[0].namespace
  }
}

resource "kubernetes_secret_v1" "argocd_token_ateam" {
  provider = kubernetes.ateam
  metadata {
    name      = "argocd-manager-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.argocd_ateam.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

data "kubernetes_secret_v1" "argocd_token_ateam" {
  provider = kubernetes.ateam
  metadata {
    name      = kubernetes_secret_v1.argocd_token_ateam.metadata[0].name
    namespace = kubernetes_secret_v1.argocd_token_ateam.metadata[0].namespace
  }
  depends_on = [kubernetes_secret_v1.argocd_token_ateam]
}
