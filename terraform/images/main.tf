# Shared, read-only base volumes. VM disks are copy-on-write overlays on these, so they
# live in their own state: destroying a VM can never delete a base image.
resource "libvirt_volume" "base" {
  for_each = var.images

  name = "ubuntu-${each.key}-${each.value.build}-base.qcow2"
  pool = var.pool

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = each.value.path
    }
  }

  lifecycle {
    # VM disks depend on these; removing one would break every VM built on it.
    prevent_destroy = true
  }
}
