terraform {
  required_version = ">= 1.10.0"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.41"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "linode" {
  # 省略 token 時使用 LINODE_TOKEN 環境變數。
  token = var.linode_token != "" ? var.linode_token : null
}

provider "aws" {
  region = var.aws_region
}
