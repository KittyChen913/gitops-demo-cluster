#!/usr/bin/env bash

# 封裝 Phase 1 的 OpenVPN Marketplace bootstrap 生命週期。
# Workflow 只負責傳入環境與 Terraform 變數；本腳本不管理後續 Ansible desired state。
set -euo pipefail

readonly OPENVPN_INSTANCE_PATTERN='^module\.openvpn\.linode_instance\.openvpn(\[0\])?$'
readonly OPENVPN_FIREWALL_PATTERN='^module\.openvpn\.linode_firewall\.openvpn(\[0\])?$'

filter_terraform_log() {
  local log_file="$1"

  grep -v -iE '^\s*(token|secret|pass[w]ord)\s*=' "${log_file}" || true
}

resolve_bootstrap_access() {
  local bootstrap_requested="${BOOTSTRAP_REQUESTED:-false}"
  local bootstrap_needed=false
  local bootstrap_http=false
  local trusted_admin_cidrs='[]'
  local runner_ip

  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT 未設定}"
  : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE 未設定}"

  if [[ "${bootstrap_requested}" == "true" ]] && \
     ! terraform state list 2>/dev/null | grep -Eq "${OPENVPN_INSTANCE_PATTERN}"; then
    runner_ip="$(bash "${GITHUB_WORKSPACE}/scripts/discover-runner-public-ip.sh")"
    echo "::add-mask::${runner_ip}"

    bootstrap_needed=true
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
  local attempt

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

  for attempt in $(seq 1 60); do
    if ssh \
      -i "${work_dir}/id_openvpn" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="${work_dir}/known_hosts" \
      "${openvpn_user}@${openvpn_host}" \
      'sudo systemctl is-active --quiet openvpnas && sudo /usr/local/openvpn_as/scripts/sacli status >/dev/null' \
      2>/dev/null; then
      echo "OpenVPN Access Server 已完成 Marketplace bootstrap。"
      return 0
    fi

    echo "等待 OpenVPN Access Server ready（${attempt}/60）..."
    sleep 10
  done

  echo "::error title=OpenVPN Bootstrap Timeout::Access Server 未在 10 分鐘內 ready"
  return 1
}

close_bootstrap_access() {
  local runner_temp="${RUNNER_TEMP:?RUNNER_TEMP 未設定}"
  local work_dir="${runner_temp}/openvpn-bootstrap"
  local state_list
  local state_exit
  local plan_exit
  local apply_exit

  rm -f "${work_dir}/id_openvpn" "${work_dir}/known_hosts"
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
