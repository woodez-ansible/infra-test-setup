variable "libvirt_uri" {
  type    = string
  default = "qemu:///system"
}

variable "pool" {
  description = "libvirt storage pool for the base volumes."
  type        = string
  default     = "default"
}

variable "images" {
  description = <<-EOT
    Base images keyed by Ubuntu release. `path` is a local file on the hypervisor that
    Ansible has already downloaded and checksum-verified.
  EOT
  type = map(object({
    build = string
    path  = string
  }))

  validation {
    condition     = alltrue([for k, v in var.images : can(regex("^[0-9]{2}\\.[0-9]{2}$", k)) && can(regex("^[0-9]{8}$", v.build))])
    error_message = "Keys must be releases like \"26.04\" and build must be a YYYYMMDD date."
  }
}
