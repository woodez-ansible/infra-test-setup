locals {
  gib     = 1024 * 1024 * 1024
  windows = var.os == "windows"
  # Windows always boots UEFI (the golden image is GPT/UEFI)
  uefi = local.windows || var.firmware == "uefi"
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

  lifecycle {
    # A VM stays on the base it was built from. A newer base image (e.g. next month's
    # Windows build) is for new VMs; changing it here would rebuild the VM.
    ignore_changes = [backing_store]
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

  # Windows: cloudbase-init reads the same NoCloud disk. Its user data holds no
  # credentials (the admin account is in the golden image), and it gets no
  # network-config: Windows uses DHCP on the virtio NIC by default.
  user_data = local.windows ? file("${path.module}/templates/windows-user-data.ps1.tftpl") : templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    name                = var.name
    user                = var.user
    ssh_authorized_keys = var.ssh_authorized_keys
    passwordless_sudo   = var.passwordless_sudo
    password_login      = var.password_login
    timezone            = var.timezone
  })

  network_config = local.windows ? null : templatefile("${path.module}/templates/network-config.yaml.tftpl", {
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

  # UEFI: explicit OVMF (no Secure Boot, as the Windows image was built) and a per-VM
  # NVRAM file in the pool. Provider 0.9.9 deletes that file on destroy (tested).
  os = {
    type            = "hvm"
    type_arch       = "x86_64"
    type_machine    = "q35"
    loader          = local.uefi ? "/usr/share/OVMF/OVMF_CODE_4M.fd" : null
    loader_readonly = local.uefi ? "yes" : null
    loader_type     = local.uefi ? "pflash" : null
    nv_ram = local.uefi ? {
      nv_ram   = "/var/lib/libvirt/images/${var.name}_VARS.fd"
      template = "/usr/share/OVMF/OVMF_VARS_4M.fd"
    } : null
  }

  # ACPI: UEFI requires it, and it's what lets a guest shut down cleanly on request.
  # Hyper-V enlightenments make Windows run (and idle) efficiently under KVM.
  features = {
    acpi = true
    hyper_v = local.windows ? {
      relaxed   = { state = "on" }
      vapic     = { state = "on" }
      spinlocks = { state = "on", retries = 8191 }
      vp_index  = { state = "on" }
      synic     = { state = "on" }
      stimer    = { state = "on" }
    } : null
  }

  clock = local.windows ? {
    timer = [{ name = "hypervclock", present = "yes" }]
  } : null

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

    # Windows has no serial console: VNC on the hypervisor's loopback only, for
    # emergencies (ssh -L 5900:127.0.0.1:<port> compute02; port from `virsh vncdisplay`)
    graphics = local.windows ? [{ vnc = { listen = "127.0.0.1", auto_port = true } }] : null

    # `virsh console <name>` (Ubuntu cloud images log to ttyS0)
    serials = [{
      target = { port = 0 }
    }]
    consoles = [{
      target = { type = "serial", port = 0 }
    }]
  }
}
