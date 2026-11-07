# One VM per Terraform workspace. Values come from vms/<name>.yml, rendered by
# playbooks/vm-build.yml into <name>.tfvars.json; defaults live in Ansible, not here.

variable "libvirt_uri" {
  type = string
}

variable "pool" {
  type = string
}

variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$", var.name))
    error_message = "name: lowercase letters, digits and '-', 1-32 chars, starting with a letter."
  }
}

variable "description" {
  type = string
}

variable "vcpus" {
  type = number
  validation {
    condition     = var.vcpus >= 1 && var.vcpus <= 16
    error_message = "vcpus must be 1-16."
  }
}

variable "memory_mib" {
  type = number
  validation {
    condition     = var.memory_mib >= 512 && var.memory_mib <= 16384
    error_message = "memory_mib must be 512-16384."
  }
}

variable "disk_gib" {
  type = number
  validation {
    condition     = var.disk_gib >= 5 && var.disk_gib <= 500
    error_message = "disk_gib must be 5-500."
  }
}

variable "extra_disks" {
  description = "Additional blank qcow2 disks (vdb, vdc, ...), left unformatted."
  type        = list(object({ size_gib = number }))
}

variable "base_volume_path" {
  description = "Path of the release's base volume, from terraform/images output."
  type        = string
}

variable "bridge" {
  type = string
}

variable "mac" {
  type = string
  validation {
    condition     = can(regex("^52:54:00(:[0-9a-f]{2}){3}$", var.mac))
    error_message = "mac must be a lowercase 52:54:00:xx:xx:xx address."
  }
}

variable "firmware" {
  type = string
  validation {
    condition     = contains(["bios", "uefi"], var.firmware)
    error_message = "firmware must be bios or uefi."
  }
}

variable "cpu_mode" {
  type = string
  validation {
    condition     = contains(["host-passthrough", "host-model"], var.cpu_mode)
    error_message = "cpu_mode must be host-passthrough or host-model."
  }
}

variable "autostart" {
  type = bool
}

# ---------- cloud-init ----------
variable "user" {
  type = string
}

variable "ssh_authorized_keys" {
  type = list(string)
  validation {
    condition     = length(var.ssh_authorized_keys) > 0
    error_message = "At least one SSH public key is required (password login is off by default)."
  }
}

variable "passwordless_sudo" {
  type = bool
}

variable "password_login" {
  type = bool
}

variable "timezone" {
  type = string
}
