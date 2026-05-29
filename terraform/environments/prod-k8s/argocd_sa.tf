# ---------------------------------------------------------------------------
# ArgoCD ServiceAccount setup
# ---------------------------------------------------------------------------

# ── Management cluster ──────────────────────────────────────────────────────

resource "kubernetes_cluster_role_v1" "argocd_mgmt" {
  provider = kubernetes.mgmt
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
    verbs      = ["create", "delete", "patch", "update"]
  }
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
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
    verbs      = ["create", "delete", "patch", "update"]
  }
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
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
