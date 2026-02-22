# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

provider "proxmox" {
  endpoint  = local.proxmox_endpoint
  api_token = local.proxmox_api_token
  insecure  = local.proxmox_insecure

  ssh {
    agent    = true
    username = local.proxmox_ssh_user
  }
}
