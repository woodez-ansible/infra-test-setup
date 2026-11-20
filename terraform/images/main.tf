# Shared, read-only base volumes. VM disks are copy-on-write overlays on these, so they
# live in their own state: destroying a VM can never delete a base image.
resource "libvirt_volume" "base" {
  for_each = var.images

  # Ubuntu keys are releases ("26.04"); Windows keys are dated builds
  # ("windows-2022-20261120"). Ubuntu names must not change: renaming forces a replacement,
  # which prevent_destroy blocks.
  name = startswith(each.key, "windows-") ? "${each.key}-base.qcow2" : "ubuntu-${each.key}-${each.value.build}-base.qcow2"
  pool = var.pool

  target = {
    format = {
      type = "qcow2"
    }
    # World-readable: QEMU opens base images read-only as a backing file. The pool's
    # default 0600 root-only mode made VMs fail to start with "Permission denied".
    permissions = {
      mode = "0644"
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
