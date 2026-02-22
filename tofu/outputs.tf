# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

output "container_ids" {
  description = "Map of container hostname to VMID"
  value       = { for k, v in proxmox_virtual_environment_container.this : k => v.vm_id }
}

output "container_ips" {
  description = "Map of container hostname to list of configured IPv4 addresses"
  value = {
    for k, v in local.containers : k => [
      for net in lookup(v, "networks", []) : net.ip
    ]
  }
}
