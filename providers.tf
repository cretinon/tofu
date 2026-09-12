# ---------------------------------------------------------------------------
# OpenTofu / provider requirements and Proxmox VE connection
#
# Authentication precedence: pve_api_token, then pve_username/pve_password.
# The provider also needs SSH access to the node to upload the cloud-init
# snippets (cloud-init.tf) and to import the VM disk images (images.tf), hence
# the explicit ssh block below.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # "~> 0.74.0" = any 0.74.x patch release. Written with all three
      # components on purpose: "~> 0.74" would allow any 0.x up to 1.0.
      version = "~> 0.74.0"
    }
  }
}

provider "proxmox" {
  endpoint = var.pve_endpoint

  # An API token takes precedence over username/password when it is set.
  api_token = var.pve_api_token != "" ? var.pve_api_token : null
  username  = var.pve_username
  password  = var.pve_password != "" ? var.pve_password : null

  insecure = var.pve_insecure
  tmp_dir  = var.pve_tmp_dir != "" ? var.pve_tmp_dir : null

  # Minimum TLS version accepted for API calls (the provider defaults to 1.3).
  min_tls = var.pve_min_tls

  # Pin or randomise VM/CT ids instead of racing on the "next free id".
  random_vm_ids = var.pve_random_vm_ids

  # The provider only accepts the key itself, never a path: the file is read here,
  # where function calls are allowed (a *.tfvars file cannot call file()).
  ssh {
    agent       = var.pve_ssh_agent
    username    = var.pve_ssh_username != "" ? var.pve_ssh_username : null
    private_key = var.pve_ssh_private_key != "" ? var.pve_ssh_private_key : (var.pve_ssh_private_key_file != "" ? file(var.pve_ssh_private_key_file) : null)
  }
}
