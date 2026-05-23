# Attach additional node pools to an existing LKE cluster (post-bootstrap scaling).
# Primary pools are created inline via modules/lke-cluster; use this module when
# adding capacity (e.g. GPU pool, larger worker pool) without recreating the cluster.

resource "linode_lke_node_pool" "this" {
  cluster_id = var.cluster_id
  type       = var.type
  count      = var.count
  labels     = var.labels
  tags       = var.tags

  dynamic "autoscaler" {
    for_each = var.autoscaler != null ? [var.autoscaler] : []
    content {
      min = autoscaler.value.min
      max = autoscaler.value.max
    }
  }
}
