#!/usr/bin/env bash

# 本 repo 自有的 automation VPN tunnel adapter；只處理 runner-local OpenVPN
# process 與精確的 split-tunnel host routes，Cloud、Firewall 與 Access Server
# desired state 由 gitops-demo-platform-access 管理，本檔案不得反向依賴該
# repo 的 Git layout、branch、tag 或 commit SHA。
set -euo pipefail

mode="${1:-}"
state_directory="${2:-}"

[[ "${mode}" == "open" || "${mode}" == "close" ]] || {
  echo "mode must be open or close" >&2
  exit 2
}
[[ -n "${RUNNER_TEMP:-}" && -n "${state_directory}" ]] || {
  echo "RUNNER_TEMP and state directory are required" >&2
  exit 2
}

runner_temp_real="$(realpath -m -- "${RUNNER_TEMP}")"
state_directory_real="$(realpath -m -- "${state_directory}")"
case "${state_directory_real}" in
  "${runner_temp_real}"/automation-vpn-*) ;;
  *)
    echo "state directory is outside the approved runner temporary scope" >&2
    exit 2
    ;;
esac

close_tunnel() {
  local pid=""

  if [[ -f "${state_directory_real}/openvpn.pid" ]]; then
    pid="$(sudo cat "${state_directory_real}/openvpn.pid" 2>/dev/null || true)"
  fi
  if [[ "${pid}" =~ ^[1-9][0-9]*$ ]] &&
    [[ -r "/proc/${pid}/comm" ]] &&
    [[ "$(<"/proc/${pid}/comm")" == "openvpn" ]]; then
    sudo kill -TERM "${pid}"
    for _ in {1..20}; do
      [[ ! -d "/proc/${pid}" ]] && break
      sleep 1
    done
    if [[ -d "/proc/${pid}" ]]; then
      sudo kill -KILL "${pid}"
    fi
  fi

  sudo rm -rf -- "${state_directory_real}"
}

if [[ "${mode}" == "close" ]]; then
  close_tunnel
  echo "Automation VPN tunnel closed."
  exit 0
fi

cleanup_on_error() {
  local exit_code=$?
  trap - EXIT
  # close_tunnel 會把 state_directory_real 整個砍掉，openvpn.log 會跟著消失，
  # 之後完全看不出握手失敗的真正原因。在砍之前先把它印到 stderr，讓失敗
  # 原因留在 CI log 裡；log 內容只含 OpenVPN 協定訊息，不含 password。
  if [[ -f "${state_directory_real}/openvpn.log" ]]; then
    echo "----- openvpn.log (dumped before cleanup) -----" >&2
    sudo cat "${state_directory_real}/openvpn.log" >&2 || true
    echo "----- end openvpn.log -----" >&2
  fi
  close_tunnel
  exit "${exit_code}"
}
trap cleanup_on_error EXIT

identity="${AUTOMATION_VPN_IDENTITY:-}"
profile_path="${VPN_PROFILE_PATH:-}"
password_path="${VPN_PASSWORD_PATH:-}"
expected_tunnel_ip="${VPN_EXPECTED_TUNNEL_IP:-}"
route_targets="${VPN_ROUTE_TARGETS:-}"
health_targets="${VPN_HEALTH_TARGETS:-}"

# 本 repo 只擁有並使用 ci-cluster 這一個 automation 身份；不接受其他 repo
# 的身份名稱，避免這份 local script 被誤用成跨 repo 共用元件。
[[ "${identity}" == "ci-cluster" ]] || {
  echo "invalid automation VPN identity for gitops-demo-cluster" >&2
  exit 2
}
if [[ -n "${expected_tunnel_ip}" ]] &&
  [[ ! "${expected_tunnel_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "invalid expected tunnel IPv4 address" >&2
  exit 2
fi
for required_file in "${profile_path}" "${password_path}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" ]] || {
    echo "automation VPN credential file is missing" >&2
    exit 2
  }
done
[[ -n "${route_targets//[[:space:]]/}" ]] || {
  echo "at least one split-tunnel route target is required" >&2
  exit 2
}
[[ -n "${health_targets//[[:space:]]/}" ]] || {
  echo "at least one tunnel health target is required" >&2
  exit 2
}

if grep -Eiq '^[[:space:]]*(script-security|up|down|route-up|plugin)[[:space:]]' "${profile_path}"; then
  echo "automation VPN profile contains a prohibited local execution directive" >&2
  exit 1
fi

mkdir -p "${state_directory_real}"
chmod 700 "${state_directory_real}"
auth_file="${state_directory_real}/auth"
routes_file="${state_directory_real}/routes"
default_interface_file="${state_directory_real}/default-interface"
umask 077
{
  printf '%s\n' "${identity}"
  cat "${password_path}"
  printf '\n'
} > "${auth_file}"

default_interface="$(
  ip -4 route show default |
    awk 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
)"
[[ -n "${default_interface}" ]] || {
  echo "unable to resolve the runner default interface" >&2
  exit 1
}
printf '%s\n' "${default_interface}" > "${default_interface_file}"

# DNS 只在這個迴圈解析一次：每個 route target 的主機名稱只查一次
# getent，解析結果同時寫進 routes_file（用來下 host route）與
# host_resolved_ips（用來讓下面的 health check 重用同一組 IPv4，不再對
# 同一個主機名稱重新查一次 DNS，避免 health probe 探測到未安裝 host
# route 的另一個 IP）。
: > "${routes_file}"
declare -A host_resolved_ips
while IFS= read -r raw_target; do
  target="${raw_target#"${raw_target%%[![:space:]]*}"}"
  target="${target%"${target##*[![:space:]]}"}"
  [[ -n "${target}" ]] || continue
  target="${target#*://}"
  target="${target%%/*}"
  target="${target%%:*}"
  [[ "${target}" =~ ^[A-Za-z0-9.-]+$ ]] || {
    echo "invalid split-tunnel route target" >&2
    exit 2
  }

  if [[ "${target}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "${target}" >> "${routes_file}"
    host_resolved_ips["${target}"]="${target}"
  else
    mapfile -t resolved_ips < <(
      getent ahostsv4 "${target}" | awk '{print $1}' | sort -u
    )
    [[ "${#resolved_ips[@]}" -gt 0 ]] || {
      echo "route target did not resolve to an IPv4 address" >&2
      exit 1
    }
    printf '%s\n' "${resolved_ips[@]}" >> "${routes_file}"
    host_resolved_ips["${target}"]="$(printf '%s\n' "${resolved_ips[@]}")"
  fi
done <<< "${route_targets}"
sort -u -o "${routes_file}" "${routes_file}"
[[ -s "${routes_file}" ]] || {
  echo "split-tunnel targets did not resolve to IPv4 addresses" >&2
  exit 1
}

openvpn_arguments=(
  --config "${profile_path}"
  --auth-user-pass "${auth_file}"
  --auth-nocache
  --route-nopull
  --persist-key
  --persist-tun
  --writepid "${state_directory_real}/openvpn.pid"
  --log "${state_directory_real}/openvpn.log"
  --daemon "automation-vpn-${identity}"
)
while IFS= read -r route_ip; do
  openvpn_arguments+=(--route "${route_ip}" 255.255.255.255)
done < "${routes_file}"

sudo openvpn "${openvpn_arguments[@]}"

ready=""
for _ in {1..60}; do
  pid="$(sudo cat "${state_directory_real}/openvpn.pid" 2>/dev/null || true)"
  if [[ "${pid}" =~ ^[1-9][0-9]*$ ]] &&
    sudo grep -q "Initialization Sequence Completed" "${state_directory_real}/openvpn.log" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 2
done
[[ -n "${ready}" ]] || {
  echo "automation VPN tunnel did not become ready before timeout" >&2
  exit 1
}

tunnel_interface=""
while IFS= read -r route_ip; do
  route="$(ip -4 route get "${route_ip}")"
  route_interface="$(
    awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<< "${route}"
  )"
  [[ -n "${route_interface}" && "${route_interface}" != "${default_interface}" ]] || {
    echo "split-tunnel route did not use the VPN interface" >&2
    exit 1
  }
  if [[ -z "${tunnel_interface}" ]]; then
    tunnel_interface="${route_interface}"
  elif [[ "${route_interface}" != "${tunnel_interface}" ]]; then
    echo "split-tunnel routes resolved to different VPN interfaces" >&2
    exit 1
  fi
done < "${routes_file}"
printf '%s\n' "${tunnel_interface}" > "${state_directory_real}/tunnel-interface"

if [[ -n "${expected_tunnel_ip}" ]]; then
  actual_tunnel_ip="$(
    ip -4 -o address show dev "${tunnel_interface}" |
      awk 'NR == 1 {sub(/\/.*/, "", $4); print $4}'
  )"
  [[ "${actual_tunnel_ip}" == "${expected_tunnel_ip}" ]] || {
    echo "::error title=Automation VPN Identity Mismatch::tunnel interface ${tunnel_interface} has IPv4 ${actual_tunnel_ip:-<none>}, expected ${expected_tunnel_ip} for identity ${identity}" >&2
    exit 1
  }
fi

# Health check 重用上面解析路由時得到的 host_resolved_ips，不再對同一個
# 主機名稱重新呼叫一次 DNS。所有 target 共用 deadline，但每輪都會輪詢尚未
# 成功的 target；同一 target 的任一 gateway 可達即通過，避免第一個 target
# 獨占整段等待時間，讓後續 target 完全沒有被探測。
health_check_timeout_seconds=300
health_probe_timeout_seconds=10
health_retry_interval_seconds=10
health_check_started_at="${SECONDS}"
health_check_deadline=$((SECONDS + health_check_timeout_seconds))

declare -a health_target_keys=()
declare -A health_target_hosts
declare -A health_target_ports
declare -A health_target_ip_lists
declare -A health_target_ip_csvs
declare -A health_target_rounds
declare -A health_target_probe_counts
declare -A health_target_reachable
while IFS= read -r health_target; do
  health_target="${health_target#"${health_target%%[![:space:]]*}"}"
  health_target="${health_target%"${health_target##*[![:space:]]}"}"
  [[ -n "${health_target}" ]] || continue
  health_host="${health_target%:*}"
  health_port="${health_target##*:}"
  [[ "${health_host}" =~ ^[A-Za-z0-9.-]+$ ]] || {
    echo "invalid tunnel health host" >&2
    exit 2
  }
  if [[ ! "${health_port}" =~ ^[1-9][0-9]{0,4}$ ]] ||
    ((10#"${health_port}" > 65535)); then
    echo "invalid tunnel health port" >&2
    exit 2
  fi

  health_ip_list="${host_resolved_ips[${health_host}]:-}"
  [[ -n "${health_ip_list}" ]] || {
    echo "::error title=Automation VPN Health Target Unresolved::${health_host} has no corresponding resolved route; health-targets host must match a route-targets host so both use the same resolved IPv4" >&2
    exit 2
  }
  mapfile -t health_ips <<< "${health_ip_list}"
  health_ip_csv="$(IFS=,; printf '%s' "${health_ips[*]}")"
  health_key="${health_host}:${health_port}"
  [[ -z "${health_target_hosts[${health_key}]:-}" ]] || {
    echo "duplicate tunnel health target" >&2
    exit 2
  }

  health_target_keys+=("${health_key}")
  health_target_hosts["${health_key}"]="${health_host}"
  health_target_ports["${health_key}"]="${health_port}"
  health_target_ip_lists["${health_key}"]="${health_ip_list}"
  health_target_ip_csvs["${health_key}"]="${health_ip_csv}"
  health_target_rounds["${health_key}"]=0
  health_target_probe_counts["${health_key}"]=0
done <<< "${health_targets}"

while true; do
  for health_key in "${health_target_keys[@]}"; do
    [[ -z "${health_target_reachable[${health_key}]:-}" ]] || continue

    health_host="${health_target_hosts[${health_key}]}"
    health_port="${health_target_ports[${health_key}]}"
    mapfile -t health_ips <<< "${health_target_ip_lists[${health_key}]}"
    health_target_rounds["${health_key}"]=$((health_target_rounds[${health_key}] + 1))

    for health_ip in "${health_ips[@]}"; do
      health_remaining_seconds=$((health_check_deadline - SECONDS))
      if ((health_remaining_seconds <= 0)); then
        break
      fi
      health_target_probe_counts["${health_key}"]=$((health_target_probe_counts[${health_key}] + 1))
      health_attempt_timeout="${health_probe_timeout_seconds}"
      if ((health_remaining_seconds < health_probe_timeout_seconds)); then
        health_attempt_timeout="${health_remaining_seconds}"
      fi
      if timeout "${health_attempt_timeout}" \
        bash -c "exec 3<>\"/dev/tcp/\$1/\$2\"" _ \
        "${health_ip}" "${health_port}"; then
        health_target_reachable["${health_key}"]=1
        break
      fi
    done
  done

  all_health_targets_reachable=1
  for health_key in "${health_target_keys[@]}"; do
    if [[ -z "${health_target_reachable[${health_key}]:-}" ]]; then
      all_health_targets_reachable=""
      break
    fi
  done
  [[ -z "${all_health_targets_reachable}" ]] || break

  health_remaining_seconds=$((health_check_deadline - SECONDS))
  if ((health_remaining_seconds <= 0)); then
    health_elapsed_seconds=$((SECONDS - health_check_started_at))
    {
      for health_key in "${health_target_keys[@]}"; do
        [[ -z "${health_target_reachable[${health_key}]:-}" ]] || continue
        health_host="${health_target_hosts[${health_key}]}"
        health_port="${health_target_ports[${health_key}]}"
        health_ip_csv="${health_target_ip_csvs[${health_key}]}"
        echo "::error title=Automation VPN Health Check Failed::target=${health_host} tested-ipv4s=${health_ip_csv} port=${health_port} rounds=${health_target_rounds[${health_key}]} probes=${health_target_probe_counts[${health_key}]} elapsed-seconds=${health_elapsed_seconds}"
        mapfile -t health_ips <<< "${health_target_ip_lists[${health_key}]}"
        for health_ip in "${health_ips[@]}"; do
          echo "----- ip route get ${health_ip} -----"
          ip route get "${health_ip}" 2>&1 || true
        done
      done
      echo "----- tunnel interface -----"
      cat "${state_directory_real}/tunnel-interface" 2>/dev/null || echo "(unavailable)"
    } >&2
    exit 1
  fi

  health_retry_sleep="${health_retry_interval_seconds}"
  if ((health_remaining_seconds < health_retry_interval_seconds)); then
    health_retry_sleep="${health_remaining_seconds}"
  fi
  for health_key in "${health_target_keys[@]}"; do
    [[ -z "${health_target_reachable[${health_key}]:-}" ]] || continue
    echo "Automation VPN health check 尚未就緒：target=${health_target_hosts[${health_key}]} tested-ipv4s=${health_target_ip_csvs[${health_key}]} port=${health_target_ports[${health_key}]} round=${health_target_rounds[${health_key}]} probes=${health_target_probe_counts[${health_key}]}，將於 ${health_retry_sleep} 秒後重試（剩餘 ${health_remaining_seconds} 秒）。" >&2
  done
  sleep "${health_retry_sleep}"
done

trap - EXIT
echo "Automation VPN tunnel opened with isolated host routes."
