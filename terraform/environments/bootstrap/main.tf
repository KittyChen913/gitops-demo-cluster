# =============================================================================
# bootstrap/main.tf — Terraform State S3 Bucket
# =============================================================================
# 建立並設定 S3 bucket，作為所有環境（dev, dev-k8s, prod, prod-k8s）
# 的 Terraform remote state backend。
#
# 所有操作皆為冪等（idempotent）— 可安全重複執行。
#
# 安全性：
#   - Bucket 為私有（完全封鎖公開存取）
#   - 靜態加密（AES-256）
#   - 啟用 Versioning，可還原 state 檔案
#   - S3 原生鎖定（use_lockfile = true）— 需要 Terraform >= 1.10
# =============================================================================

resource "aws_s3_bucket" "tf_state" {
  bucket = var.tf_state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
