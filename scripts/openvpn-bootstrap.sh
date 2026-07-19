#!/usr/bin/env bash

# 封裝 Phase 1 的 OpenVPN Marketplace bootstrap 與 Admin credential 生命週期。
# Workflow 只負責傳入環境與 Terraform 變數；本腳本不管理後續 Ansible network desired state。
set -euo pipefail

readonly OPENVPN_INSTANCE_PATTERN='^module\.openvpn\.linode_instance\.openvpn(\[0\])?$'
readonly OPENVPN_FIREWALL_PATTERN='^module\.openvpn\.linode_firewall\.openvpn(\[0\])?$'
readonly READINESS_TIMEOUT_SECONDS=900
readonly READINESS_RETRY_SECONDS=10
readonly SSH_ATTEMPT_TIMEOUT_SECONDS=15
readonly FIREWALL_VERIFY_ATTEMPTS=6
readonly FIREWALL_VERIFY_RETRY_SECONDS=5
readonly RUNNER_IP_RECHECK_ATTEMPTS=6
readonly LINODE_API_BASE_URL='https://api.linode.com/v4'

filter_terraform_log() {
  local log_file="$1"

  grep -v -iE '^\s*(token|secret|pass[w]ord)\s*=' "${log_file}" || true
}

linode_api_get() {
  local api_path="$1"

  : "${TF_VAR_linode_token:?TF_VAR_linode_token 未設定}"

  curl --fail --silent --show-error \
    --retry 2 \
    --retry-all-errors \
    --connect-timeout 10 \
    --max-time 30 \
    --header "Authorization: Bearer ${TF_VAR_linode_token}" \
    "${LINODE_API_BASE_URL}${api_path}"
}

openvpn_requires_replacement() (
  local runner_temp="${RUNNER_TEMP:?RUNNER_TEMP 未設定}"
  local plan_file="${runner_temp}/openvpn-bootstrap-detect.tfplan"
  local plan_json="${runner_temp}/openvpn-bootstrap-detect.json"
  local plan_log="${runner_temp}/openvpn-bootstrap-detect.log"
  local jq_exit
  local plan_exit
  local tfvars_args=()

  trap 'rm -f -- "${plan_file}" "${plan_json}" "${plan_log}"' EXIT

  if [[ -f terraform.tfvars ]]; then
    tfvars_args=(-var-file=terraform.tfvars)
  fi

  set +e
  terraform plan \
    -input=false \
    -target='module.openvpn.linode_instance.openvpn' \
    -out="${plan_file}" \
    "${tfvars_args[@]}" \
    >"${plan_log}" 2>&1
  plan_exit=$?
  set -e

  if [[ "${plan_exit}" -ne 0 ]]; then
    echo "::group::OpenVPN replacement plan 診斷"
    filter_terraform_log "${plan_log}"
    echo "::endgroup::"
    echo "::error title=OpenVPN Bootstrap Detection Failed::無法判斷 OpenVPN Linode 是否需要 replacement"
    return 2
  fi

  if ! terraform show -json "${plan_file}" >"${plan_json}" 2>>"${plan_log}"; then
    echo "::group::OpenVPN replacement plan 解析診斷"
    filter_terraform_log "${plan_log}"
    echo "::endgroup::"
    echo "::error title=OpenVPN Bootstrap Detection Failed::無法解析 OpenVPN replacement plan"
    return 2
  fi

  set +e
  jq -e '
    any(
      .resource_changes[]?;
      (.address | test("^module\\.openvpn\\.linode_instance\\.openvpn(\\[0\\])?$")) and
      (.change.actions | index("create") != null)
    )
  ' "${plan_json}" >/dev/null
  jq_exit=$?
  set -e

  case "${jq_exit}" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      echo "::error title=OpenVPN Bootstrap Detection Failed::無法讀取 OpenVPN replacement actions"
      return 2
      ;;
  esac
)

describe_readiness_failure() {
  local exit_code="$1"
  local error_file="$2"

  case "${exit_code}" in
    20)
      printf '%s\n' 'SSH 已連線，但遠端使用者無法執行免互動 sudo'
      ;;
    21)
      printf '%s\n' 'SSH 已連線，但 sacli 尚未安裝或不可執行'
      ;;
    22)
      printf '%s\n' 'SSH 已連線，但 openvpnas service 尚未 active'
      ;;
    23)
      printf '%s\n' 'SSH 已連線且 openvpnas 已 active，但 sacli status 失敗'
      ;;
    124)
      printf '%s\n' "SSH readiness 命令超過 ${SSH_ATTEMPT_TIMEOUT_SECONDS} 秒"
      ;;
    255)
      if grep -qiE 'host key verification failed|remote host identification has changed|no .* host key is known' "${error_file}"; then
        printf '%s\n' 'SSH host key 驗證失敗；cloud-init 可能尚未安裝 Terraform 管理的 host key'
      elif grep -qiE 'permission denied|authentication failed' "${error_file}"; then
        printf '%s\n' 'SSH 使用者或 private key 驗證失敗'
      elif grep -qiE 'connection timed out|operation timed out|no route to host|connection refused' "${error_file}"; then
        printf '%s\n' 'TCP/22 無法連線；請檢查 Linode Firewall runner /32 與 ssh service'
      elif grep -qiE 'connection closed|connection reset|kex_exchange_identification' "${error_file}"; then
        printf '%s\n' 'SSH transport 或 key exchange 尚未 ready'
      else
        printf '%s\n' 'SSH 連線失敗；請檢查 Firewall、host key 與使用者認證'
      fi
      ;;
    *)
      printf '遠端 readiness 命令失敗（exit code %s）\n' "${exit_code}"
      ;;
  esac
}

resolve_bootstrap_access() {
  local bootstrap_requested="${BOOTSTRAP_REQUESTED:-false}"
  local readiness_needed=false
  local replacement_needed=false
  local bootstrap_http=false
  local trusted_admin_cidrs='[]'
  local runner_ip
  local replacement_exit
  local state_list

  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT 未設定}"
  : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE 未設定}"

  if [[ "${bootstrap_requested}" == "true" ]]; then
    readiness_needed=true
    state_list="$(terraform state list)"

    if ! grep -Eq "${OPENVPN_INSTANCE_PATTERN}" <<< "${state_list}"; then
      replacement_needed=true
    elif openvpn_requires_replacement; then
      replacement_needed=true
    else
      replacement_exit=$?
      if [[ "${replacement_exit}" -ne 1 ]]; then
        return "${replacement_exit}"
      fi
    fi
  fi

  if [[ "${readiness_needed}" == "true" ]]; then
    runner_ip="$(bash "${GITHUB_WORKSPACE}/scripts/discover-runner-public-ip.sh")"
    echo "::add-mask::${runner_ip}"

    trusted_admin_cidrs="[\"${runner_ip}/32\"]"
  fi

  if [[ "${replacement_needed}" == "true" ]]; then
    bootstrap_http=true
  fi

  {
    echo "needed=${readiness_needed}"
    echo "replacement=${replacement_needed}"
    echo "bootstrap_http=${bootstrap_http}"
    echo "trusted_admin_cidrs=${trusted_admin_cidrs}"
  } >> "${GITHUB_OUTPUT}"
}

report_marketplace_diagnostics() {
  local openvpn_host="$1"
  local openvpn_user="$2"
  local private_key_file="$3"
  local known_hosts_file="$4"
  local diagnostics_exit

  echo "::group::OpenVPN Marketplace 安裝診斷"
  set +e
  # 遠端命令中的變數應由 VM shell 展開，不可由 runner 預先展開。
  # shellcheck disable=SC2016
  timeout --signal=TERM "${SSH_ATTEMPT_TIMEOUT_SECONDS}s" ssh \
    -i "${private_key_file}" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=1 \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${known_hosts_file}" \
    "${openvpn_user}@${openvpn_host}" \
    'if ! sudo -n true >/dev/null 2>&1; then
       echo "sudo=unavailable"
       exit 0
     fi

     if sudo -n test -x /usr/local/openvpn_as/scripts/sacli; then
       echo "sacli=present"
     else
       echo "sacli=absent"
     fi

     if dpkg-query -W openvpn-as >/dev/null 2>&1; then
       echo "openvpn_as_package=installed"
     else
       echo "openvpn_as_package=absent"
     fi

     printf "openvpnas_service=%s\n" "$(sudo -n systemctl is-active openvpnas 2>/dev/null || true)"
     printf "cloud_final_service=%s\n" "$(sudo -n systemctl is-active cloud-final.service 2>/dev/null || true)"

     if pgrep -x apt >/dev/null 2>&1 ||
        pgrep -x apt-get >/dev/null 2>&1 ||
        pgrep -x dpkg >/dev/null 2>&1; then
       echo "package_manager=active"
     else
       echo "package_manager=idle"
     fi

     if sudo -n test -r /var/log/stackscript.log; then
       marker_count="$(sudo -n grep -ciE "fatal:|FAILED!|Traceback|ERROR" /var/log/stackscript.log 2>/dev/null || true)"
       printf "stackscript_log=present,error_markers=%s\n" "${marker_count:-unknown}"
     else
       echo "stackscript_log=unavailable"
     fi' \
    2>/dev/null
  diagnostics_exit=$?
  set -e

  if [[ "${diagnostics_exit}" -ne 0 ]]; then
    echo "無法透過 SSH 取得 Marketplace 安裝診斷（exit code ${diagnostics_exit}）。"
  fi
  echo "::endgroup::"
}

ensure_bootstrap_http_access() (
  local plan_file='openvpn-bootstrap-http.tfplan'
  local plan_log='openvpn-bootstrap-http-plan.log'
  local apply_log='openvpn-bootstrap-http-apply.log'
  local plan_exit
  local apply_exit

  trap 'rm -f -- "${plan_file}" "${plan_log}" "${apply_log}"' EXIT

  set +e
  TF_VAR_openvpn_bootstrap_http_enabled=true terraform plan \
    -input=false \
    -detailed-exitcode \
    -target='module.openvpn.linode_firewall.openvpn' \
    -out="${plan_file}" \
    >"${plan_log}" 2>&1
  plan_exit=$?
  set -e

  filter_terraform_log "${plan_log}"

  case "${plan_exit}" in
    0)
      echo "OpenVPN bootstrap TCP/80 已處於暫時開放狀態。"
      ;;
    2)
      set +e
      terraform apply \
        -input=false \
        -auto-approve \
        "${plan_file}" \
        >"${apply_log}" 2>&1
      apply_exit=$?
      set -e

      filter_terraform_log "${apply_log}"
      if [[ "${apply_exit}" -ne 0 ]]; then
        echo "::error title=OpenVPN Bootstrap Recovery Failed::無法為尚未完成的 Marketplace 安裝暫時開啟 TCP/80"
        return "${apply_exit}"
      fi
      echo "已為尚未完成的 Marketplace 安裝暫時開啟 TCP/80。"
      ;;
    *)
      echo "::error title=OpenVPN Bootstrap Recovery Failed::無法規劃 Marketplace 安裝所需的暫時 TCP/80 規則"
      return 1
      ;;
  esac
)

refresh_bootstrap_admin_access() {
  local bootstrap_http_enabled="$1"
  local runner_ip
  local trusted_admin_cidrs
  local plan_file='openvpn-bootstrap-admin-refresh.tfplan'
  local plan_log='openvpn-bootstrap-admin-refresh-plan.log'
  local apply_log='openvpn-bootstrap-admin-refresh-apply.log'
  local plan_exit
  local apply_exit

  runner_ip="$(bash "${GITHUB_WORKSPACE}/scripts/discover-runner-public-ip.sh")"
  echo "::add-mask::${runner_ip}"
  trusted_admin_cidrs="[\"${runner_ip}/32\"]"

  if [[ "${TF_VAR_trusted_admin_cidrs:-[]}" == "${trusted_admin_cidrs}" ]]; then
    return 0
  fi

  echo "runner 公開 IPv4 在 Terraform apply 後已變更，正在刷新 OpenVPN Firewall 管理白名單。"
  export TF_VAR_openvpn_bootstrap_http_enabled="${bootstrap_http_enabled}"
  export TF_VAR_trusted_admin_cidrs="${trusted_admin_cidrs}"

  set +e
  terraform plan \
    -input=false \
    -detailed-exitcode \
    -target='module.openvpn.linode_firewall.openvpn' \
    -out="${plan_file}" \
    >"${plan_log}" 2>&1
  plan_exit=$?
  set -e

  filter_terraform_log "${plan_log}"

  case "${plan_exit}" in
    0)
      echo "OpenVPN Firewall 已包含目前 runner 管理白名單。"
      ;;
    2)
      set +e
      terraform apply \
        -input=false \
        -auto-approve \
        "${plan_file}" \
        >"${apply_log}" 2>&1
      apply_exit=$?
      set -e

      filter_terraform_log "${apply_log}"
      if [[ "${apply_exit}" -ne 0 ]]; then
        rm -f -- "${plan_file}" "${plan_log}" "${apply_log}"
        echo "::error title=OpenVPN Admin Access Refresh Failed::無法刷新 runner /32 管理白名單"
        return "${apply_exit}"
      fi
      echo "已刷新 OpenVPN Firewall 的 runner /32 管理白名單。"
      ;;
    *)
      rm -f -- "${plan_file}" "${plan_log}" "${apply_log}"
      echo "::error title=OpenVPN Admin Access Refresh Failed::無法規劃 runner /32 管理白名單"
      return 1
      ;;
  esac

  rm -f -- "${plan_file}" "${plan_log}" "${apply_log}"
}

verify_bootstrap_firewall_access() {
  local openvpn_host="$1"
  local instance_id
  local firewall_id
  local expected_cidr
  local instance_json
  local firewall_json
  local devices_json
  local rules_json
  local attempt
  local instance_running=false
  local firewall_enabled=false
  local firewall_attached=false
  local ssh_rule_matches=false
  local public_ipv4_matches=false

  instance_id="$(terraform output -raw openvpn_instance_id)"
  firewall_id="$(terraform output -raw openvpn_firewall_id)"
  expected_cidr="$(jq -er 'if length == 1 then .[0] else error("runner CIDR 數量必須為 1") end' \
    <<< "${TF_VAR_trusted_admin_cidrs:-[]}")"

  for attempt in $(seq 1 "${FIREWALL_VERIFY_ATTEMPTS}"); do
    instance_json="$(linode_api_get "/linode/instances/${instance_id}")"
    firewall_json="$(linode_api_get "/networking/firewalls/${firewall_id}")"
    devices_json="$(linode_api_get "/networking/firewalls/${firewall_id}/devices")"
    rules_json="$(linode_api_get "/networking/firewalls/${firewall_id}/rules")"

    instance_running="$(jq -r '.status == "running"' <<< "${instance_json}")"
    firewall_enabled="$(jq -r '.status == "enabled"' <<< "${firewall_json}")"
    firewall_attached="$(jq -r --argjson instance_id "${instance_id}" \
      'any(.data[]?; .entity.type == "linode" and .entity.id == $instance_id)' \
      <<< "${devices_json}")"
    ssh_rule_matches="$(jq -r --arg expected_cidr "${expected_cidr}" '
      any(
        .inbound[]?;
        .action == "ACCEPT" and
        (.protocol | ascii_upcase) == "TCP" and
        .ports == "22" and
        any(.addresses.ipv4[]?; . == $expected_cidr)
      )
    ' <<< "${rules_json}")"
    public_ipv4_matches="$(jq -r --arg openvpn_host "${openvpn_host}" \
      'any(.ipv4[]?; . == $openvpn_host)' \
      <<< "${instance_json}")"

    if [[ "${instance_running}" == "true" &&
          "${firewall_enabled}" == "true" &&
          "${firewall_attached}" == "true" &&
          "${ssh_rule_matches}" == "true" &&
          "${public_ipv4_matches}" == "true" ]]; then
      echo "OpenVPN bootstrap access 驗證通過：instance running、Firewall enabled、attachment 與 runner /32 TCP/22 rule 均正確。"
      return 0
    fi

    if ((attempt < FIREWALL_VERIFY_ATTEMPTS)); then
      echo "等待 Linode Firewall bootstrap access 生效（第 ${attempt}/${FIREWALL_VERIFY_ATTEMPTS} 次）..."
      sleep "${FIREWALL_VERIFY_RETRY_SECONDS}"
    fi
  done

  echo "::group::OpenVPN Linode Firewall 診斷"
  echo "instance_running=${instance_running}"
  echo "firewall_enabled=${firewall_enabled}"
  echo "firewall_attached_to_instance=${firewall_attached}"
  echo "ssh_rule_matches_runner_cidr=${ssh_rule_matches}"
  echo "terraform_host_matches_instance=${public_ipv4_matches}"
  echo "::endgroup::"
  echo "::error title=OpenVPN Bootstrap Access Invalid::Linode Firewall 或 instance bootstrap access 與 Terraform 預期不一致"
  return 1
}

reconcile_openvpn_admin_credential() {
  local target_env="$1"
  local openvpn_host="$2"
  local openvpn_user="$3"
  local private_key_file="$4"
  local known_hosts_file="$5"
  local work_dir="$6"
  local parameter_name="/gitops/${target_env}/openvpn/ansible/OPENVPN_ADMIN_PASSWORD"
  local password_file="${work_dir}/admin-password"
  local ssm_error_file="${work_dir}/admin-password-ssm-error.log"
  local admin_password
  local credential_exit
  local get_parameter_exit

  if [[ ! "${target_env}" =~ ^(dev|prod)$ ]]; then
    echo "::error title=OpenVPN Admin Credential Failed::不支援的環境名稱"
    return 1
  fi

  set +e
  admin_password="$(aws ssm get-parameter \
    --name "${parameter_name}" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text \
    2>"${ssm_error_file}")"
  get_parameter_exit=$?
  set -e

  if [[ "${get_parameter_exit}" -ne 0 ]]; then
    echo "::group::OpenVPN Admin password SSM 診斷"
    cat "${ssm_error_file}"
    echo "::endgroup::"
    echo "::error title=OpenVPN Admin Credential Failed::無法讀取 Terraform 管理的 Admin password SSM parameter"
    return "${get_parameter_exit}"
  fi

  echo "::add-mask::${admin_password}"
  if [[ "${#admin_password}" -lt 16 ]]; then
    echo "::error title=OpenVPN Admin Credential Failed::SSM Admin password 長度不足 16 字元"
    return 1
  fi

  install -m 0600 /dev/null "${password_file}"
  printf '%s' "${admin_password}" > "${password_file}"
  unset admin_password

  # 密碼只透過 SSH stdin 傳送；遠端暫存檔會由 trap 在所有路徑移除。
  # 遠端命令中的變數應由 VM shell 展開，不可由 runner 預先展開。
  set +e
  # shellcheck disable=SC2016
  timeout --signal=TERM 120s ssh \
    -i "${private_key_file}" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=1 \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${known_hosts_file}" \
    "${openvpn_user}@${openvpn_host}" \
    'set -euo pipefail
     umask 077
     password_file="$(mktemp "${HOME}/.openvpn-admin-password.XXXXXX")"
     trap '\''rm -f -- "${password_file}"'\'' EXIT
     cat > "${password_file}"

     if [[ ! -s "${password_file}" ]] || [[ "$(wc -c < "${password_file}")" -lt 16 ]]; then
       exit 30
     fi

     sacli=/usr/local/openvpn_as/scripts/sacli
     authcli=/usr/local/openvpn_as/scripts/authcli
     admin_password="$(<"${password_file}")"
     user_props_json="$(sudo -n "${sacli}" --pfilt openvpn UserPropGet)"

     read_prop() {
       python3 -c '\''import json, sys
data = json.load(sys.stdin).get("openvpn", {})
value = data.get(sys.argv[1], "")
print(str(value).lower() if isinstance(value, bool) else value)'\'' "$1" <<< "${user_props_json}"
     }

     auth_succeeds() {
       local auth_output
       auth_output="$(sudo -n "${authcli}" --user openvpn --pass "${admin_password}" 2>/dev/null)" &&
         grep -Eq '\''^[[:space:]]*status[[:space:]]*:[[:space:]]*SUCCEED[[:space:]]*$'\'' <<< "${auth_output}"
     }

     changed=false
     if [[ "$(read_prop user_auth_type)" != "local" ]]; then
       sudo -n "${sacli}" --user openvpn --key user_auth_type --value local UserPropPut >/dev/null
       changed=true
     fi
     if [[ "$(read_prop prop_superuser)" != "true" ]]; then
       sudo -n "${sacli}" --user openvpn --key prop_superuser --value true UserPropPut >/dev/null
       changed=true
     fi
     if [[ "$(read_prop prop_deny)" != "false" ]]; then
       sudo -n "${sacli}" --user openvpn --key prop_deny --value false UserPropPut >/dev/null
       changed=true
     fi
     if ! auth_succeeds; then
       sudo -n "${sacli}" --user openvpn --new_pass "${admin_password}" SetLocalPassword >/dev/null
       changed=true
     fi

     if [[ "${changed}" == "true" ]]; then
       sudo -n "${sacli}" start >/dev/null
     fi

     for attempt in {1..12}; do
       if auth_succeeds; then
         exit 0
       fi
       sleep 5
     done
     exit 31' \
    < "${password_file}"
  credential_exit=$?
  set -e

  rm -f -- "${password_file}" "${ssm_error_file}"

  case "${credential_exit}" in
    0)
      echo "OpenVPN Admin password 已套用至 openvpn 帳號，且 authcli 驗證成功。"
      ;;
    30)
      echo "::error title=OpenVPN Admin Credential Failed::遠端收到的 Admin password 無效"
      return 1
      ;;
    31)
      echo "::error title=OpenVPN Admin Credential Failed::authcli 未能驗證套用後的 openvpn 帳號密碼"
      return 1
      ;;
    124)
      echo "::error title=OpenVPN Admin Credential Failed::Admin credential 遠端同步超過 120 秒"
      return 1
      ;;
    255)
      echo "::error title=OpenVPN Admin Credential Failed::Admin credential 同步期間 SSH 連線失敗"
      return 1
      ;;
    *)
      echo "::error title=OpenVPN Admin Credential Failed::遠端同步失敗（exit code ${credential_exit}）"
      return 1
      ;;
  esac
}

wait_for_marketplace_readiness() {
  local target_env="${TARGET_ENV:?TARGET_ENV 未設定}"
  local runner_temp="${RUNNER_TEMP:?RUNNER_TEMP 未設定}"
  local bootstrap_http_enabled="${BOOTSTRAP_HTTP_ENABLED:-false}"
  local openvpn_host
  local openvpn_user
  local private_key_b64
  local host_key
  local work_dir="${runner_temp}/openvpn-bootstrap"
  local ssh_error_file="${work_dir}/ssh-error.log"
  local deadline
  local attempt
  local ssh_exit
  local last_reason='尚未執行 readiness 檢查'
  local remaining
  local sleep_seconds

  openvpn_host="$(terraform output -raw openvpn_public_ipv4)"
  openvpn_user="$(terraform output -json openvpn_network_ansible_config | jq -r '.openvpn_ssh_user')"
  private_key_b64="$(aws ssm get-parameter \
    --name "/gitops/${target_env}/openvpn/ansible/OPENVPN_SSH_PRIVATE_KEY_B64" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text)"
  host_key="$(aws ssm get-parameter \
    --name "/gitops/${target_env}/openvpn/ansible/OPENVPN_SSH_HOST_KEY" \
    --query 'Parameter.Value' \
    --output text)"

  echo "::add-mask::${private_key_b64}"
  echo "::add-mask::${host_key}"

  mkdir -p "${work_dir}"
  install -m 0600 /dev/null "${work_dir}/id_openvpn"
  printf '%s' "${private_key_b64}" | base64 --decode > "${work_dir}/id_openvpn"
  printf '%s %s\n' "${openvpn_host}" "${host_key}" > "${work_dir}/known_hosts"

  refresh_bootstrap_admin_access "${bootstrap_http_enabled}"
  verify_bootstrap_firewall_access "${openvpn_host}"

  deadline=$((SECONDS + READINESS_TIMEOUT_SECONDS))
  attempt=0

  while ((SECONDS < deadline)); do
    attempt=$((attempt + 1))

    if ((attempt > 1 && (attempt - 1) % RUNNER_IP_RECHECK_ATTEMPTS == 0)); then
      refresh_bootstrap_admin_access "${bootstrap_http_enabled}"
      verify_bootstrap_firewall_access "${openvpn_host}"
    fi

    set +e
    timeout --signal=TERM "${SSH_ATTEMPT_TIMEOUT_SECONDS}s" ssh \
      -i "${work_dir}/id_openvpn" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o ServerAliveInterval=5 \
      -o ServerAliveCountMax=1 \
      -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="${work_dir}/known_hosts" \
      "${openvpn_user}@${openvpn_host}" \
      'if ! sudo -n true 2>/dev/null; then exit 20; fi
       if ! sudo -n test -x /usr/local/openvpn_as/scripts/sacli; then exit 21; fi
       if ! sudo -n systemctl is-active --quiet openvpnas; then exit 22; fi
       if ! sudo -n /usr/local/openvpn_as/scripts/sacli status >/dev/null 2>&1; then exit 23; fi' \
      2>"${ssh_error_file}"
    ssh_exit=$?
    set -e

    if [[ "${ssh_exit}" -eq 0 ]]; then
      echo "OpenVPN Access Server 已完成 Marketplace bootstrap。"
      reconcile_openvpn_admin_credential \
        "${target_env}" \
        "${openvpn_host}" \
        "${openvpn_user}" \
        "${work_dir}/id_openvpn" \
        "${work_dir}/known_hosts" \
        "${work_dir}"
      return 0
    fi

    if [[ "${bootstrap_http_enabled}" == "false" && "${ssh_exit}" =~ ^(21|22|23)$ ]]; then
      echo "已確認既有 VM 的 Marketplace 安裝尚未 ready，恢復 bootstrap TCP/80 後繼續等待。"
      ensure_bootstrap_http_access
      bootstrap_http_enabled=true
    fi

    last_reason="$(describe_readiness_failure "${ssh_exit}" "${ssh_error_file}")"
    remaining=$((deadline - SECONDS))
    if ((remaining <= 0)); then
      break
    fi

    echo "等待 OpenVPN Access Server ready（第 ${attempt} 次；原因：${last_reason}；剩餘約 ${remaining} 秒）..."
    sleep_seconds=${READINESS_RETRY_SECONDS}
    if ((sleep_seconds > remaining)); then
      sleep_seconds=${remaining}
    fi
    sleep "${sleep_seconds}"
  done

  report_marketplace_diagnostics \
    "${openvpn_host}" \
    "${openvpn_user}" \
    "${work_dir}/id_openvpn" \
    "${work_dir}/known_hosts"
  echo "::error title=OpenVPN Bootstrap Timeout::Access Server 未在 ${READINESS_TIMEOUT_SECONDS} 秒內 ready；最後原因：${last_reason}"
  return 1
}

close_bootstrap_access() {
  local runner_temp="${RUNNER_TEMP:?RUNNER_TEMP 未設定}"
  local work_dir="${runner_temp}/openvpn-bootstrap"
  local state_list
  local state_exit
  local plan_exit
  local apply_exit

  rm -f \
    "${work_dir}/id_openvpn" \
    "${work_dir}/known_hosts" \
    "${work_dir}/ssh-error.log" \
    "${work_dir}/admin-password" \
    "${work_dir}/admin-password-ssm-error.log"
  rmdir "${work_dir}" 2>/dev/null || true

  set +e
  state_list="$(terraform state list 2>openvpn-bootstrap-cleanup-state.err)"
  state_exit=$?
  set -e

  if [[ "${state_exit}" -ne 0 ]]; then
    cat openvpn-bootstrap-cleanup-state.err
    echo "::error title=OpenVPN Cleanup Failed::無法讀取 Terraform state，拒絕略過 bootstrap cleanup"
    return "${state_exit}"
  fi

  if ! grep -Eq "${OPENVPN_FIREWALL_PATTERN}" <<< "${state_list}"; then
    echo "OpenVPN Firewall 尚未進入 Terraform state，無需執行 bootstrap cleanup。"
    return 0
  fi

  set +e
  terraform plan \
    -input=false \
    -detailed-exitcode \
    -target='module.openvpn.linode_firewall.openvpn' \
    -out=openvpn-bootstrap-cleanup.tfplan \
    > openvpn-bootstrap-cleanup-plan.log 2>&1
  plan_exit=$?
  set -e

  filter_terraform_log openvpn-bootstrap-cleanup-plan.log

  case "${plan_exit}" in
    0)
      echo "OpenVPN bootstrap access 已關閉。"
      ;;
    2)
      set +e
      terraform apply \
        -input=false \
        -auto-approve \
        openvpn-bootstrap-cleanup.tfplan \
        > openvpn-bootstrap-cleanup-apply.log 2>&1
      apply_exit=$?
      set -e

      filter_terraform_log openvpn-bootstrap-cleanup-apply.log
      if [[ "${apply_exit}" -ne 0 ]]; then
        echo "::error title=OpenVPN Cleanup Failed::套用 bootstrap cleanup plan 失敗"
        return "${apply_exit}"
      fi
      ;;
    *)
      echo "::error title=OpenVPN Cleanup Failed::無法產生 bootstrap cleanup plan"
      return 1
      ;;
  esac
}

main() {
  case "${1:-}" in
    resolve)
      resolve_bootstrap_access
      ;;
    wait)
      wait_for_marketplace_readiness
      ;;
    close)
      close_bootstrap_access
      ;;
    *)
      echo "用法：$0 <resolve|wait|close>" >&2
      return 2
      ;;
  esac
}

main "$@"
