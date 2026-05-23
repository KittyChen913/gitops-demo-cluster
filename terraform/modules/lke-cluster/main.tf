locals {
  cluster_tags = concat(
    var.tags,
    compact([
      "env:${var.env}",
      "cluster-role:${var.cluster_role}",
      var.team != null ? "team:${var.team}" : null,
      "managed-by:terraform",
      "repo:gitops-demo-cluster",
    ])
  )

  pool_labels = merge(
    {
      "cluster-role" = var.cluster_role
      "env"          = var.env
    },
    var.team != null ? { "team" = var.team } : {}
  )
}

resource "linode_lke_cluster" "this" {
  label       = var.label
  k8s_version = var.k8s_version
  region      = var.region
  tags        = local.cluster_tags

  dynamic "pool" {
    for_each = var.node_pools
    content {
      type  = pool.value.type
      count = pool.value.count
      tags  = pool.value.tags

      labels = merge(local.pool_labels, pool.value.labels)

      dynamic "autoscaler" {
        for_each = pool.value.autoscaler != null ? [pool.value.autoscaler] : []
        content {
          min = autoscaler.value.min
          max = autoscaler.value.max
        }
      }
    }
  }
}

resource "local_file" "kubeconfig" {
  count = var.write_kubeconfig ? 1 : 0

  content              = base64decode(linode_lke_cluster.this.kubeconfig)
  filename             = var.kubeconfig_path
  file_permission      = "0600"
  directory_permission = "0700"
}
