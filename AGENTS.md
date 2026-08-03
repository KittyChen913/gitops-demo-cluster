# AGENTS.md

本文件是 `gitops-demo-cluster` 的專案總規範，適用於整個 repository。任何 Codex 或其他代理在此專案中工作時，請先閱讀本文件，再參考 `README.md` 與 `docs/ci-cd.md`。

## 專案定位

本 repo負責以Terraform管理Linode Kubernetes Engine (LKE) Cluster lifecycle、Node Pool、Cluster Firewall、Management Cluster Control Plane ACL、ArgoCD cluster access與cluster connection SSM parameters。

專案邊界：

- 本 repo管理LKE Cluster、dev/prod隔離、Management／Worker Cluster Firewall、Management Cluster Control Plane ACL，以及ArgoCD用ServiceAccount / RBAC / token。
- 不在本 repo 安裝 ArgoCD 本體、建立 GitOps bootstrap manifest，或管理應用程式 workload。
- Shared OpenVPN、VPN Server Firewall、Internal DNS、routing、NAT、groups與credential bootstrap由 `gitops-demo-platform-access` 管理；不得重新加入本repo。
- Shared OpenVPN建立於獨立Linode VM，不是在Kubernetes Cluster內建立。
- `argocd-server-private` Service、NodeBalancer與其Cloud Firewall由 `gitops-demo-infra` 管理。
- 下游 GitOps 管理由 `gitops-demo-infra` 與 `gitops-demo-apps` 負責。
- 應用程式原始碼、Dockerfile 與映像建置 workflow 由 `gitops-demo-frontend`、`gitops-demo-backend` 負責，不屬於本 repo。

部署分為兩階段：

- Phase 1：`terraform/environments/dev`、`terraform/environments/prod`建立LKE Cluster、evidence-gated Cluster Firewall／Control Plane ACL並寫入cluster SSM metadata。
- Phase 2：`terraform/environments/dev-k8s`、`terraform/environments/prod-k8s` 讀取 Phase 1 remote state，在叢集內建立 ArgoCD SA / RBAC / token，並寫入 SSM `token`。

跨Repository從零部署順序固定為：Cluster foundation → Platform Access → Cluster network boundary convergence → Infra / ArgoCD → User Provisioning。

## 目錄與責任

- `terraform/modules/lke-cluster/`：主要 LKE cluster module，建立 cluster 與 primary node pool。
- `terraform/modules/worker-firewall/`：既有相容路徑；提供evidence-gated Management／Worker Cluster Firewall與node attachment。
- `terraform/modules/argocd-cluster-access/`：Phase 2 共用的 ArgoCD SA、RBAC 與 token module。
- `terraform/environments/bootstrap/`：建立 S3 Terraform state backend。
- `terraform/environments/dev/`、`prod/`：Phase 1 cluster provisioning。
- `config/worker-firewall/`：既有相容路徑；dev/prod schema v2 Cluster Firewall／Control Plane ACL canonical evidence與activation contract。
- `terraform/environments/dev-k8s/`、`prod-k8s/`：Phase 2 Kubernetes provider、ArgoCD SA/RBAC/token 與 SSM token。
- `.github/workflows/`：GitHub Actions orchestration；reusable workflow 以 `_` 開頭。
- `.github/actions/`：專案內 composite actions。
- `scripts/`：post-provision、健康檢查與saved-plan safety guard scripts。
- `docs/`：CI/CD 與操作文件。

## 工作原則

- 優先遵循現有模式，不要引入新框架、新工具或新抽象，除非能明確降低複雜度。
- 保持變更範圍小而清楚；不要順手重構無關檔案。
- Terraform 環境應保持 dev/prod 對稱。修改 dev 時，評估 prod 是否需要等價變更；若刻意不同，請在文件或註解中說明原因。
- Phase 1 與 Phase 2 的依賴順序不可顛倒。`*-k8s` 環境必須依賴對應 Phase 1 remote state。
- Cluster Firewall預設inbound `DROP`、outbound `ACCEPT`。沒有verified runtime evidence時，對應Cluster與Control Plane ACL必須保持`activation_enabled=false`，不得猜測CIDR。
- 每條Cluster Firewall allow rule必須記錄purpose與evidence，禁止`0.0.0.0/0`、`::/0`與Internet直接到ArgoCD、NodePort或SSH。
- Management Cluster Control Plane ACL只能允許已驗證的VPN public egress CIDR；啟用前必須確認Phase 2與post-provision runner確實經VPN送出API traffic。
- 不要將 ArgoCD 安裝、本體設定、Application/ApplicationSet 或 app manifests 加入本 repo。
- 文件使用繁體中文為主；程式碼、變數、workflow id 與 script 名稱維持英文。

## 註解與術語規範

- 人工維護的程式碼、Terraform、GitHub Actions、Ansible、manifest、設定檔與腳本註解必須使用繁體中文。
- 專有名詞、產品名稱、API、Kubernetes 資源種類、欄位名稱、命令、路徑與識別字可保留英文，但英文專有名詞必須放在中文敘述中，不得以完整英文句子撰寫註解。
- `Management Cluster`、`Worker Cluster`、`Cluster` 與 `S3 State Bucket` 均視為專有名詞，不得翻譯成中文，也不得使用其他大小寫變體。
- 複數形式必須寫成 `Management Clusters`、`Worker Clusters` 與 `S3 State Buckets`。
- README 與 docs 使用繁體中文敘述，並遵守相同的專有名詞大小寫。
- Workflow／job／step、composite action 的 `name` 與 `description` 必須使用英文。
- 程式碼內的文字必須使用英文，包括 Terraform `description`／`error_message`、CLI／UI 文字、log、error、warning、summary 與其他執行訊息；但等待／重試迴圈中即時印給人類觀察進度的狀態訊息（例如第幾次嘗試、剩餘秒數、失敗原因、逾時後的診斷輸出）例外，使用繁體中文。
- 產品名稱的唯一允許拼法為 `ArgoCD`。
- 自動生成檔案（例如 `.terraform.lock.hcl`）的生成器註解、shebang、lint directive 與被註解掉的程式碼不需翻譯或改寫。

## Terraform 規範

- Terraform CLI 最低版本為 `>= 1.10.0`，以支援 S3 backend 的 `use_lockfile` 原生鎖定。
- Terraform validation 必須依全域「最小必要 Validation」規範，針對實際受影響的 module、root 與 consumers 選擇 formatting check、`terraform validate` 或其他直接檢核；不得預設執行 recursive formatting 或所有環境。
- 需要 `terraform validate` 時，只驗證受影響 root；若 backend 或 provider 初始化不足，標示 `BLOCKED` 或 `NOT RUN` 並說明未取得的信心，不得假裝已驗證。
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
  - `/gitops/<env>/clusters/<cluster-label>/api-endpoint`
  - `/gitops/<env>/clusters/<cluster-label>/ca-cert`
  - `/gitops/<env>/clusters/<cluster-label>/token`
- LKE、Cluster Firewall與Control Plane ACL的delete／replace／disable保護由Phase 1 saved-plan guard統一負責；一般plan／apply必須啟用guard，只有專用destroy workflow可略過。
- 新增 Worker Cluster 時，需同步檢查：
  - Phase 1 `locals.tf` 的 `worker_clusters`
  - Phase 2 `locals.tf`、`providers.tf`、`argocd_sa.tf`、`ssm.tf`
  - `config/worker-firewall/<env>.json` 的cluster key
  - README / docs 中的叢集清單與操作說明

## GitHub Actions 規範

- dev apply 只由 `terraform-apply-dev.yml` 管理；push 到 `master` 且符合 dev/bootstrap/modules Terraform、`.github/workflows/**`、`.github/actions/**`、`scripts/**` 或 `.gitattributes` path 時，自動執行 Quality Gate 與完整 dev apply。
- prod apply 只由 `terraform-apply-prod.yml` 管理；prod 不因 branch push 自動 apply，必須透過 SemVer tag `v*` 或手動 workflow，並通過 GitHub Environment `prod` approval。
- 本專案主 branch 是 `master`，workflow trigger、文件與指令範例都不要改成 `main`。
- destroy 只由 `terraform-destroy.yml` 手動執行，且必須依序 Phase 2 再 Phase 1。
- workflow/action/script或`.gitattributes`變更應觸發`terraform-apply-dev.yml`，並在Quality Gate成功後執行dev apply；不得因branch push部署prod。
- 需要 AWS 存取時一律使用 `.github/actions/configure-aws-credentials` composite action 與 OIDC；不要直接在 workflow 呼叫 `aws-actions/configure-aws-credentials`。
- 所有需要 AWS 的 job 必須設定 `permissions: id-token: write` 與 `contents: read`。
- `AWS_ACCOUNT_ID` 是唯一必要的 AWS 相關 GitHub Repository Secret。不要加入、宣告或傳遞 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`。
- Provider token 由 `.github/actions/get-ssm-parameters` 從 `/gitops/shared` 讀取後注入環境；workflow 不可引用 `secrets.LINODE_TOKEN`。
- CI Terraform 步驟必須設定 `TF_VAR_write_kubeconfig_files=false`，避免 kubeconfig 寫入 runner 磁碟。
- Terraform plan/apply/destroy log 必須過濾 `token`、`secret`、`password`、`pass[word]` 等敏感行。
- Workflow 與 composite action 的本機 validation 應依實際 syntax、expression、Shell execution path 與直接 consumers 選擇 `actionlint`、ShellCheck 或相關 contract checks，不得預設執行完整工具集合。
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
- Shell validation 應聚焦受影響 script 與直接 caller；只有 shared helper 或跨 workflow execution path 受影響時才擴大範圍。
- 不要在 logs 輸出 token、kubeconfig、secret value、password 或完整 sensitive Terraform output。
- 健康檢查與驗證腳本主要依賴：
  - `CLUSTER_ENV`
  - `CLUSTER_LABEL`
  - `AWS_REGION`
  - AWS OIDC credentials

## Cluster Network Boundary規範

- `config/worker-firewall/<env>.json` schema v2是唯一canonical source；不得在tfvars、workflow env或文件另建一份rules或ACL addresses。
- Cluster Firewall activation前必須有Management／Worker public IP／NodePort、Firewall owner、LKE control-plane、NodeBalancer health與node/pod traffic的runtime evidence。
- Management Cluster Firewall另需確認VPN traffic經route或SNAT後的實際node source；Control Plane ACL則使用VPN public egress source，兩者不得互相推測。
- node attachment只從LKE pool output推導，不手工維護instance IDs；新增或replacement node必須自動受同一Firewall保護。
- NodeBalancer Firewall不能取代Cluster Firewall；DNS也不是authorization boundary。
- runtime evidence未完成時使用`NOT_RUNTIME_VERIFIED`與停用adapter，不得因此猜測allowlist或啟用default-deny。
- 需要連線Kubernetes API server建立ArgoCD SA/RBAC/token的apply（`dev-k8s`／`prod-k8s`，判斷式為`enforce_cluster_boundary=false`）改經`config/automation-vpn.json`定義的automation VPN tunnel連線Management／Worker Cluster API endpoint，避免被只允許VPN來源的Control Plane ACL擋下；tunnel open/close composite action（`.github/actions/{open,close}-automation-vpn-tunnel`）與執行腳本（`scripts/manage-automation-vpn-tunnel.sh`）由本repo自行擁有與維護，只使用`./`本地相對路徑引用，不得改為跨repo`uses:`參照、不得以`gitops-demo-platform-access`的commit SHA作為workflow runtime dependency。Shared OpenVPN Server、automation identity簽發、SSM credential publishing與VPN public egress IP仍由`gitops-demo-platform-access`管理，屬platform service contract，只能透過SSM參數消費，不得取得其Git history、branch、tag或檔案布局的依賴。
- `config/automation-vpn.json`的`target_parameter_paths`必須對應SSM上實際存在的`/gitops/<env>/clusters/<cluster-label>/api-endpoint`；新增Worker Cluster時需同步更新此清單。`expected_tunnel_ip`是本repo宣告的ci-cluster固定`conn_ip`，若`gitops-demo-platform-access`的`config/automation-identities.json`變更該身份的`conn_ip`，需人工同步更新此欄位；本欄位只是本repo自行宣告的期望值比對基準，不是跨repo程式碼相依。

## 安全與破壞性操作

- 不要主動執行 `terraform apply`、`terraform destroy`、`kubectl delete`、`gh workflow run terraform-destroy.yml` 等會改變或刪除雲端資源的命令，除非使用者明確要求。
- 若使用者要求destroy，必須再次確認環境與順序：先Phase 2 `*-k8s`，再Phase 1。Phase 1 destroy會移除LKE、node、cluster SSM metadata、已啟用的Cluster Firewall與Control Plane ACL。
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
- cluster post-provision／health workflows不驗證或設定Shared OpenVPN；該ownership屬`gitops-demo-platform-access`。
- 排程健康檢查必須同時探索 dev 與 prod；手動與 workflow_call 則只檢查指定 environment。
- 排程失敗必須建立或更新單一 incident issue，恢復後自動關閉；matrix job 不可各自建立重複 issue。
- `cluster_label` 空值代表從對應 Phase 1 remote state 的非機密 `cluster_ids` output 探索所有受管 cluster；指定 label 時必須確認它存在於該 state，找不到 cluster 時應失敗，不可靜默成功。SSM 只提供逐叢集連線資料，不作為 cluster inventory。
- health/post-provision/destroy 等 workflow 結束時應寫入 `$GITHUB_STEP_SUMMARY`，清楚列出 environment、結果與失敗數或 phase 狀態。

## 可用 Validation 入口

```bash
terraform fmt -check <affected-paths>
terraform -chdir=<affected-root> validate
shellcheck <affected-scripts>
actionlint <affected-workflow-or-action-files>
```

- 上述命令只是 repository 既有入口，不是固定清單；每次依實際變更風險選擇最小子集。
- 只有 shared module、shared workflow、cross-environment contract、局部 validation 失敗且證據指向相依範圍，或使用者明確要求時，才擴大至其他 roots、scripts 或 workflows。
- 完整 Quality Gate、Terraform plan、post-provision 與 health validation 屬 PR、merge、release、deployment 或獨立驗收階段，不得在每次局部修改後自動執行。
- 使用 Container 執行 validation 時，依全域安全 Container 規則使用本機既有 Image、停用 network、唯讀掛載 repository 並限制權限；不在此文件維護較寬鬆的替代命令。

## 文件同步

當修改以下內容時，請同步檢查文件：

- workflow trigger、path filter、approval、concurrency 或 secrets：更新 `docs/ci-cd.md` 與 README 的 CI/CD 摘要。
- Terraform state key、SSM path、cluster label、team、node sizing：更新 README。
- Cluster Firewall／Control Plane ACL contract、evidence、attachment或guard：更新`docs/cluster-network-boundary.md`並同步檢查README與`docs/ci-cd.md`。
- destroy 流程或安全限制：更新 README 與 `docs/ci-cd.md`。
- manual command、failure handling、post-provision、health check 或 GitHub Environment 設定有變動時，更新 `docs/ci-cd.md`。
- README 的操作範例需與 `docs/ci-cd.md` 保持一致，尤其是 `gh workflow run`、apply、health check、post-provision 與 destroy。

## 回覆使用者時

- 使用繁體中文，除非使用者要求其他語言。
- 說明實際修改範圍、判定出的風險、每項 validation 的風險對應、刻意未執行的較大範圍驗證，以及因缺少工具或憑證而無法執行的項目。
- 對 prod、destroy、secret、state 相關事項保持明確與保守。
