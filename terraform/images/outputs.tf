output "base_volumes" {
  description = "Base volume per Ubuntu release: name and path, for VM disks to back onto."
  value = {
    for release, vol in libvirt_volume.base : release => {
      name = vol.name
      path = vol.path
    }
  }
}
