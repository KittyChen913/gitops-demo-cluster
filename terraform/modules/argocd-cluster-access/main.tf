# 每個目標 Cluster 建立相同的 ArgoCD ServiceAccount、RBAC 與長效 token Secret。
resource "kubernetes_cluster_role_v1" "argocd" {
  metadata {
    name = "argocd-manager"
  }

  # 完整讀取權限供 Argo CD 比較期望狀態與實際狀態。
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

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["applications", "applicationsets", "appprojects"]
    verbs      = ["create", "delete", "patch", "update"]
  }
}

resource "kubernetes_service_account_v1" "argocd" {
  metadata {
    name      = "argocd-manager"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding_v1" "argocd" {
  metadata {
    name = "argocd-manager"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.argocd.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.argocd.metadata[0].name
    namespace = kubernetes_service_account_v1.argocd.metadata[0].namespace
  }
}

resource "kubernetes_secret_v1" "argocd_token" {
  metadata {
    name      = "argocd-manager-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.argocd.metadata[0].name
    }
  }

  type = "kubernetes.io/service-account-token"
}

# 讀回 Kubernetes controller 填入的 token。
data "kubernetes_secret_v1" "argocd_token" {
  metadata {
    name      = kubernetes_secret_v1.argocd_token.metadata[0].name
    namespace = kubernetes_secret_v1.argocd_token.metadata[0].namespace
  }

  depends_on = [kubernetes_secret_v1.argocd_token]
}
