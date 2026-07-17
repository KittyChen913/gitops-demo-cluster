# S3 State Bucket 名稱必須與 bootstrap/variables.tf:tf_state_bucket 一致（預設："kc-gitops-demo-tfstate"）。
# Terraform backend 區塊不支援變數插值；重新命名時請同步更新此處。
bucket = "kc-gitops-demo-tfstate"
region = "ap-southeast-1"
