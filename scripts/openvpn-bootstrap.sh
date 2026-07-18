#!/usr/bin/env bash

# 封裝 Phase 1 的 OpenVPN Marketplace bootstrap 生命週期。
# Workflow 只負責傳入環境與 Terraform 變數；本腳本不管理後續 Ansible desired state。
set -euo pipefail

readonly OPENVPN_INSTANCE_PATTERN='^module\.openvpn\.linode_instance\.openvpn(\[0\])?$'
readonly OPENVPN_FIREWALL_PATTERN='^module\.openvpn\.linode_firewall\.openvpn(\[0\])?$'
readonly READINESS_TIMEOUT_SECONDS=600
readonly READINESS_RETRY_SECONDS=10
readonly SSH_ATTEMPT_TIMEOUT_SECONDS=15

filter_terraform_log() {
  local log_file="$1"

  grep -v -iE '^\s*(token|secret|pass[w]ord)\s*=' "${log_file}" || true
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
  local bootstrap_needed=false
  local bootstrap_http=false
  local trusted_admin_cidrs='[]'
  local runner_ip
  local replacement_exit
  local state_list

  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT 未設定}"
  : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE 未設定}"

  if [[ "${bootstrap_requested}" == "true" ]]; then
    state_list="$(terraform state list)"

    if ! grep -Eq "${OPENVPN_INSTANCE_PATTERN}" <<< "${state_list}"; then
      bootstrap_needed=true
    elif openvpn_requires_replacement; then
      bootstrap_needed=true
    else
      replacement_exit=$?
      if [[ "${replacement_exit}" -ne 1 ]]; then
        return "${replacement_exit}"
      fi
    fi
  fi

  if [[ "${bootstrap_needed}" == "true" ]]; then
    runner_ip="$(bash "${GITHUB_WORKSPACE}/scripts/discover-runner-public-ip.sh")"
    echo "::add-mask::${runner_ip}"

    bootstrap_http=true
    trusted_admin_cidrs="[\"${runner_ip}/32\"]"
  fi

  {
    echo "needed=${bootstrap_needed}"
    echo "bootstrap_http=${bootstrap_http}"
    echo "trusted_admin_cidrs=${trusted_admin_cidrs}"
  } >> "${GITHUB_OUTPUT}"
}

wait_for_marketplace_readiness() {
  local target_env="${TARGET_ENV:?TARGET_ENV 未設定}"
  local runner_temp="${RUNNER_TEMP:?RUNNER_TEMP 未設定}"
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

  deadline=$((SECONDS + READINESS_TIMEOUT_SECONDS))
  attempt=0

  while ((SECONDS < deadline)); do
    attempt=$((attempt + 1))

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
      return 0
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

  rm -f "${work_dir}/id_openvpn" "${work_dir}/known_hosts" "${work_dir}/ssh-error.log"
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
