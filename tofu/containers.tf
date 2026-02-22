# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

resource "proxmox_virtual_environment_container" "this" {
  for_each = local.containers

  node_name    = local.proxmox_node
  vm_id        = each.value.vmid
  description  = "Managed by OpenTofu"
  tags         = each.value.tags
  started      = each.value.started
  unprivileged = each.value.unprivileged

  start_on_boot = lookup(each.value, "start_on_boot", false)

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.templates[each.value.template].id
    type             = "debian"
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = each.value.datastore_id
    size         = each.value.disk_size
  }

  dynamic "features" {
    for_each = lookup(each.value, "features", null) != null ? [each.value.features] : []
    content {
      nesting = lookup(features.value, "nesting", false)
      keyctl  = lookup(features.value, "keyctl", false)
      fuse    = lookup(features.value, "fuse", false)
    }
  }

  dynamic "network_interface" {
    for_each = lookup(each.value, "networks", [])
    content {
      name   = "eth${index(each.value.networks, network_interface.value)}"
      bridge = network_interface.value.bridge
    }
  }

  initialization {
    hostname = each.key

    dynamic "ip_config" {
      for_each = lookup(each.value, "networks", [])
      content {
        ipv4 {
          address = ip_config.value.ip
          gateway = ip_config.value.gw
        }
      }
    }
  }

  dynamic "startup" {
    for_each = lookup(each.value, "startup", null) != null ? [each.value.startup] : []
    content {
      order    = lookup(startup.value, "order", null)
      up_delay = lookup(startup.value, "up_delay", null)
    }
  }

  depends_on = [proxmox_virtual_environment_sdn_applier.applier]

  lifecycle {
    ignore_changes = [operating_system[0].template_file_id, started, initialization, features]
  }
}
