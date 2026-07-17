variable "label" {
  description = "OpenVPN Linode label。"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{1,62}[a-zA-Z0-9]$", var.label))
    error_message = "label 必須是 3 至 64 個可接受的 Linode label 字元。"
  }
}

variable "region" {
  description = "OpenVPN Linode region。"
  type        = string
}

variable "instance_type" {
  description = "OpenVPN Linode instance type。"
  type        = string
  default     = "g6-standard-1"
}

variable "image" {
  description = "Marketplace StackScript 支援的 image。"
  type        = string
  default     = "linode/ubuntu24.04"

  validation {
    condition     = var.image == "linode/ubuntu24.04"
    error_message = "目前 OpenVPN Marketplace StackScript 401719 僅宣告支援 linode/ubuntu24.04。"
  }
}

variable "stackscript_id" {
  description = "經 Linode API 驗證的 OpenVPN One-Click StackScript ID。變更會重建 Linode。"
  type        = number
  default     = 401719

  validation {
    condition     = var.stackscript_id > 0 && floor(var.stackscript_id) == var.stackscript_id
    error_message = "stackscript_id 必須是正整數。"
  }
}

variable "stackscript_data" {
  description = "Marketplace UDF。必須提供 user_name 與 soa_email_address；不得提供 API token 或 public DNS 欄位。"
  type        = map(string)
  default     = {}
  sensitive   = true

  validation {
    condition = alltrue([
      for key in keys(var.stackscript_data) : contains([
        "user_name",
        "disable_root",
        "soa_email_address",
        "add_ons",
      ], key)
    ])
    error_message = "stackscript_data 僅允許 user_name、disable_root、soa_email_address 與 add_ons；本架構不建立 public DNS，也不把 Linode API token 傳入 StackScript。"
  }
}

variable "root_password" {
  description = "Terraform 產生的 Linode root password。"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Terraform 產生、允許 Ansible 登入 OpenVPN Linode 的 SSH public key。"
  type        = string
}

variable "ssh_host_private_key" {
  description = "Terraform 產生並由 cloud-init 安裝的 OpenVPN SSH Ed25519 host private key。"
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "OpenVPN Linode 與 Firewall tags。"
  type        = list(string)
  default     = ["gitops-demo", "openvpn"]
}

variable "openvpn_port" {
  description = "對 VPN client 開放的 OpenVPN listener port。"
  type        = number
  default     = 1194

  validation {
    condition     = var.openvpn_port == 1194
    error_message = "目前 Marketplace Access Server listener contract 僅支援 UDP/1194；變更 listener 前必須同步實作 sacli port 設定。"
  }
}

variable "openvpn_protocol" {
  description = "OpenVPN listener protocol。"
  type        = string
  default     = "udp"

  validation {
    condition     = var.openvpn_protocol == "udp"
    error_message = "目前 Marketplace Access Server listener contract 僅支援 UDP/1194。"
  }
}

variable "enable_ipv6" {
  description = "是否對 IPv6 開放 OpenVPN listener；未明確啟用時保持關閉。"
  type        = bool
  default     = false
}

variable "bootstrap_http_enabled" {
  description = "是否暫時開放 Marketplace certbot bootstrap 所需 TCP/80；Access Server healthy 後必須關閉。"
  type        = bool
  default     = false
}

variable "admin_port" {
  description = "OpenVPN Access Server Admin/Client Web UI port。"
  type        = number
  default     = 943

  validation {
    condition     = var.admin_port == 943
    error_message = "目前 Marketplace Access Server Admin UI contract 固定為 TCP/943。"
  }
}

variable "trusted_admin_cidrs" {
  description = "暫時允許 SSH 與 Access Server Admin UI 的來源 CIDR；環境穩態必須傳入空清單。"
  type        = list(string)

  validation {
    condition = alltrue([
      for cidr in var.trusted_admin_cidrs : can(cidrhost(cidr, 0)) && !contains(["0.0.0.0/0", "::/0"], cidr)
    ])
    error_message = "trusted_admin_cidrs 只能包含有效且非全開的 CIDR。"
  }
}

variable "expected_public_ipv4" {
  description = "選用的預期 public IPv4；若指定，apply 只核對 Linode 實際位址，不會保留、配置或重新附加 IP。"
  type        = string
  default     = null

  validation {
    condition     = var.expected_public_ipv4 == null ? true : can(cidrnetmask("${var.expected_public_ipv4}/32"))
    error_message = "expected_public_ipv4 必須是未帶 CIDR suffix 的 IPv4。"
  }
}
