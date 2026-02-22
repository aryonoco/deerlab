# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

resource "proxmox_virtual_environment_cluster_firewall" "this" {
  enabled       = local.cluster_firewall_enabled
  input_policy  = local.cluster_firewall_input_policy
  output_policy = local.cluster_firewall_output_policy

  log_ratelimit {
    enabled = local.cluster_firewall_log_ratelimit_enabled
    rate    = local.cluster_firewall_log_ratelimit_rate
    burst   = local.cluster_firewall_log_ratelimit_burst
  }
}

resource "proxmox_virtual_environment_firewall_rules" "cluster" {
  depends_on = [proxmox_virtual_environment_cluster_firewall.this]

  dynamic "rule" {
    for_each = local.cluster_firewall_rules
    content {
      action  = rule.value.action
      type    = rule.value.type
      proto   = rule.value.proto
      dport   = rule.value.dport
      sport   = rule.value.sport
      source  = rule.value.source
      dest    = rule.value.dest
      comment = rule.value.comment
      log     = rule.value.log
      enabled = rule.value.enabled
    }
  }
}

# --- Per-container firewall ---

resource "proxmox_virtual_environment_firewall_options" "containers" {
  for_each = local.container_firewalls

  node_name    = local.proxmox_node
  container_id = each.value.vmid

  enabled       = each.value.firewall.enabled
  input_policy  = each.value.firewall.input_policy
  output_policy = each.value.firewall.output_policy

  depends_on = [proxmox_virtual_environment_container.this]
}

resource "proxmox_virtual_environment_firewall_rules" "containers" {
  for_each = local.container_firewalls

  node_name    = local.proxmox_node
  container_id = each.value.vmid

  dynamic "rule" {
    for_each = each.value.firewall.rules
    content {
      action  = rule.value.action
      type    = rule.value.type
      proto   = rule.value.proto
      dport   = rule.value.dport
      sport   = rule.value.sport
      source  = rule.value.source
      dest    = rule.value.dest
      iface   = rule.value.iface
      comment = rule.value.comment
      log     = rule.value.log
      enabled = rule.value.enabled
    }
  }

  depends_on = [proxmox_virtual_environment_firewall_options.containers]
}
