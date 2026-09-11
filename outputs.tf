# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "vm_ids" {
  description = "VM identifiers, keyed by the var.vm key."
  value       = { for key, vm in proxmox_virtual_environment_vm.debian_vm : key => vm.vm_id }
}

output "vm_names" {
  description = "VM names, keyed by the var.vm key."
  value       = { for key, vm in proxmox_virtual_environment_vm.debian_vm : key => vm.name }
}

output "vm_ipv4_addresses" {
  description = "IPv4 addresses reported by the QEMU agent (one list per interface, empty until the agent runs inside the guest)."
  value       = { for key, vm in proxmox_virtual_environment_vm.debian_vm : key => vm.ipv4_addresses }
}

output "ct_ids" {
  description = "Container resource identifiers assigned by the provider (<node>/<ctid>)."
  value       = { for key, ct in proxmox_virtual_environment_container.debian_container : key => ct.id }
}

output "ct_hostnames" {
  description = "Container hostnames, keyed by the var.ct key."
  value       = { for key, ct in proxmox_virtual_environment_container.debian_container : key => ct.initialization[0].hostname }
}

output "image_file_ids" {
  description = "Datastore volume ids of the downloaded OS images, keyed by the var.images key."
  value       = { for key, image in proxmox_virtual_environment_download_file.image : key => image.id }
}

output "snippet_file_ids" {
  description = "Datastore volume ids of the uploaded cloud-init snippets."
  value = {
    user_config   = proxmox_virtual_environment_file.user_config.id
    vendor_config = proxmox_virtual_environment_file.vendor_config.id
  }
}
