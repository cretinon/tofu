# ---------------------------------------------------------------------------
# OS images downloaded directly on the Proxmox node through the PVE
# download-url API. Every VM disk and container rootfs is created from one of
# these files, so they are created before the VMs/CTs (implicit dependency
# through the file_id references in vms.tf and containers.tf).
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_download_file" "image" {
  for_each = var.images

  content_type = each.value.content_type
  datastore_id = var.images_datastore_id
  node_name    = var.pve_node
  url          = each.value.url
  file_name    = each.value.file_name

  # Only pass the verification parameters when a digest is known: the PVE API
  # takes a checksum algorithm only together with a checksum.
  checksum           = each.value.checksum != "" ? each.value.checksum : null
  checksum_algorithm = each.value.checksum != "" ? each.value.checksum_algorithm : null

  # Delete a file of the same name that already sits in the datastore -- even
  # one this configuration did not create -- and download the image again,
  # instead of failing with "file already exists".
  overwrite_unmanaged = true

  # Images are large: the provider default of 10 minutes is tight on slow links.
  upload_timeout = 1800
}
