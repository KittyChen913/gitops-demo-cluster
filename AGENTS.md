# AGENTS.md

本文件是 `gitops-demo-cluster` 的專案總規範，適用於整個 repository。任何 Codex 或其他代理在此專案中工作時，請先閱讀本文件，再參考 `README.md` 與 `docs/ci-cd.md`。

## 專案定位

本 repo 負責以 Terraform 管理 Linode Kubernetes Engine (LKE) 叢集生命週期與 Marketplace OpenVPN 存取層，並將叢集連線資訊及 OpenVPN 自動產生的部署憑證寫入 AWS SSM Parameter Store。

專案邊界：

- 本 repo 管理 LKE 叢集、dev/prod 隔離、ArgoCD 用 ServiceAccount / RBAC / token，以及 OpenVPN Linode、Linode Firewall、dnsmasq、Access Server routing 與 host firewall 設定。
- 不在本 repo 安裝 Argo CD 本體、建立 GitOps bootstrap manifest，或管理應用程式 workload。
- OpenVPN 僅提供到內部端點的存取層；`argocd-server-private` Service、NodeBalancer 與其 Cloud Firewall 仍由 `gitops-demo-infra` 管理。
- 下游 GitOps 管理由 `gitops-demo-infra` 與 `gitops-demo-apps` 負責。
- 應用程式原始碼、Dockerfile 與映像建置 workflow 由 `gitops-demo-frontend`、`gitops-demo-backend` 負責，不屬於本 repo。

部署分為兩階段：

- Phase 1：`terraform/environments/dev`、`terraform/environments/prod` 建立 LKE 叢集；啟用時亦建立 Marketplace OpenVPN Linode、Linode Firewall 與部署憑證，並寫入相關 SSM 參數。
- Phase 2：`terraform/environments/dev-k8s`、`terraform/environments/prod-k8s` 讀取 Phase 1 remote state，在叢集內建立 ArgoCD SA / RBAC / token，並寫入 SSM `token`。
- OpenVPN 設定：Phase 1 完成且 Access Server ready 後，才可手動執行 `openvpn-configure.yml` 或本機 Ansible playbook；此步驟不屬於 Phase 2，也不建立 Kubernetes resources。

## 目錄與責任

- `terraform/modules/lke-cluster/`：主要 LKE cluster module，建立 cluster 與 primary node pool。
- `terraform/modules/openvpn-marketplace/`：OpenVPN Marketplace Linode 與 Linode Firewall module。
- `terraform/modules/argocd-cluster-access/`：Phase 2 共用的 ArgoCD SA、RBAC 與 token module。
- `terraform/environments/bootstrap/`：建立 S3 Terraform state backend。
- `terraform/environments/dev/`、`prod/`：Phase 1 cluster provisioning。
- `terraform/environments/dev/openvpn_*.tf`、`prod/openvpn_*.tf`：OpenVPN inputs、credentials、module wiring 與 outputs。
- `terraform/environments/dev-k8s/`、`prod-k8s/`：Phase 2 Kubernetes provider、ArgoCD SA/RBAC/token 與 SSM token。
- `.github/workflows/`：GitHub Actions orchestration；reusable workflow 以 `_` 開頭。
- `.github/actions/`：專案內 composite actions。
- `scripts/`：post-provision 與健康檢查 shell scripts。
- `ansible/`：OpenVPN Access Server、dnsmasq、routing 與 UFW 的 idempotent 設定。
- `docs/`：CI/CD 與操作文件。

## 工作原則

- 優先遵循現有模式，不要引入新框架、新工具或新抽象，除非能明確降低複雜度。
- 保持變更範圍小而清楚；不要順手重構無關檔案。
- Terraform 環境應保持 dev/prod 對稱。修改 dev 時，評估 prod 是否需要等價變更；若刻意不同，請在文件或註解中說明原因。
- Phase 1 與 Phase 2 的依賴順序不可顛倒。`*-k8s` 環境必須依賴對應 Phase 1 remote state。
- OpenVPN 是 dev/prod 的固定環境元件；不得重新加入環境層級的啟用開關。Linode、Firewall 與 generated credentials 必須隨 Phase 1 建立。
- OpenVPN Terraform 與 Ansible 不得管理 `argocd-server`、`argocd-server-private` 或其他 Kubernetes object；這些資源屬於下游 GitOps repo。
- 不要將 Argo CD 安裝、本體設定、Application/ApplicationSet 或 app manifests 加入本 repo。
- 文件使用繁體中文為主；程式碼、變數、workflow id 與 script 名稱維持英文。

## 註解與術語規範

- 人工維護的程式碼、Terraform、GitHub Actions、Ansible、manifest、設定檔與腳本註解必須使用繁體中文。
- 專有名詞、產品名稱、API、Kubernetes 資源種類、欄位名稱、命令、路徑與識別字可保留英文，但英文專有名詞必須放在中文敘述中，不得以完整英文句子撰寫註解。
- `Management Cluster`、`Worker Cluster`、`Cluster` 與 `S3 State Bucket` 均視為專有名詞，不得翻譯成中文，也不得使用其他大小寫變體。
- 複數形式必須寫成 `Management Clusters`、`Worker Clusters` 與 `S3 State Buckets`。
- README、docs、Terraform description、workflow 顯示文字、summary 與人工維護的執行訊息也必須遵守相同的專有名詞大小寫。
- 自動生成檔案（例如 `.terraform.lock.hcl`）的生成器註解、shebang、lint directive 與被註解掉的程式碼不需翻譯或改寫。

## Terraform 規範

- Terraform CLI 最低版本為 `>= 1.10.0`，以支援 S3 backend 的 `use_lockfile` 原生鎖定。
- 變更 Terraform 後，至少執行 `terraform fmt -recursive`。
- 對受影響環境執行 `terraform -chdir=<env-dir> validate`；若 backend 或 provider 初始化不足，先說明限制，不要假裝已驗證。
- 不要提交 `terraform.tfvars`、`.terraform/`、plan binary、local state 或 kubeconfig。
- `terraform.tfvars.example` 應提交並包含所有必要變數鍵、合理預設值與機敏欄位留空註解；實際 `terraform.tfvars` 必須保持 gitignored。
- `region` 與 `aws_region` 由各環境 `variables.tf` 的 `default` 管理，不使用 GitHub Repository Variables。`*-k8s` 環境只需 `aws_region`。
- `versions.tf` 的 AWS provider 必須使用 `region = var.aws_region`；Linode provider token 透過 `linode_token` 或 `LINODE_TOKEN` / `TF_VAR_linode_token` 提供，LKE 資源 region 則由 module 的 `var.region` 傳入。
- `backend.tf` 只放 backend block 中必要且無法變數化的靜態設定：`key`、`encrypt`、`use_lockfile`。`bucket` 與 `region` 放在 `backend.hcl`。
- `backend.hcl` 的 bucket 必須與 `terraform/environments/bootstrap/variables.tf` 的 `tf_state_bucket` 保持一致。
- 除 `bootstrap/` 外，所有 `terraform init` 都必須使用 `-backend-config=backend.hcl -reconfigure -input=false`。
- `bootstrap/` 使用 `backend "local" {}`，不可改成 S3 backend；它負責建立 S3 State Bucket 本身。
- Bootstrap S3 bucket 必須保留 versioning、server-side encryption、public access block 與 `prevent_destroy`，並維持 bucket 已存在即跳過的冪等邏輯；不要改成依賴 GitHub Actions cache 或 `terraform import`。
- 不要讓 dev 與 prod 共用同一個 state key。
- `linode_token` 是 sensitive；本機優先透過 `LINODE_TOKEN` 環境變數提供，CI 由 SSM `/gitops/shared/LINODE_TOKEN` 讀取。
- SSM 路徑維持：
  - `/gitops/shared/OPENVPN_CONTACT_EMAIL`
  - `/gitops/<env>/clusters/<cluster-label>/api-endpoint`
  - `/gitops/<env>/clusters/<cluster-label>/ca-cert`
  - `/gitops/<env>/clusters/<cluster-label>/token`
  - `/gitops/<env>/openvpn/terraform/OPENVPN_ROOT_PASSWORD`
  - `/gitops/<env>/openvpn/ansible/OPENVPN_ADMIN_PASSWORD`
  - `/gitops/<env>/openvpn/ansible/OPENVPN_SSH_PRIVATE_KEY_B64`
  - `/gitops/<env>/openvpn/ansible/OPENVPN_SSH_HOST_KEY`
- OpenVPN root password、Admin password、SSH user key 與 SSH host key 必須由 Terraform `random` / `tls` resources 產生；不得提交或放入 GitHub Secrets。只有 `write_ssm_parameters=true` 時才寫入 OpenVPN SSM 參數。
- 除 contact email 外，OpenVPN infrastructure desired state 由 dev/prod `openvpn.tf` 的 defaults 管理，Internal DNS、split route 與 network desired state 則集中於 `openvpn_network.tf`；contact email 由 CI 從 SSM `/gitops/shared/OPENVPN_CONTACT_EMAIL` 注入，不依賴未提交的 `terraform.tfvars` 或 GitHub Environment Variables。
- 新增 Worker Cluster 時，需同步檢查：
  - Phase 1 `locals.tf` 的 `worker_clusters`
  - Phase 2 `locals.tf`、`providers.tf`、`argocd_sa.tf`、`ssm.tf`
  - README / docs 中的叢集清單與操作說明

## GitHub Actions 規範

- dev apply 只由 `terraform-apply-dev.yml` 管理；push 到 `master` 且符合 dev/bootstrap/modules Terraform、`.github/workflows/**`、`.github/actions/**`、`scripts/**` 或 `.gitattributes` path 時，自動執行 Quality Gate 與完整 dev apply。
- prod apply 只由 `terraform-apply-prod.yml` 管理；prod 不因 branch push 自動 apply，必須透過 SemVer tag `v*` 或手動 workflow，並通過 GitHub Environment `prod` approval。
- 本專案主 branch 是 `master`，workflow trigger、文件與指令範例都不要改成 `main`。
- destroy 只由 `terraform-destroy.yml` 手動執行，且必須依序 Phase 2 再 Phase 1。
- workflow/action/script 或 `.gitattributes` 變更應觸發 `terraform-apply-dev.yml`，並在 Quality Gate 成功後執行 dev apply；不得因 branch push 部署 prod。`ansible/**` 目前不在 dev apply 的 push path filter，僅透過 PR Quality Gate 與手動 OpenVPN workflow 驗證/套用。
- 需要 AWS 存取時一律使用 `.github/actions/configure-aws-credentials` composite action 與 OIDC；不要直接在 workflow 呼叫 `aws-actions/configure-aws-credentials`。
- 所有需要 AWS 的 job 必須設定 `permissions: id-token: write` 與 `contents: read`。
- `AWS_ACCOUNT_ID` 是唯一必要的 AWS 相關 GitHub Repository Secret。不要加入、宣告或傳遞 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`。
- Provider token 由 `.github/actions/get-ssm-parameters` 從 `/gitops/shared` 讀取後注入環境；workflow 不可引用 `secrets.LINODE_TOKEN`。
- CI Terraform 步驟必須設定 `TF_VAR_write_kubeconfig_files=false`，避免 kubeconfig 寫入 runner 磁碟。
- Terraform plan/apply/destroy log 必須過濾 `token`、`secret`、`password`、`pass[word]` 等敏感行。
- 修改 workflow 後，使用 actionlint 驗證；修改 `scripts/*.sh` 後，使用 ShellCheck 驗證；修改 `ansible/**` 後，使用 yamllint 與 `ansible-playbook --syntax-check` 驗證。
- `openvpn-configure.yml` 只能使用 `workflow_dispatch`，從 Phase 1 Terraform state 讀取非機密設定、從 Management Cluster 探索 `argocd-server-private` endpoint，並從 `/gitops/<env>/openvpn/ansible` 讀取 SSH material；prod 執行必須受 `prod` Environment approval 保護。
- Reusable workflows 的 `permissions`、`secrets: inherit`、OIDC 與 concurrency 設定不可隨意移除。
- 呼叫 reusable workflow 時若被呼叫方需要 repository secret，必須加 `secrets: inherit`。
- `.github/actions/**` 是 workflow 依賴的一部分；調整 workflow path filter 時，應確保 composite action 變更能觸發必要的 quality/plan 驗證。
- `run-name` 只對直接觸發的 workflow 有效；`workflow_call` child run 會顯示檔案路徑，不要為 reusable workflow 設定無效的 `run-name`。
- 新增或修改 `uses:` 時，順手核對 action major version 是否符合專案目前基準；local action 與 local reusable workflow 不需要版本管理。

## Workflow Shell 安全

- 不要在 `run:` 區塊中直接使用會影響 shell 邏輯的 `${{ inputs.* }}`、`${{ github.ref_name }}`、`${{ github.actor }}`、`${{ github.ref_type }}` 等 expression。
- 將使用者可控或半可控 expression 先放到 step `env:`，再於 shell 中用 `"${VAR_NAME}"` 引用。
- 純輸出到 `$GITHUB_STEP_SUMMARY` 的系統值可例外，但條件判斷、指令參數、路徑、檔名與迴圈資料都應走 `env:`。
- 此規則同時適用 `.github/workflows/*.yml` 與 `.github/actions/*/action.yml` 中的 Bash 步驟。

## Script 規範

- Shell scripts 以 Bash 撰寫，維持可在 GitHub Actions runner 執行。
- 修改 scripts 後執行 ShellCheck。
- 不要在 logs 輸出 token、kubeconfig、secret value、password 或完整 sensitive Terraform output。
- 健康檢查與驗證腳本主要依賴：
  - `CLUSTER_ENV`
  - `CLUSTER_LABEL`
  - `AWS_REGION`
  - AWS OIDC credentials

## OpenVPN 與 Ansible 規範

- `openvpn-configure.yml` 執行前必須確認 OpenVPN 已啟用、Phase 1 apply 成功、`write_ssm_parameters=true`，且 Marketplace Access Server 已 ready。
- 各環境首次建立 OpenVPN 時，apply workflow 只能對當次 runner `/32` 暫開管理連線；Let’s Encrypt HTTP-01 所需 TCP/80 必須在 bootstrap 期間對 public IPv4 開放，Access Server healthy 後由 workflow 再次 apply 關閉 TCP/80 並移除 runner CIDR。
- `openvpn-configure.yml` 只能在執行期間對當次 runner `/32` 暫開 TCP/22 與 TCP/943，所有成功或失敗路徑都必須嘗試恢復空的 `trusted_admin_cidrs`。
- VM host UFW 固定允許 TCP/22 與 TCP/943，來源限制只由 inbound policy 為 `DROP` 的 Linode Firewall 管理，避免動態 runner 在 SSH 前無法先修改 UFW。
- Ansible inventory 不得含 password 或 private key；CI 只能使用 ephemeral inventory、private key 與 `known_hosts`，並於結束時清理。
- SSH host key 必須與 Terraform 產生並存入 SSM 的 Ed25519 public key 完全相符，不得以關閉 host key checking 規避。
- 不要重設 Access Server core VPN subnet、CA、使用者或 client profiles；只管理文件列明的 DNS、split route、forwarding 與 UFW desired state。
- `argocd_destination_cidr` 應從 `argocd-server-private` LoadBalancer IP 推導為 `/32`；`trusted_admin_cidrs` 不得使用 `0.0.0.0/0` 或 `::/0`，穩定狀態應為空集合。

## 安全與破壞性操作

- 不要主動執行 `terraform apply`、`terraform destroy`、`kubectl delete`、`gh workflow run terraform-destroy.yml` 等會改變或刪除雲端資源的命令，除非使用者明確要求。
- 若使用者要求 destroy，必須再次確認環境與順序：先 Phase 2 `*-k8s`，再 Phase 1。Phase 1 destroy 也會移除該環境啟用的 OpenVPN Linode、Firewall、generated credentials 與 SSM 參數。
- destroy workflow 必須只允許 `workflow_dispatch`，由 environment choice 決定目標，並與 apply 共用 `tf-apply-<env>` concurrency group；prod 必須保留 GitHub Environment approval。
- destroy 執行方式應先 `terraform state list` 判斷是否有 managed resources，再用 `terraform plan -destroy -detailed-exitcode -out=tfdestroy` 與 `terraform apply tfdestroy`；不要直接改成 `terraform destroy -auto-approve`。
- destroy 不刪除 S3 backend bucket，保留 state backend 供日後重新 apply。
- 不要讀取、印出或提交 secret。若需要檢查 secret 是否存在，只回報存在與否。
- 不要修改 Terraform state、遠端 S3 state 或 GitHub Environment protection 設定，除非使用者明確要求。
- 不要回復使用者既有未提交變更。若工作區已有變更，先理解並在其上工作。

## Post-Provision 與 Health Check

- `cluster-post-provision.yml` 可由 apply workflow 呼叫，也可手動重新驗證；它不應重新 apply Terraform。
- 完整驗證流程由 `_cluster-validate.yml` 封裝：每個 Cluster 只讀取一次專屬 SSM path，再執行 health check、SA/RBAC verify、readiness validation。
- `cluster-health-check.yml` 是獨立健康檢查，不部署資源，也不驗證 SA/RBAC。
- cluster post-provision / health workflows 不驗證或設定 OpenVPN；OpenVPN 由 `openvpn-configure.yml` 與 `docs/openvpn-internal-dns.md` 的 runtime checks 負責。
- 排程健康檢查必須同時探索 dev 與 prod；手動與 workflow_call 則只檢查指定 environment。
- 排程失敗必須建立或更新單一 incident issue，恢復後自動關閉；matrix job 不可各自建立重複 issue。
- `cluster_label` 空值代表從對應 Phase 1 remote state 的非機密 `cluster_ids` output 探索所有受管 cluster；指定 label 時必須確認它存在於該 state，找不到 cluster 時應失敗，不可靜默成功。SSM 只提供逐叢集連線資料，不作為 cluster inventory。
- health/post-provision/destroy 等 workflow 結束時應寫入 `$GITHUB_STEP_SUMMARY`，清楚列出 environment、結果與失敗數或 phase 狀態。

## 建議驗證命令

依變更內容選擇最小必要驗證：

```bash
terraform fmt -recursive
terraform -chdir=terraform/environments/dev validate
terraform -chdir=terraform/environments/dev-k8s validate
terraform -chdir=terraform/environments/prod validate
terraform -chdir=terraform/environments/prod-k8s validate
shellcheck scripts/*.sh
actionlint
yamllint -d '{extends: default, rules: {line-length: {max: 140}}}' ansible
cd ansible
ansible-playbook -i inventories/example/hosts.yml --syntax-check playbooks/configure-openvpn-network.yml
```

若使用 Docker 版 actionlint：

```bash
docker run --rm -v "$PWD:/repo" --workdir /repo rhysd/actionlint:1.7.12 -color
```

## 文件同步

當修改以下內容時，請同步檢查文件：

- workflow trigger、path filter、approval、concurrency 或 secrets：更新 `docs/ci-cd.md` 與 README 的 CI/CD 摘要。
- Terraform state key、SSM path、cluster label、team、node sizing：更新 README。
- OpenVPN inputs、SSM path、Firewall、Ansible roles、部署順序或 credential lifecycle：更新 `docs/openvpn-internal-dns.md`，並同步檢查 README 與 `docs/ci-cd.md`。
- destroy 流程或安全限制：更新 README 與 `docs/ci-cd.md`。
- manual command、failure handling、post-provision、health check 或 GitHub Environment 設定有變動時，更新 `docs/ci-cd.md`。
- README 的操作範例需與 `docs/ci-cd.md` 保持一致，尤其是 `gh workflow run`、apply、health check、post-provision 與 destroy。

## 回覆使用者時

- 使用繁體中文，除非使用者要求其他語言。
- 說明實際修改了哪些檔案、做了哪些驗證、哪些驗證因缺少工具或憑證而無法執行。
- 對 prod、destroy、secret、state 相關事項保持明確與保守。
