terraform {
  required_version = ">= 1.5.0"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.41"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Remote state: copy backend.tf.example → backend.tf and configure before init.
}

provider "linode" {
  token = var.linode_token != "" ? var.linode_token : null
}
