locals {
  gib = 1024 * 1024 * 1024
}

# ---------- Disks ----------
# Root disk: copy-on-write overlay on the shared, read-only base volume.
resource "libvirt_volume" "root" {
  name     = "${var.name}.qcow2"
  pool     = var.pool
  capacity = var.disk_gib * local.gib

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = var.base_volume_path
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_volume" "extra" {
  count = length(var.extra_disks)

  name     = "${var.name}-disk${count.index + 2}.qcow2"
  pool     = var.pool
  capacity = var.extra_disks[count.index].size_gib * local.gib

  target = {
    format = {
      type = "qcow2"
    }
  }
}

# ---------- cloud-init ----------
resource "libvirt_cloudinit_disk" "init" {
  name = "${var.name}-cloudinit"

  meta_data = templatefile("${path.module}/templates/meta-data.yaml.tftpl", {
    name = var.name
  })

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    name                = var.name
    user                = var.user
    ssh_authorized_keys = var.ssh_authorized_keys
    passwordless_sudo   = var.passwordless_sudo
    password_login      = var.password_login
    timezone            = var.timezone
  })

  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    mac = var.mac
  })

  lifecycle {
    # cloud-init only reads this on the VM's first boot, so changing a template or SSH
    # key later can't affect an existing VM; don't churn its config disk for nothing.
    ignore_changes = [user_data, meta_data, network_config]
  }
}

resource "libvirt_volume" "cloudinit" {
  name = "${var.name}-cloudinit.iso"
  pool = var.pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.init.path
    }
  }
}

# ---------- VM ----------
resource "libvirt_domain" "vm" {
  name        = var.name
  title       = var.name
  description = var.description
  type        = "kvm"
  vcpu        = var.vcpus
  memory      = var.memory_mib
  memory_unit = "MiB"
  autostart   = var.autostart
  running     = true

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    firmware     = var.firmware == "uefi" ? "efi" : null
  }

  cpu = {
    mode = var.cpu_mode
  }

  devices = {
    # Disks are referenced by file path, not pool/volume: libvirt's AppArmor helper
    # (virt-aa-helper) only adds a disk's backing chain to the VM's profile for
    # file-type disks. With volume-type disks QEMU can't open the base image
    # ("Permission denied", denied silently).
    disks = concat(
      [{
        source = { file = { file = libvirt_volume.root.path } }
        target = { bus = "virtio", dev = "vda" }
        driver = { type = "qcow2" }
      }],
      [for i, d in libvirt_volume.extra : {
        source = { file = { file = d.path } }
        target = { bus = "virtio", dev = "vd${substr("bcdefghijklmnop", i, 1)}" }
        driver = { type = "qcow2" }
      }],
      [{
        device = "cdrom"
        source = { file = { file = libvirt_volume.cloudinit.path } }
        target = { bus = "sata", dev = "sda" }
      }]
    )

    interfaces = [{
      model  = { type = "virtio" }
      mac    = { address = var.mac }
      source = { bridge = { bridge = var.bridge } }
    }]

    # qemu-guest-agent: how Ansible learns the VM's DHCP address on a bridged NIC
    channels = [{
      source = { unix = { mode = "bind" } }
      target = { virt_io = { name = "org.qemu.guest_agent.0" } }
    }]

    # `virsh console <name>` (Ubuntu cloud images log to ttyS0)
    serials = [{
      target = { port = 0 }
    }]
    consoles = [{
      target = { type = "serial", port = 0 }
    }]
  }
}
