# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

resource "proxmox_virtual_environment_download_file" "templates" {
  for_each = local.templates

  content_type       = "vztmpl"
  datastore_id       = "local"
  node_name          = local.proxmox_node
  url                = each.value.url
  checksum           = each.value.checksum
  checksum_algorithm = each.value.checksum_algorithm
  overwrite          = false
}
