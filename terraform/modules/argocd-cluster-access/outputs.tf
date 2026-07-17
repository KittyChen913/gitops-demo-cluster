output "token" {
  description = "ArgoCD ServiceAccount 長效 token。"
  value       = data.kubernetes_secret_v1.argocd_token.data["token"]
  sensitive   = true
}
