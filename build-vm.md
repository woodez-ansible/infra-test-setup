# Plan: build Ubuntu VMs on libvirt (compute02) with Terraform + Ansible

Status: **draft, awaiting approval.** Nothing has been changed on compute02. This plan
is based on read-only checks of compute02 made on 2026-11-06.

The goal is one command that builds a VM from a short settings file you control:

```bash
ansible-playbook playbooks/vm-build.yml -e @vms/web01.yml
```

The playbook runs Terraform on the hypervisor to create the VM, waits for it to boot
and get a DHCP address, then connects over SSH and applies a baseline.
`vm-destroy.yml` removes a VM again.

## 1. Decisions

| Area | Choice |
|---|---|
| Hypervisor | **compute02**, 192.168.2.6, SSH as `kwood`, sudo to root |
| IaC tool | **Terraform v1.17.1** with provider **`dmacvicar/libvirt` v0.9.9**, both pinned |
| Where Terraform runs | **On compute02**, as `kwood`, against `qemu:///system` (kwood is in the `libvirt` group, so no sudo is needed at run time) |
| Orchestration | **Ansible on the Mac** drives everything: syncs the Terraform code, renders the VM's settings, runs Terraform, waits for the VM, then configures it |
| OS image | **Ubuntu 26.04 LTS** cloud image by default; settable per VM (e.g. 24.04) |
| Network | **DHCP on bridge `br0`**: the VM is an ordinary LAN host, like db01 |
| Finding the IP | **qemu-guest-agent**, installed by cloud-init; libvirt can't see the router's DHCP leases on a bridged network |
| Disks | copy-on-write qcow2 on a shared base image in pool `default` (`/var/lib/libvirt/images`, 281 GiB free) |
| State | one **Terraform workspace per VM** on compute02, so destroying one VM can't touch another |

## 2. What compute02 looks like today

| Item | Value |
|---|---|
| OS / virtualisation | Ubuntu 24.04.2, kernel 6.8, libvirt 10.0, QEMU 8.2.2, `libvirtd` active |
| CPU / RAM | 16 threads (Ryzen 7 5825U, AMD-V) / 15 GiB, **~10 GiB available** |
| Storage pools | `default` → `/var/lib/libvirt/images`, 434 GiB, **281 GiB free**; `tmp` → `/var/tmp` |
| Networks | bridge **`br0`** on `enp1s0` holds 192.168.2.6/24; libvirt NAT network `default` (virbr0, unused) |
| Existing VMs | `db01.apexkube.xyz` running (6 vCPU / 6 GiB, bridged on br0); `node03`–`node05` shut off |
| Tools present | `xorriso`; Terraform is not installed |
| Access | SSH key login works. kwood is in `libvirt` and `kvm`, and has **passwordless sudo** (confirmed 2026-11-06) |
| Security | AppArmor enforcing, with one `libvirt-<uuid>` profile per VM; `qemu.conf` at defaults apart from the standard `swtpm_user`/`swtpm_group` lines |

## 3. How a build works

```
Mac: ansible-playbook playbooks/vm-build.yml -e @vms/web01.yml
 1. validate settings; preflight on compute02:
      name unused, RAM fits, pool has space, base image present
 2. copy terraform/ to compute02:/opt/vm-builder (only if changed)
 3. render /opt/vm-builder/vms/web01.tfvars.json from the settings
 4. on compute02, as kwood:
      terraform -chdir=/opt/vm-builder/vm workspace select -or-create web01
      terraform apply -var-file=../vms/web01.tfvars.json
        → volume web01.qcow2 (backed by the base image, resized)
        → cloud-init ISO volume (hostname, user, SSH key, DHCP, qemu-guest-agent)
        → domain web01: vCPU, RAM, virtio disk, NIC on br0 with a fixed MAC,
          guest-agent channel, autostart
 5. wait until the guest agent reports an IPv4 address on br0
 6. wait for SSH, then wait for cloud-init to report done
 7. baseline: timezone + chrony, apt upgrade (optional), extra packages, guest agent enabled
 8. print a summary: name, IP, MAC, vCPU/RAM/disk, and an inventory line to copy
```

## 4. VM settings: what you can specify

A VM is one small YAML file in `vms/`. Anything you leave out takes the default shown.

```yaml
# vms/web01.yml
vm_name: web01               # required: hostname and libvirt domain name
vm_vcpus: 2
vm_memory_mib: 2048
vm_disk_gib: 20
vm_ubuntu_release: "26.04"   # "26.04" | "24.04"
```

| Setting | Default | Notes |
|---|---|---|
| `vm_name` | **required** | lowercase letters, digits and `-`; becomes the hostname and the domain name |
| `vm_vcpus` | `2` | checked against free host CPUs (warning only; CPUs can be shared) |
| `vm_memory_mib` | `2048` | **hard check**: must fit in available host RAM minus a 1 GiB reserve |
| `vm_disk_gib` | `20` | root disk; it grows the base image, which is about 3.5 GB |
| `vm_extra_disks` | `[]` | e.g. `[{size_gib: 20}]`; blank qcow2 disks, left unformatted |
| `vm_ubuntu_release` | `"26.04"` | selects the base image |
| `vm_bridge` | `br0` | |
| `vm_mac` | derived from the name | a stable MAC per name, so a **DHCP reservation on the router** can give the VM a fixed IP; set it explicitly to override |
| `vm_user` | `kwood` | created by cloud-init |
| `vm_ssh_authorized_keys` | your Mac's `~/.ssh/id_*.pub` | list |
| `vm_passwordless_sudo` | `true` | the same as the other hosts |
| `vm_password_login` | `false` | SSH keys only |
| `vm_timezone` | `America/Toronto` | baseline applies chrony with `ca.pool.ntp.org`, as on db01 and the k8s nodes |
| `vm_packages` | `[]` | extra apt packages installed by the baseline |
| `vm_apt_upgrade` | `true` | full upgrade on first build |
| `vm_autostart` | `true` | start when compute02 boots |
| `vm_firmware` | `bios` | or `uefi` (OVMF is installed) |
| `vm_cpu_mode` | `host-passthrough` | best performance; use `host-model` if you might move VMs between hosts |
| `vm_description` | `""` | stored as the libvirt domain title |

Settings are validated before anything is built: types, ranges, name format, and a
check that the name isn't already a libvirt domain or a Terraform workspace.

## 5. Repo layout (new files only)

```
terraform/
  images/                  # base cloud images, one per release; built once, separate state
    main.tf  variables.tf  versions.tf
  vm/                      # one VM per workspace
    main.tf  variables.tf  outputs.tf  versions.tf
    templates/user-data.yaml.tftpl  meta-data.yaml.tftpl  network-config.yaml.tftpl
vms/
  example.yml              # documented example settings
inventory/hosts.yml        # + hypervisors: compute02
inventory/group_vars/hypervisors/vars.yml   # pool, bridge, image URLs, versions, defaults
playbooks/
  hypervisor-prep.yml      # one-time: install Terraform, create /opt/vm-builder, base images
  vm-build.yml             # build or update a VM from vms/<name>.yml
  vm-destroy.yml           # -e vm_name=web01 -e confirm=yes
  vm-list.yml              # VMs, state, IPs, resources; host capacity left
build-vm.md                # this plan, then the how-to
```

### Why base images have their own Terraform state

If each VM's state also owned the Ubuntu base image, `terraform destroy` of any one VM
would delete the base image that every other VM's disk depends on. So:

- `terraform/images` manages `ubuntu-26.04-base.qcow2` and `ubuntu-24.04-base.qcow2`
  once, in its own state.
- VM disks are copy-on-write volumes backed by those images.
- `terraform/images` refuses to delete a base image while any VM disk still uses it.

### Terraform details

- **Code location:** `/opt/vm-builder` on compute02, owned by kwood. State lives in
  `/opt/vm-builder/vm/terraform.tfstate.d/<name>/` (one directory per workspace).
  `hypervisor-prep.yml` adds a nightly copy of all state to `/var/backups/vm-builder/`.
- **Provider:** `uri = "qemu:///system"`. Terraform runs locally on compute02, so
  there's no SSH tunnel inside Terraform.
- **Domain:** `q35` machine type; virtio disk and NIC; an `org.qemu.guest_agent.0`
  channel; a serial console, so `virsh console web01` works.
- **IP lookup:** the `libvirt_domain_interface_addresses` data source with
  `source = "agent"`. Terraform itself doesn't wait for the IP. Ansible polls for it, so
  a slow first boot can't hang or fail the `apply`.

### cloud-init (rendered per VM)

- **`meta-data`:** `instance-id` and `local-hostname`.
- **`user-data`:**
  - user, SSH keys, sudo rule; password login off
  - `package_update` and the `qemu-guest-agent` package, started at first boot
  - growpart, so the root filesystem fills the disk
  - the timezone
- **`network-config` (v2):** DHCP on the first NIC. It matches the NIC by MAC address,
  because interface names differ between machine types.

## 6. Playbooks

| Playbook | Runs on | What it does |
|---|---|---|
| `hypervisor-prep.yml` | compute02 (sudo) | adds the HashiCorp apt repo and installs `terraform=1.17.1-*` (held); creates `/opt/vm-builder`; runs `terraform -chdir=images apply`; sets up the state backup; checks `virt-host-validate` |
| `vm-build.yml` | compute02, then the new VM | steps 1–8 of section 3; re-running it with changed settings updates the VM in place where libvirt allows (see below) |
| `vm-destroy.yml` | compute02 | needs `-e confirm=yes`; `terraform destroy` in that VM's workspace, removes the workspace and its tfvars, reports the space freed |
| `vm-list.yml` | compute02 | table of VMs with state, IP (from the agent), vCPU, RAM and disk, plus free host RAM and pool space |

**What a re-run can change:**

- **Applied with a reboot of the VM:** vCPU and RAM. The playbook shuts the VM down and
  starts it again, and asks for `-e allow_restart=yes` first.
- **Grown in place:** disk size. Shrinking is refused.
- **Replaces the VM:** a different Ubuntu release or a new MAC address. Terraform's plan
  would show this, and the playbook stops unless you pass `-e allow_replace=yes`.

## 7. How the plan is verified (when it's built)

1. **`hypervisor-prep.yml`:** `terraform version` is 1.17.1 on compute02, and the base
   image volumes exist (`virsh vol-list default`). A re-run reports `changed=0`.
2. **Build `vms/test01.yml`** with 1 vCPU, 1 GiB RAM and a 10 GiB disk:
   - the domain is running, with autostart on
   - the guest agent reports a 192.168.2.x address
   - SSH works as kwood with the Mac's key, and `sudo -n true` succeeds
   - `hostnamectl` shows `test01`
   - `df -h /` is about 10 GiB, meaning growpart worked
   - `lsb_release` shows 26.04
   - `timedatectl` shows Toronto time and a synced clock
3. **Re-run the same build.** Terraform's plan shows no changes, and Ansible reports
   `changed=0`.
4. **Change `vm_memory_mib` to 2048 and re-run with `-e allow_restart=yes`.** The VM
   restarts with 2 GiB RAM.
5. **Build a 24.04 VM** to prove the release setting works, and a second 26.04 VM to
   prove two VMs share one base image.
6. **Destroy `test01`.** Its domain and volumes are gone, the base image and the other
   VMs are untouched, and `vm-list.yml` shows the RAM returned.
7. **Negative tests:**
   - a duplicate name is refused
   - a VM bigger than the free RAM is refused
   - a bad name such as `Web_01` is refused
   - `vm-destroy.yml` without `confirm=yes` is refused

## 8. Delivery

Per your git rules, the work goes on a branch with a PR rather than straight onto
`master`, and each step gets a `working-hard.md` entry:

1. `hypervisor-prep.yml` + `terraform/images`, then run and verify (section 7, step 1)
2. `terraform/vm` + `vm-build.yml` + `vm-list.yml`, then verify (steps 2–5)
3. `vm-destroy.yml` + negative checks, then verify (steps 6–7)
4. Turn this plan into a how-to section in this file, with a reference for every setting

## 9. Risks, assumptions and open items

- **sudo is passwordless** (fixed and confirmed 2026-11-06). Only `hypervisor-prep.yml`
  uses it. Building and destroying VMs run as kwood through the `libvirt` group.
- **DHCP addresses can change.** A VM's IP may differ after a rebuild or after its
  lease expires. Because each VM gets a stable MAC, a **DHCP reservation on the
  router** pins it. For anything long-lived, such as a server you'll put in the
  inventory, add a reservation. A static-IP option can be added later without
  changing the design.
- **The playbook doesn't add new VMs to `inventory/hosts.yml`.** It prints the line to
  add. Writing the inventory automatically is easy to add, but DHCP IPs make
  auto-written entries unreliable without a reservation.
- **RAM is the real limit.** About 10 GiB is free with db01 running. If `node03`–`05`
  are started again, that shrinks. The preflight check refuses builds that don't fit.
- **The libvirt provider rewrote its schema in v0.9.** Older 0.7/0.8 examples you find
  online won't work. The plan pins 0.9.9 and uses its documented resources.
- **AppArmor** confines each VM to its own files; copy-on-write disks inside the pool
  directory are allowed. If a backing-chain permission error appears in testing, the
  fix is a per-domain AppArmor rule, *not* `security_driver = "none"`.
- **Terraform's licence** (BSL) is fine for internal use. OpenTofu could replace it
  later with no code changes.
