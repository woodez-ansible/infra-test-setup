# Windows Server 2022 golden image for the VM builder (build-windows-vm.md §4).
# Run by playbooks/windows-image.yml on compute02; not meant to be run by hand.
#
# The build VM uses Packer's private user-mode network (it's never on the LAN). WinRM
# HTTP with Basic auth is enabled inside it for Packer only, and removed again just
# before sysprep (scripts/finalize.ps1).

packer {
  required_version = "~> 1.16.0"
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "= 1.1.8"
    }
  }
}

variable "admin_password" {
  description = "Password of the local admin 'ansible' (from the vault, via PKR_VAR_admin_password)."
  type        = string
  sensitive   = true
}

variable "iso_path" {
  type = string
}

variable "iso_sha256" {
  type = string
}

variable "image_name" {
  description = "install.wim image NAME to install."
  type        = string
}

variable "cd_dir" {
  description = "Directory whose contents become the build's second CD: drivers, guest tools, scripts, cloudbase-init MSI + config."
  type        = string
}

variable "output_dir" {
  type = string
}

variable "vm_name" {
  type = string
}

locals {
  autounattend = templatefile("${path.root}/autounattend.xml.pkrtpl", {
    admin_password = var.admin_password
    image_name     = var.image_name
  })
}

source "qemu" "windows" {
  iso_url      = var.iso_path
  iso_checksum = "sha256:${var.iso_sha256}"

  # Second CD: answer file + everything setup and the provisioners need from disk
  cd_files   = ["${var.cd_dir}/*"]
  cd_content = { "autounattend.xml" = local.autounattend }
  cd_label   = "PACKERCD"

  accelerator  = "kvm"
  machine_type = "q35"
  cpus         = 4
  memory       = 8192

  efi_boot          = true
  efi_firmware_code = "/usr/share/OVMF/OVMF_CODE_4M.fd"
  efi_firmware_vars = "/usr/share/OVMF/OVMF_VARS_4M.fd"

  disk_interface     = "virtio"
  disk_size          = "40G"
  disk_discard       = "unmap"
  disk_detect_zeroes = "unmap"
  disk_compression   = true
  format             = "qcow2"
  net_device         = "virtio-net"

  output_directory = var.output_dir
  vm_name          = var.vm_name

  headless         = true
  vnc_bind_address = "127.0.0.1" # debug a stuck build over an SSH tunnel

  # UEFI shows "Press any key to boot from CD or DVD" for a few seconds
  boot_wait    = "2s"
  boot_command = ["<spacebar><wait1s><spacebar><wait1s><spacebar><wait1s><spacebar>"]

  communicator   = "winrm"
  winrm_username = "ansible"
  winrm_password = var.admin_password
  winrm_use_ssl  = false
  winrm_timeout  = "3h" # setup + first boot

  # finalize.ps1 removes Packer's WinRM HTTP access, then runs sysprep (generalize + shutdown)
  shutdown_command = "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\vmb\\scripts\\finalize.ps1"
  shutdown_timeout = "45m"
}

build {
  sources = ["source.qemu.windows"]

  # Copy the provisioning scripts off the CD into a fixed place
  provisioner "powershell" {
    inline = [
      "$cd = (Get-Volume | Where-Object FileSystemLabel -eq 'PACKERCD').DriveLetter + ':'",
      "New-Item -ItemType Directory -Force C:\\Windows\\Temp\\vmb | Out-Null",
      "Copy-Item -Recurse -Force \"$cd\\*\" C:\\Windows\\Temp\\vmb\\",
      "Get-ChildItem C:\\Windows\\Temp\\vmb | Select-Object -ExpandProperty Name",
    ]
  }

  provisioner "powershell" {
    script = "${path.root}/scripts/01-virtio.ps1"
  }

  provisioner "windows-restart" {
    check_registry  = true # wait out update servicing; WinRM answers while Windows is still shutting down
    restart_timeout = "30m"
  }

  # Windows Update: four rounds with reboots in between. Elevated (a scheduled task as
  # 'ansible'): the Windows Update API refuses installs from a plain remote WinRM session.
  # The last round only reports what's left rather than failing a 1-2 hour build.
  provisioner "powershell" {
    script            = "${path.root}/scripts/02-windows-update.ps1"
    elevated_user     = "ansible"
    elevated_password = var.admin_password
    max_retries       = 2 # a late update reboot kills the elevated task; the script is safe to re-run
  }
  provisioner "windows-restart" {
    check_registry  = true # wait out update servicing; WinRM answers while Windows is still shutting down
    restart_timeout = "60m"
  }
  provisioner "powershell" {
    script            = "${path.root}/scripts/02-windows-update.ps1"
    elevated_user     = "ansible"
    elevated_password = var.admin_password
    max_retries       = 2 # a late update reboot kills the elevated task; the script is safe to re-run
  }
  provisioner "windows-restart" {
    check_registry  = true # wait out update servicing; WinRM answers while Windows is still shutting down
    restart_timeout = "60m"
  }
  provisioner "powershell" {
    script            = "${path.root}/scripts/02-windows-update.ps1"
    elevated_user     = "ansible"
    elevated_password = var.admin_password
    max_retries       = 2 # a late update reboot kills the elevated task; the script is safe to re-run
  }
  provisioner "windows-restart" {
    check_registry  = true # wait out update servicing; WinRM answers while Windows is still shutting down
    restart_timeout = "60m"
  }
  provisioner "powershell" {
    script            = "${path.root}/scripts/02-windows-update.ps1"
    elevated_user     = "ansible"
    elevated_password = var.admin_password
    max_retries       = 2 # a late update reboot kills the elevated task; the script is safe to re-run
  }
  provisioner "powershell" {
    script = "${path.root}/scripts/03-cloudbase-init.ps1"
  }

  provisioner "powershell" {
    script = "${path.root}/scripts/04-cleanup.ps1"
  }
}
