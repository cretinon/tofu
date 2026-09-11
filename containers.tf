# ---------------------------------------------------------------------------
# LXC containers, one per var.ct entry, created from a managed Debian template
# (see images.tf).
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_container" "debian_container" {
  for_each = var.ct

  description = each.value.ct_description
  node_name   = var.pve_node
  # Pinned only when ct_id is set, otherwise the provider picks a free id.
  vm_id         = each.value.ct_id
  start_on_boot = true
  # Proxmox always sorts the tags: sorting them here avoids a permanent diff.
  tags         = sort(each.value.ct_tags)
  unprivileged = true
  # true makes Proxmox refuse to destroy or update the container.
  protection = each.value.ct_protection

  cpu {
    cores = each.value.ct_cores
  }

  disk {
    datastore_id = each.value.ct_datastore_storage_location
    size         = each.value.ct_disk_size
  }

  memory {
    dedicated = each.value.ct_memory
    swap      = each.value.ct_swap
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.image[each.value.ct_source_image].id
    type             = each.value.ct_os_type
  }

  initialization {
    hostname = each.value.ct_name

    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = each.value.ct_ip
        # A gateway must be omitted when the address is obtained via DHCP.
        gateway = each.value.ct_ip == "dhcp" ? null : var.gateway
      }
    }

    user_account {
      keys = var.ssh_public_keys
      # null keeps the container SSH-key-only (no root password).
      password = each.value.ct_root_password
    }
  }

  network_interface {
    name       = "veth0"
    bridge     = each.value.ct_bridge
    rate_limit = each.value.ct_nic_rate_limit
  }

  features {
    nesting = true
    fuse    = false
  }

  lifecycle {
    precondition {
      condition     = contains(keys(var.images), each.value.ct_source_image)
      error_message = "ct_source_image \"${each.value.ct_source_image}\" is not defined in var.images (known keys: ${join(", ", sort(keys(var.images)))})."
    }

    precondition {
      condition     = try(var.images[each.value.ct_source_image].content_type, "") == "vztmpl"
      error_message = "The image referenced by ct_source_image \"${each.value.ct_source_image}\" is not an LXC template: its content_type must be \"vztmpl\"."
    }
  }
}
