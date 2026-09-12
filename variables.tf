# ---------------------------------------------------------------------------
# Input variables
#
# Every secret (pve_password, pve_api_token, pve_ssh_private_key) is marked
# sensitive and MUST be provided through a git-ignored terraform.tfvars file or
# through TF_VAR_* environment variables.
# ---------------------------------------------------------------------------

# --- Proxmox VE connection --------------------------------------------------

variable "pve_endpoint" {
  description = "Proxmox VE API endpoint, e.g. \"https://pve.example.com:8006/\" (without the /api2/json suffix)."
  type        = string

  validation {
    condition     = can(regex("^https://(\\[[0-9A-Fa-f:]+\\]|[A-Za-z0-9][A-Za-z0-9.-]*)(:[0-9]{1,5})?/?$", var.pve_endpoint))
    error_message = "pve_endpoint must be an HTTPS URL such as \"https://pve.example.com:8006/\" (the provider rejects plain HTTP, and the /api2/json suffix must be left out)."
  }

  validation {
    condition     = try(tonumber(regex(":([0-9]{1,5})/?$", var.pve_endpoint)[0]) >= 1 && tonumber(regex(":([0-9]{1,5})/?$", var.pve_endpoint)[0]) <= 65535, true)
    error_message = "The port of pve_endpoint must be between 1 and 65535."
  }
}

variable "pve_username" {
  description = "Proxmox VE API user, e.g. \"root@pam\". Keep it set even when using an API token: the provider needs a PAM user for the node SSH connection unless pve_ssh_username is given."
  type        = string
}

variable "pve_password" {
  description = "Proxmox VE API password. Ignored as soon as pve_api_token is set; prefer the token in production."
  type        = string
  default     = ""
  sensitive   = true
}

variable "pve_api_token" {
  description = "Proxmox VE API token, e.g. \"terraform@pve!provider=00000000-0000-0000-0000-000000000000\". When set it takes precedence over pve_username/pve_password."
  type        = string
  default     = ""
  sensitive   = true
}

variable "pve_node" {
  description = "Proxmox VE node hosting every VM, container, image and snippet."
  type        = string

  validation {
    condition     = length(trimspace(var.pve_node)) > 0
    error_message = "pve_node must not be empty: every proxmox resource requires it."
  }
}

variable "pve_insecure" {
  description = "Skip TLS certificate verification with the API. Keep false unless the Proxmox API uses a self-signed certificate."
  type        = bool
  default     = false
}

variable "pve_min_tls" {
  description = "Minimum TLS version accepted by the provider for API calls. Keep the provider default (1.3) unless the Proxmox node only offers TLS 1.2: lowering it trades security for compatibility."
  type        = string
  default     = "1.3"

  validation {
    condition     = contains(["1.0", "1.1", "1.2", "1.3"], var.pve_min_tls)
    error_message = "pve_min_tls must be one of 1.0, 1.1, 1.2 or 1.3."
  }
}

variable "pve_tmp_dir" {
  description = "Custom temporary directory used by the provider (empty = system default)."
  type        = string
  default     = ""
}

variable "pve_random_vm_ids" {
  description = "Let the provider pick a random, uniqueness-checked id for VM/CT entries that do not pin one, avoiding collisions between concurrent runs."
  type        = bool
  default     = true
}

variable "pve_ssh_agent" {
  description = "Use the local ssh-agent for the node SSH connection (needed to upload snippets and import disk images)."
  type        = bool
  default     = true
}

variable "pve_ssh_username" {
  description = "SSH user used to reach the node. Mandatory when pve_api_token is used, otherwise it defaults to pve_username. That user needs password-less sudo for pvesm/qm/tee."
  type        = string
  default     = ""
}

variable "pve_ssh_private_key" {
  description = "PEM private key used when no ssh-agent is available (empty = use the agent or the API password). Takes precedence over pve_ssh_private_key_file."
  type        = string
  default     = ""
  sensitive   = true
}

variable "pve_ssh_private_key_file" {
  description = "Path of the PEM private key read with file() for the node SSH connection when pve_ssh_private_key is empty (empty = use the ssh-agent or the API password). Set it when the key only exists as a file: a *.tfvars file accepts literals only, so the file() call cannot be made there."
  type        = string
  default     = ""
}

# --- Datastores -------------------------------------------------------------

variable "images_datastore_id" {
  description = "Datastore receiving the downloaded VM images and LXC templates."
  type        = string
  default     = "local"
}

variable "snippets_datastore_id" {
  description = "Datastore receiving the cloud-init snippets. Snippets must be enabled on it (Datacenter > Storage)."
  type        = string
  default     = "local"
}

variable "snippet_name_prefix" {
  description = "Prefix of the two cloud-init snippet file names. Snippet names are datastore-wide, so set a distinct prefix when several configurations (or a manually uploaded snippet) share the same datastore."
  type        = string
  default     = "tofu"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", var.snippet_name_prefix))
    error_message = "snippet_name_prefix must start with a letter or a digit and may only contain letters, digits, dots, underscores and hyphens."
  }
}

# --- Managed OS images ------------------------------------------------------

variable "images" {
  description = <<-EOT
    OS images downloaded once on the node, keyed by a short id that vm/ct
    entries reference through vm_source_image / ct_source_image.
      content_type       "iso" for a VM qcow2 image, "vztmpl" for an LXC template
      url                versioned download URL (avoid "latest": the pinned checksum would rot)
      file_name          mandatory: name stored in the datastore (must end with
                         .img/.iso for an iso, .tar.zst/.tar.gz for a vztmpl)
      checksum           hex digest whose length must match checksum_algorithm,
                         empty = no verification
      checksum_algorithm md5|sha1|sha224|sha256|sha384|sha512
  EOT
  type = map(object({
    content_type       = string
    url                = string
    file_name          = string
    checksum           = optional(string, "")
    checksum_algorithm = optional(string, "sha512")
  }))

  default = {
    debian13 = {
      content_type = "iso"
      url          = "https://cloud.debian.org/images/cloud/trixie/20260831-2587/debian-13-genericcloud-amd64-20260831-2587.qcow2"
      file_name    = "debian-13-genericcloud-amd64-20260831-2587.img"
      checksum     = "8ea9faae810043a0b35b0149f05014f26705c2339ffb11ead308f33e844a87cc3ef46ec81d5262b38817b6a88af404874d48a5857ebe072ef6a31dfb6e371f50"
    }
    debian12 = {
      content_type = "iso"
      url          = "https://cloud.debian.org/images/cloud/bookworm/20260909-2596/debian-12-genericcloud-amd64-20260909-2596.qcow2"
      file_name    = "debian-12-genericcloud-amd64-20260909-2596.img"
      checksum     = "08fea112563461f251f3c95a5c5cf8cb25eb60f74cec03e85a97ff91d3efef3059d35837598bbb476008f20db6d3bdc7143c5f2f2a9a6da394a0acc601fd5986"
    }
    # The two LXC templates below are the only unverified downloads of this
    # project: download.proxmox.com publishes no SHA512SUMS next to them and
    # serves them over HTTP only (its certificate is not valid for that host
    # name), so no digest can be pinned here and PVE cannot verify the template
    # that becomes the rootfs of every container. See README "Managed OS
    # images" to compute and pin one by hand.
    debian13-ct = {
      content_type       = "vztmpl"
      url                = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
      file_name          = "debian-13-standard_13.6-1_amd64.tar.zst"
      checksum_algorithm = "sha512"
    }
    debian12-ct = {
      content_type       = "vztmpl"
      url                = "http://download.proxmox.com/images/system/debian-12-standard_12.12-1_amd64.tar.zst"
      file_name          = "debian-12-standard_12.12-1_amd64.tar.zst"
      checksum_algorithm = "sha512"
    }
  }

  validation {
    condition     = length(var.images) > 0
    error_message = "images must define at least one image."
  }

  validation {
    condition     = alltrue([for i in values(var.images) : contains(["iso", "vztmpl"], i.content_type)])
    error_message = "Every image content_type must be \"iso\" (VM image) or \"vztmpl\" (LXC template)."
  }

  validation {
    condition = alltrue([
      for i in values(var.images) : can(regex("^https?://", i.url))
    ])
    error_message = "Every image url must start with http:// or https://."
  }

  validation {
    condition = alltrue([
      for i in values(var.images) :
      contains(["md5", "sha1", "sha224", "sha256", "sha384", "sha512"], i.checksum_algorithm)
    ])
    error_message = "Every image checksum_algorithm must be one of md5|sha1|sha224|sha256|sha384|sha512."
  }

  validation {
    condition = alltrue([
      for i in values(var.images) :
      i.content_type == "iso" ? (endswith(i.file_name, ".img") || endswith(i.file_name, ".iso")) : (endswith(i.file_name, ".tar.zst") || endswith(i.file_name, ".tar.gz"))
    ])
    error_message = "An iso image file_name must end with .img or .iso, a vztmpl template file_name with .tar.zst or .tar.gz."
  }

  validation {
    condition = alltrue([
      for i in values(var.images) : i.checksum == "" || (
        can(regex("^[0-9a-f]+$", lower(i.checksum))) &&
        length(i.checksum) == lookup(
          {
            "md5"    = 32
            "sha1"   = 40
            "sha224" = 56
            "sha256" = 64
            "sha384" = 96
            "sha512" = 128
          },
          i.checksum_algorithm,
          -1
        )
      )
    ])
    error_message = "Every image checksum must be a hexadecimal digest whose length matches its checksum_algorithm (md5 32, sha1 40, sha224 56, sha256 64, sha384 96, sha512 128 characters)."
  }
}

# --- Virtual machines -------------------------------------------------------

variable "vm" {
  description = <<-EOT
    Virtual machines, keyed by a stable identifier used in the resource
    addresses (proxmox_virtual_environment_vm.debian_vm["<key>"]).
      vm_name, vm_ip, vm_datastore_storage_location are mandatory
      vm_ip is CIDR ("10.0.10.11/24") or "dhcp" (the gateway is then ignored)
      vm_floating_memory = 0 disables the balloon device; set it below
      vm_memory to allow the host to reclaim unused memory
      vm_id is optional and must be >= 100 when pinned
      vm_protection = true makes Proxmox refuse to destroy the VM; it cannot be
      combined with vm_recreate_on_cloud_init_change (a rebuild must destroy)
      vm_recreate_on_cloud_init_change = true DESTROYS and recreates the VM
      whenever the rendered cloud-init payload changes (variables or template
      files), and once when the flag itself is toggled. See README
      "How a guest is built"
  EOT
  type = map(object({
    vm_name                          = string
    vm_ip                            = string
    vm_datastore_storage_location    = string
    vm_source_image                  = optional(string, "debian13")
    vm_description                   = optional(string, "Managed by OpenTofu")
    vm_tags                          = optional(list(string), [])
    vm_bridge                        = optional(string, "vmbr0")
    vm_cores                         = optional(number, 2)
    vm_cpu_type                      = optional(string, "x86-64-v2-AES")
    vm_memory                        = optional(number, 2048)
    vm_floating_memory               = optional(number, 0)
    vm_disk_size                     = optional(number, 8)
    vm_nic_rate_limit                = optional(number, 0)
    vm_id                            = optional(number)
    vm_protection                    = optional(bool, false)
    vm_recreate_on_cloud_init_change = optional(bool, false)
  }))

  validation {
    condition     = alltrue([for v in values(var.vm) : length(trimspace(v.vm_name)) > 0])
    error_message = "Every vm_name must not be empty."
  }

  validation {
    condition = alltrue([
      for v in values(var.vm) : v.vm_ip == "dhcp" || can(cidrnetmask(v.vm_ip))
    ])
    error_message = "Every vm_ip must be \"dhcp\" or an IPv4 address in CIDR notation, e.g. 10.0.10.11/24."
  }

  validation {
    condition = alltrue([
      for v in values(var.vm) : v.vm_cores > 0 && v.vm_memory > 0 && v.vm_disk_size > 0 && v.vm_nic_rate_limit >= 0 && v.vm_floating_memory >= 0
    ])
    error_message = "vm_cores, vm_memory and vm_disk_size must be greater than 0; vm_nic_rate_limit and vm_floating_memory must not be negative."
  }

  validation {
    condition     = alltrue([for v in values(var.vm) : v.vm_floating_memory <= v.vm_memory])
    error_message = "vm_floating_memory (balloon floor) must not exceed vm_memory."
  }

  validation {
    condition     = alltrue([for v in values(var.vm) : v.vm_id == null || v.vm_id >= 100])
    error_message = "Every pinned vm_id must be at least 100: Proxmox reserves the ids below 100."
  }

  validation {
    condition     = length(distinct([for v in values(var.vm) : v.vm_id if v.vm_id != null])) == length([for v in values(var.vm) : v.vm_id if v.vm_id != null])
    error_message = "vm_id must be unique: several var.vm entries pin the same VM id."
  }
}

# --- Containers -------------------------------------------------------------

variable "ct" {
  description = <<-EOT
    LXC containers, keyed by a stable identifier used in the resource addresses
    (proxmox_virtual_environment_container.debian_container["<key>"]).
      ct_name, ct_ip, ct_datastore_storage_location are mandatory
      ct_id pins the container id (otherwise one is picked automatically)
      ct_id is optional and must be >= 100 when pinned
      ct_protection = true makes Proxmox refuse to destroy or update the container
      ct_root_password is optional: leave it null to allow SSH-key-only access
      ct_swap = 0 keeps the provider default
  EOT
  type = map(object({
    ct_name                       = string
    ct_ip                         = string
    ct_datastore_storage_location = string
    ct_source_image               = optional(string, "debian13-ct")
    ct_os_type                    = optional(string, "debian")
    ct_description                = optional(string, "Managed by OpenTofu")
    ct_tags                       = optional(list(string), [])
    ct_bridge                     = optional(string, "vmbr0")
    ct_cores                      = optional(number, 1)
    ct_memory                     = optional(number, 512)
    ct_swap                       = optional(number, 0)
    ct_disk_size                  = optional(number, 8)
    ct_nic_rate_limit             = optional(number, 0)
    ct_id                         = optional(number)
    ct_protection                 = optional(bool, false)
    ct_root_password              = optional(string)
  }))

  validation {
    condition     = alltrue([for c in values(var.ct) : length(trimspace(c.ct_name)) > 0])
    error_message = "Every ct_name must not be empty."
  }

  validation {
    condition = alltrue([
      for c in values(var.ct) : c.ct_ip == "dhcp" || can(cidrnetmask(c.ct_ip))
    ])
    error_message = "Every ct_ip must be \"dhcp\" or an IPv4 address in CIDR notation, e.g. 10.0.10.21/24."
  }

  validation {
    condition = alltrue([
      for c in values(var.ct) : contains(["alpine", "archlinux", "centos", "debian", "devuan", "fedora", "gentoo", "nixos", "opensuse", "ubuntu", "unmanaged"], c.ct_os_type)
    ])
    error_message = "Every ct_os_type must be a Proxmox container OS type (debian, ubuntu, alpine, ...)."
  }

  validation {
    condition = alltrue([
      for c in values(var.ct) : c.ct_cores > 0 && c.ct_memory > 0 && c.ct_disk_size > 0 && c.ct_swap >= 0 && c.ct_nic_rate_limit >= 0
    ])
    error_message = "ct_cores, ct_memory and ct_disk_size must be greater than 0; ct_swap and ct_nic_rate_limit must not be negative."
  }

  validation {
    condition     = alltrue([for c in values(var.ct) : c.ct_id == null || c.ct_id >= 100])
    error_message = "Every pinned ct_id must be at least 100: Proxmox reserves the ids below 100."
  }

  validation {
    condition     = length(distinct([for c in values(var.ct) : c.ct_id if c.ct_id != null])) == length([for c in values(var.ct) : c.ct_id if c.ct_id != null])
    error_message = "ct_id must be unique: several var.ct entries pin the same container id."
  }
}

# --- Shared guest settings --------------------------------------------------

variable "dns_domain" {
  description = "DNS search domain handed to the VMs and containers."
  type        = string

  validation {
    condition     = length(trimspace(var.dns_domain)) > 0
    error_message = "dns_domain must not be empty."
  }
}

variable "dns_servers" {
  description = "DNS resolver addresses handed to the VMs and containers."
  type        = list(string)

  validation {
    condition     = length(var.dns_servers) > 0
    error_message = "dns_servers must contain at least one resolver address."
  }

  validation {
    condition     = alltrue([for ip in var.dns_servers : can(cidrnetmask(format("%s/32", ip)))])
    error_message = "Every dns_servers entry must be a valid IPv4 address without prefix (this project only configures IPv4)."
  }
}

variable "gateway" {
  description = "Default IPv4 gateway of the guest network. Ignored by entries configured with vm_ip/ct_ip = \"dhcp\"."
  type        = string

  validation {
    condition     = can(cidrnetmask(format("%s/32", var.gateway)))
    error_message = "gateway must be a valid IPv4 address without prefix, e.g. 10.0.10.1 (this project only configures IPv4)."
  }
}

variable "ssh_public_keys" {
  description = "OpenSSH public keys authorized for the guest admin user (and for the root account of the containers)."
  type        = list(string)

  validation {
    condition = length(var.ssh_public_keys) > 0 && alltrue([
      for key in var.ssh_public_keys : can(regex("^(ssh-(rsa|ed25519)|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com) ", trimspace(key)))
    ])
    error_message = "ssh_public_keys must contain at least one OpenSSH public key line, e.g. \"ssh-ed25519 AAAA... user@host\"."
  }
}

variable "vm_admin_user" {
  description = "Admin user created by cloud-init in every VM (the Debian cloud images ship a \"debian\" user). The user config snippet is rendered once for all VMs, so it cannot differ per VM; containers are not affected."
  type        = string
  default     = "debian"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*$", var.vm_admin_user))
    error_message = "vm_admin_user must be a valid UNIX user name: lowercase letters, digits, underscore and hyphen, starting with a letter or an underscore."
  }
}
