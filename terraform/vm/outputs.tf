output "vm" {
  value = {
    name      = libvirt_domain.vm.name
    mac       = var.mac
    vcpus     = var.vcpus
    memory    = var.memory_mib
    disk_gib  = var.disk_gib
    root_disk = libvirt_volume.root.path
  }
}
