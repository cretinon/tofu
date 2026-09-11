# ---------------------------------------------------------------------------
# Cloud-init snippets uploaded to the snippets datastore.
#
# The user config is rendered from cloud-init/user-config.yaml.tftpl so that the
# admin user (vm_admin_user), the SSH keys and the resolvers come from the
# variables defined in variables.tf. The vendor config only installs the QEMU
# guest agent.
#
# Notes:
# - a custom user config replaces the one Proxmox generates (user, password,
#   SSH keys, upgrade flag); the network and meta configs stay auto-generated.
# - snippet names are datastore-wide: they are prefixed with
#   var.snippet_name_prefix and both resources overwrite a leftover file of the
#   same name (already the provider default, kept explicit) instead of failing,
#   so several configurations can share one datastore.
# - editing the payload replaces the snippet file itself (source_raw is ForceNew:
#   the provider deletes the old file, then uploads the new one). The VMs depend
#   on these files through initialization.*_file_id, so OpenTofu creates the
#   snippets before the guests using them and destroys those guests before the
#   snippets: a guest never points at a missing file. Do NOT add
#   create_before_destroy here -- with an identical file name the old instance's
#   destroy would remove the file that was just uploaded.
# - user and vendor data are applied by cloud-init at the guest's FIRST boot:
#   editing ssh_public_keys/dns_* (or the template files) updates the snippet
#   but does not reach an existing guest. Set vm_recreate_on_cloud_init_change =
#   true on a VM to have it rebuilt whenever the rendered payload changes
#   (terraform_data below); that rebuild destroys the VM and its disks.
# ---------------------------------------------------------------------------

locals {
  # Rendered snippet payloads. The revision below hashes these payloads rather
  # than the input variables, so editing cloud-init/user-config.yaml.tftpl or
  # cloud-init/vendor-config.yaml is detected too. cloud-init only applies the
  # payload at a guest's first boot, hence the opt-in replacement trigger below.
  vm_user_data = templatefile("${path.module}/cloud-init/user-config.yaml.tftpl", {
    admin_user      = var.vm_admin_user
    ssh_public_keys = var.ssh_public_keys
    dns_domain      = var.dns_domain
    dns_servers     = var.dns_servers
  })
  vm_vendor_data = file("${path.module}/cloud-init/vendor-config.yaml")

  # jsonencode (not a plain join) keeps the two payloads unambiguously separated.
  vm_cloud_init_revision = sha256(jsonencode([local.vm_user_data, local.vm_vendor_data]))
}

# Opt-in rebuild trigger: a VM with vm_recreate_on_cloud_init_change = true gets
# its terraform_data instance replaced as soon as the revision above changes,
# which replaces (destroys + recreates) the VM itself (replace_triggered_by in
# vms.tf). With the default (false) the value stays constant and no VM is ever
# replaced. Note: the flag is part of the trigger value, so toggling it rebuilds
# that VM once in either direction -- see README "How a guest is built".
resource "terraform_data" "vm_cloud_init" {
  for_each = var.vm

  triggers_replace = each.value.vm_recreate_on_cloud_init_change ? local.vm_cloud_init_revision : "disabled"
}

resource "proxmox_virtual_environment_file" "user_config" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore_id
  node_name    = var.pve_node

  # Kept explicit although the provider already defaults to true: a snippet name
  # is datastore-wide, so replacing a leftover file of the same name is what
  # allows several configurations to share one datastore.
  overwrite = true

  source_raw {
    data      = local.vm_user_data
    file_name = "${var.snippet_name_prefix}-user-config.yaml"
  }
}

resource "proxmox_virtual_environment_file" "vendor_config" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore_id
  node_name    = var.pve_node

  # Same note as user_config above (provider default, kept explicit).
  overwrite = true

  source_raw {
    data      = local.vm_vendor_data
    file_name = "${var.snippet_name_prefix}-vendor-config.yaml"
  }
}
