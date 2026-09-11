# ---------------------------------------------------------------------------
# Virtual machines, one per var.vm entry, booted from a managed Debian cloud
# image (see images.tf) and configured through the cloud-init snippets defined
# in cloud-init.tf.
#
# The disk image is imported on the node through SSH, so the provider needs the
# ssh block configured in providers.tf.
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "debian_vm" {
  for_each = var.vm

  name      = each.value.vm_name
  node_name = var.pve_node
  # Pinned only when vm_id is set, otherwise the provider picks a free id.
  vm_id       = each.value.vm_id
  description = each.value.vm_description
  # true makes Proxmox refuse to destroy the VM (and its disks). Incompatible
  # with vm_recreate_on_cloud_init_change: a rebuild must destroy the VM first.
  protection = each.value.vm_protection
  # Proxmox always sorts the tags: sorting them here avoids a permanent diff.
  tags    = sort(each.value.vm_tags)
  on_boot = true

  # Stop instead of shutting down on destroy: a VM waiting for a QEMU agent
  # that is not (yet) running would otherwise block the destroy.
  stop_on_destroy = true

  cpu {
    cores = each.value.vm_cores
    type  = each.value.vm_cpu_type
  }

  memory {
    dedicated = each.value.vm_memory
    # 0 disables the balloon device (provider default).
    floating = each.value.vm_floating_memory
  }

  disk {
    datastore_id = each.value.vm_datastore_storage_location
    file_id      = proxmox_virtual_environment_download_file.image[each.value.vm_source_image].id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    # Must be at least the virtual size of the imported cloud image.
    size = each.value.vm_disk_size
  }

  network_device {
    bridge     = each.value.vm_bridge
    model      = "virtio"
    rate_limit = each.value.vm_nic_rate_limit
  }

  operating_system {
    type = "l26"
  }

  agent {
    # Requires qemu-guest-agent running inside the guest; it is installed by the
    # vendor data snippet (cloud-init/vendor-config.yaml).
    enabled = true
  }

  initialization {
    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = each.value.vm_ip
        # A gateway must be omitted when the address is obtained via DHCP.
        gateway = each.value.vm_ip == "dhcp" ? null : var.gateway
      }
    }

    # Link the cloud-init snippets uploaded by cloud-init.tf.
    user_data_file_id   = proxmox_virtual_environment_file.user_config.id
    vendor_data_file_id = proxmox_virtual_environment_file.vendor_config.id
  }

  lifecycle {
    # Only active for VMs opting in: rebuilds the VM -- destroy + recreate, its
    # disks included -- when the rendered cloud-init payload changes (see
    # cloud-init.tf).
    replace_triggered_by = [terraform_data.vm_cloud_init[each.key]]

    precondition {
      condition     = contains(keys(var.images), each.value.vm_source_image)
      error_message = "vm_source_image \"${each.value.vm_source_image}\" is not defined in var.images (known keys: ${join(", ", sort(keys(var.images)))})."
    }

    precondition {
      condition     = try(var.images[each.value.vm_source_image].content_type, "") == "iso"
      error_message = "The image referenced by vm_source_image \"${each.value.vm_source_image}\" is not a VM disk image: its content_type must be \"iso\"."
    }

    precondition {
      condition     = each.value.vm_id == null || !contains([for c in values(var.ct) : c.ct_id if c.ct_id != null], each.value.vm_id)
      error_message = "vm_id ${coalesce(each.value.vm_id, 0)} is already pinned by a var.ct entry: VMs and containers share the same Proxmox id space."
    }
  }
}
