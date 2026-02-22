# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

# --- Public zone (SNAT, internet-facing) ---

resource "proxmox_virtual_environment_sdn_zone_simple" "public" {
  id    = "public"
  nodes = [local.proxmox_node]
}

resource "proxmox_virtual_environment_sdn_vnet" "public" {
  id   = "vnetpub"
  zone = proxmox_virtual_environment_sdn_zone_simple.public.id

  depends_on = [proxmox_virtual_environment_sdn_applier.finalizer]
}

resource "proxmox_virtual_environment_sdn_subnet" "public" {
  vnet    = proxmox_virtual_environment_sdn_vnet.public.id
  cidr    = "10.10.2.0/24"
  gateway = "10.10.2.1"
  snat    = true

  depends_on = [proxmox_virtual_environment_sdn_applier.finalizer]
}

# --- Services zone (no SNAT, reverse-proxy backends) ---

resource "proxmox_virtual_environment_sdn_zone_simple" "services" {
  id    = "services"
  nodes = [local.proxmox_node]
}

resource "proxmox_virtual_environment_sdn_vnet" "services" {
  id   = "vnetsvc"
  zone = proxmox_virtual_environment_sdn_zone_simple.services.id

  depends_on = [proxmox_virtual_environment_sdn_applier.finalizer]
}

resource "proxmox_virtual_environment_sdn_subnet" "services" {
  vnet    = proxmox_virtual_environment_sdn_vnet.services.id
  cidr    = "10.10.3.0/24"
  gateway = "10.10.3.1"
  snat    = false

  depends_on = [proxmox_virtual_environment_sdn_applier.finalizer]
}

# --- SDN applier (finalizer + applier pattern per provider docs) ---

resource "proxmox_virtual_environment_sdn_applier" "finalizer" {}

resource "proxmox_virtual_environment_sdn_applier" "applier" {
  depends_on = [
    proxmox_virtual_environment_sdn_zone_simple.public,
    proxmox_virtual_environment_sdn_zone_simple.services,
    proxmox_virtual_environment_sdn_vnet.public,
    proxmox_virtual_environment_sdn_vnet.services,
    proxmox_virtual_environment_sdn_subnet.public,
    proxmox_virtual_environment_sdn_subnet.services,
  ]

  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_sdn_zone_simple.public,
      proxmox_virtual_environment_sdn_zone_simple.services,
      proxmox_virtual_environment_sdn_vnet.public,
      proxmox_virtual_environment_sdn_vnet.services,
      proxmox_virtual_environment_sdn_subnet.public,
      proxmox_virtual_environment_sdn_subnet.services,
    ]
  }
}
