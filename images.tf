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
  # takes a checksum algorithm only together with a checksum, and a decompression
  # algorithm only makes sense on a compressed download (OpenWrt ships .img.gz
  # files). The node decompresses it and stores the result under file_name,
  # which keeps the .img extension PVE accepts for a VM disk.
  checksum                = each.value.checksum != "" ? each.value.checksum : null
  checksum_algorithm      = each.value.checksum != "" ? each.value.checksum_algorithm : null
  decompression_algorithm = each.value.decompression_algorithm != "" ? each.value.decompression_algorithm : null

  # The provider replaces the resource whenever the size it reads from the
  # datastore differs from the Content-Length of the url, and that comparison is
  # meaningless for a decompressed download: the node stores the decompressed
  # file while the url announces the compressed one, so the provider default
  # (true) re-downloads the image at every plan and never converges -- see
  # https://github.com/bpg/terraform-provider-proxmox/issues/1740, fixed only in
  # provider >= 0.78.2 whereas providers.tf pins "~> 0.74.0". Disabling the check
  # costs nothing here: the pinned checksum still guards the download, and the
  # raw CLI remains the way to force a fresh copy
  # (`tofu apply -replace='proxmox_virtual_environment_download_file.image["openwrt2512"]'`).
  overwrite = false

  # Delete a file of the same name that already sits in the datastore -- even
  # one this configuration did not create -- and download the image again,
  # instead of failing with "file already exists".
  overwrite_unmanaged = true

  # Images are large: the provider default of 10 minutes is tight on slow links.
  upload_timeout = 1800
}
