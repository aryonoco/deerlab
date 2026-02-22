# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

ephemeral "sops_file" "secrets" {
  source_file = "${path.module}/../inventory/group_vars/proxmox/secrets.sops.yaml"
}

data "sops_file" "tfvars" {
  source_file = "${path.module}/terraform.tfvars.sops.json"
}

locals {
  inventory    = yamldecode(file("${path.module}/../inventory/hosts.yml"))
  proxmox_node = one(keys(local.inventory.all.children.proxmox.hosts))

  proxmox_fqdn      = "${local.proxmox_node}.${ephemeral.sops_file.secrets.data["proxmox_install_domain"]}"
  proxmox_endpoint  = "https://${local.proxmox_fqdn}:8006/"
  proxmox_ssh_user  = ephemeral.sops_file.secrets.data["ansible_user"]
  proxmox_api_token = "root@pam!ansible=${ephemeral.sops_file.secrets.data["proxmox_api_token_secret"]}"

  tfvars           = nonsensitive(jsondecode(data.sops_file.tfvars.raw))
  proxmox_insecure = local.tfvars.proxmox_insecure
  containers       = local.tfvars.containers
  templates        = local.tfvars.templates

  cluster_firewall_enabled               = local.tfvars.cluster_firewall_enabled
  cluster_firewall_input_policy          = local.tfvars.cluster_firewall_input_policy
  cluster_firewall_output_policy         = local.tfvars.cluster_firewall_output_policy
  cluster_firewall_log_ratelimit_enabled = local.tfvars.cluster_firewall_log_ratelimit_enabled
  cluster_firewall_log_ratelimit_rate    = local.tfvars.cluster_firewall_log_ratelimit_rate
  cluster_firewall_log_ratelimit_burst   = local.tfvars.cluster_firewall_log_ratelimit_burst
  cluster_firewall_rules                 = local.tfvars.cluster_firewall_rules

  container_firewalls = {
    for k, v in local.containers : k => v
    if lookup(v, "firewall", null) != null
  }
}
