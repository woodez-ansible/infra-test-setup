# Plan: Windows Server 2022 VMs on compute02 (Packer golden image + existing GitOps)

**Status:** approved 2026-11-19, with **username/password** WinRM login (not
certificates); W1 in progress. Facts below come from read-only checks of compute02 and
of upstream sources.

**Goal:** a Windows VM is just another spec file. `vms/win01.yml` with `vm_os: windows-2022`
goes through the same PR → `vm-validate` → merge → plan → **your approval** → apply flow
as the Ubuntu VMs, and comes up in ~5–10 minutes. It's configured over **WinRM HTTPS**
with a **local admin username and password** that is kept out of Terraform, plan files and
logs (§1).

## 1. Decisions

| Area | Choice |
|---|---|
| Edition | **Windows Server 2022** (LTSC, supported to 2031), Standard edition with Desktop Experience. Core is an option later (see §9) |
| Licensing | **Microsoft Evaluation ISO**: 180 days, re-armable. VMs are rebuildable, so expiry is managed by rebuilding. Evaluation terms don't allow production use |
| Image | **Packer golden image**, built on compute02. Unattended install, VirtIO drivers + guest agent, Windows Updates, cloudbase-init, sysprep. Result: a base volume `windows-2022-<YYYYMMDD>-base.qcow2` next to the Ubuntu ones |
| VM creation | The **existing** `terraform/vm` + `vm-build.yml` + `vm-gitops.yml`, with OS-specific branches; no second pipeline |
| First boot | **cloudbase-init**, reading the same `cidata` ISO the Linux VMs use (its `NoCloud` service): hostname, WinRM HTTPS listener, volume extension. **No user or password**: those are in the image |
| Management | **WinRM over HTTPS (5986)**, NTLM over TLS, as local admin **`ansible`** with a **password** (your decision, 2026-11-19; see "Where the password lives") |
| Firmware | **UEFI** (`OVMF_CODE_4M.fd` + a per-VM NVRAM copy), no Secure Boot or TPM, which Server 2022 doesn't need. Can be switched on later; compute02 has both (§2) |

### Where the password lives

The admin password must stay out of Terraform. A Terraform plan contains the VM's
cloud-init data, plans are saved in `/opt/vm-builder/plans/`, and the plan job runs
without approval. So:

| Place | How the password gets there |
|---|---|
| **Golden image** | Packer creates the local admin user `ansible` (Administrators) with the vault password **before sysprep**. Local accounts survive `sysprep /generalize`, so every VM starts with it. cloudbase-init never touches users |
| **Ansible vault** | `vault_windows_admin_password` in **`playbooks/vars/windows-vault.yml`** (encrypted, same vault password as the others). **You add it** (`ansible-vault create`); I never see the value. It's loaded **explicitly** (`include_vars`) only by `windows-image.yml` and by Windows builds run from the Mac. It must **not** go in `inventory/group_vars/hypervisors/`: the CI inventory puts compute02 in that group, so Ansible on the runner would try to decrypt it and fail every `vm-gitops` run ("no vault secrets found") |
| **CI (runner)** | GitHub **environment secret** `WINDOWS_ADMIN_PASSWORD` on **`vm-build`** and **`vm-destroy`**. GitHub only gives environment secrets to jobs that were **approved** to run in that environment, so the no-approval `plan` job never has it. You set it with `gh secret set WINDOWS_ADMIN_PASSWORD --env vm-build -R woodez-ansible/infra-test-setup` (it prompts) |
| **Existing VMs** | `baseline_windows` re-sets `ansible`'s password from the vault/secret on every run, so rotating it is: update the vault + secret, re-run builds |

Kept out of: Terraform variables and state, cloud-init/cidata, plan files, Ansible output
(`no_log` on every task that handles it), git (vault is encrypted).

**Trade-off you accepted:** one shared local admin password on all Windows VMs. A leak
opens every one of them. Per-VM random passwords stored in the vault (or LAPS) are a
possible later step.

## 2. What compute02 has today (checked 2026-11-19)

| Item | State |
|---|---|
| TPM 2.0 emulation | `swtpm` / `swtpm-tools` 0.7.3: installed (not needed for Server 2022) |
| UEFI firmware | `OVMF_CODE_4M.fd`, `OVMF_VARS_4M.fd`, plus Secure Boot variants with Microsoft keys (`OVMF_CODE_4M.ms.fd`, `OVMF_VARS_4M.ms.fd`) |
| VirtIO drivers for Windows | **missing**. Latest stable `virtio-win` ISO is 0.1.302 (Fedora); it provides `viostor`/`vioscsi`, `NetKVM`, balloon, and the **qemu-guest-agent MSI** that IP discovery depends on |
| Packer | **missing** (on compute02 and the Mac). Latest: Packer 1.16.2, `packer-plugin-qemu` 1.1.8; HashiCorp's apt repo is already configured on compute02 |
| cloudbase-init | latest 1.1.9 (2026-10-12) |
| Capacity | ~9.9 GiB RAM available, 284 GiB pool free; VMs: db01 (running), node03–05 (off) |

A Server 2022 VM needs 4 GiB RAM to be comfortable, so **two Windows VMs at a time** fit
next to db01. The existing preflight (RAM minus 1 GiB reserve) refuses anything more.

## 3. How it fits together

```
(once a month, or on demand)                         (every Windows VM, via GitOps)
playbooks/windows-image.yml on compute02             PR adds vms/win01.yml (vm_os: windows-2022)
  download + SHA-256-check Server 2022 eval ISO        └─► vm-validate (Windows rules too)
  download + check virtio-win ISO                     merge ─► vm-gitops plan (no approval)
  packer build (KVM, ~60–90 min):                        ⏸ you approve in "vm-build"
    autounattend.xml → install from ISO, VirtIO           └─► apply: COW disk on the Windows base,
      storage/net drivers loaded during setup                  cidata ISO (cloudbase-init), UEFI
    install guest agent + VirtIO drivers                       + NVRAM, NIC on br0, VNC console
    Windows Updates (loop until none left)                     on 127.0.0.1, guest-agent channel
    install cloudbase-init (NoCloud + our plugins)        wait for guest-agent IP
    sysprep /generalize /oobe /shutdown                   wait for WinRM HTTPS (5986)
  import qcow2 → windows-2022-<date>-base.qcow2         Windows baseline over WinRM (cert auth)
    (terraform/images, prevent_destroy)                   → summary: name, IP, MAC
```

## 4. Golden image (`packer/windows-2022/`, `playbooks/windows-image.yml`)

- **Where:** Packer runs **on compute02** (its qemu builder needs local KVM), as `kwood`
  or `gha-runner` via the shared `vm-builder` group. `hypervisor-prep.yml` installs
  Packer 1.16.2 (held), the qemu plugin 1.1.8 (in `/opt/vm-builder/packer-plugins`),
  `libarchive-tools`, `wimtools` and `libguestfs-tools`.
- **Storage:** the root filesystem is only 24 GB, so ISOs and builds live on the pool's
  filesystem (`/var/lib/libvirt/images`, 434 GB):
  - `/var/lib/libvirt/images/.vm-builder-cache/`: the Windows ISO, virtio-win RPM + ISO,
    cloudbase-init MSI
  - `/var/lib/libvirt/images/.vm-builder-packer/windows-2022-<YYYYMMDD>/`: one build per
    day: `<key>.qcow2`, `packer.log`, and a `<key>.complete` marker written only after the
    offline checks pass. Only builds with the marker become base volumes.

  libvirt lists these two hidden directories in `virsh vol-list default` as `dir`
  volumes. That is harmless; leave them alone (don't `vol-delete` them). A separate LV
  isn't possible: the volume group has no free space.
- **Inputs, pinned in `group_vars/hypervisors/vars.yml`:**
  - the Server 2022 evaluation ISO (SHA-256 recorded on first download)
  - `virtio-win` 0.1.302: Fedora publishes only an MD5 for the RPM, so the RPM is checked
    with that, the ISO is extracted from it, and the ISO's SHA-256 is pinned too. Drivers
    are pulled out with `xorriso` (the ISO stores them as hard links that `bsdtar` can't
    resolve in a partial extract)
  - cloudbase-init 1.1.9 MSI (SHA-256 from its GitHub release)
- **Packer template (HCL):**
  - `source "qemu"`: q35, KVM, UEFI (`OVMF_CODE_4M.fd`), 4 vCPU / 8 GiB during the build
    only, a 40 GiB virtio disk, a virtio NIC on Packer's private user-mode network (the
    build VM is **not** on your LAN)
  - `cd_files`: `autounattend.xml`, the VirtIO drivers (so setup can see the virtio disk),
    `bootstrap.ps1`
  - `autounattend.xml` (rendered by Packer from `autounattend.xml.pkrtpl`, so the password
    never sits in a file in the repo): edition **Windows Server 2022 Standard Evaluation
    (Desktop Experience)**, a GPT layout for UEFI, the local admin **`ansible`** with the
    vault password, then it runs `bootstrap.ps1`
  - `bootstrap.ps1`: installs the VirtIO guest tools (drivers + QEMU guest agent), then
    enables WinRM **HTTP on the private build network only**, for Packer to drive the
    build. The guest tools must go in **before** WinRM: the installer reloads the network
    driver, which silently kills any WinRM command in flight and leaves Packer waiting
    forever. `finalize-run.ps1` removes the HTTP listener, Basic auth, auto-logon and the
    Panther unattend copy before sysprep; none of it exists on real VMs
  - provisioners:
    1. check the guest tools result from bootstrap and that `QEMU-GA` runs
    2. Windows Updates: four rounds with reboots in between (the last two normally find
       nothing). Uses the built-in Windows Update API from PowerShell (elevated, as a
       scheduled task), so no third-party Packer plugin. The restarts use
       `check_registry = true`: after a cumulative update Windows keeps answering WinRM for
       minutes while it services the update on the way down, and without it Packer
       starts the next round on a machine that is about to reboot
    3. cloudbase-init MSI, configured: metadata service `NoCloudConfigDriveService`;
       plugins `SetHostName`, `ExtendVolumes`, `ConfigWinRMListener` (HTTPS, self-signed
       certificate), `UserData`. No `CreateUser`/`SetUserPassword`: the user is already in
       the image
    4. cleanup: temp files, `Dism /Cleanup-Image`, zero free space
    5. **sysprep** `/generalize /oobe /shutdown` with cloudbase-init's unattend file
- **Output:** qcow2, compressed. `windows-image.yml` checks it offline with `virt-cat`
  (State.ini must say `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`; cloudbase-init's config
  must be in place), writes the `.complete` marker, then runs `terraform/images`. Each
  completed build is a `for_each` key `windows-2022-<YYYYMMDD>` (found by
  `playbooks/tasks/windows-builds.yml`, also used by `hypervisor-prep.yml` so prep never
  drops them), named `windows-2022-<YYYYMMDD>-base.qcow2`, with `prevent_destroy`.
  Ubuntu volume names are unchanged.
- **Running it:** `ansible-playbook playbooks/windows-image.yml` from the Mac (needs the
  vault password file). A day that already has a completed build only reloads the base
  volume. A failed build is redone from scratch; see `packer.log` in the build directory.
  To watch a stuck build: `ssh -L 5900:127.0.0.1:59xx compute02` (port in `packer.log`)
  and a VNC viewer.
- **Refreshing:** run `windows-image.yml` again (monthly, after Patch Tuesday). That makes
  a new dated base volume; existing VMs keep theirs. The old base is deleted only when no
  VM uses it.
- **Build time:** 1 h 10 min for the first build (2026-11-20), most of it updates. It
  isn't part of a VM build: each VM is a copy-on-write disk on the base volume.
- **Security checks done on the first build:** the admin password appears 0 times in
  `packer.log`, the playbook output, Panther's `unattend.xml`/`setupact.log` and the
  bootstrap/finalize logs; WinRM ends with `Basic = false`, `AllowUnencrypted = false`;
  no `DefaultPassword`/auto-logon values remain in Winlogon.

## 5. VM spec and settings

New and changed settings (validator, defaults and the build-vm.md §4 table updated):

| Setting | Linux default | Windows (`vm_os: windows-2022`) |
|---|---|---|
| `vm_os` (new) | `ubuntu` | `windows-2022` |
| `vm_name` | ≤32 chars | **≤15 chars** (Windows NetBIOS name limit) |
| `vm_memory_mib` | 2048 | default **4096**, minimum **2048** |
| `vm_disk_gib` | 20 | default **60**, minimum **40** (the base image's size). **Fixed after creation**, as for Linux |
| `vm_vcpus` | 2 | 2 |
| `vm_firmware` | bios | **uefi** (forced) |
| `vm_ubuntu_release` | used | ignored (validator rejects it on Windows specs) |
| `vm_timezone` | America/Toronto | same, mapped to the Windows ID `Eastern Standard Time` |
| `vm_packages` | apt | **not used**; use `vm_windows_features` |
| `vm_windows_features` (new) | – | Windows features/roles to install, e.g. `[Web-Server]` |
| `vm_user`, `vm_ssh_authorized_keys`, `vm_passwordless_sudo`, `vm_password_login` | used | **rejected** on Windows specs (Linux only) |

Example:
```yaml
vm_name: win01
vm_os: windows-2022
vm_vcpus: 2
vm_memory_mib: 4096
vm_disk_gib: 60
vm_description: "Windows test VM"
```

## 6. Terraform and playbook changes

- **`terraform/vm`:** a new `os` variable switches:
  - base volume path (Windows base from the images output)
  - cloud-init content: `templates/windows-user-data.yaml.tftpl` for cloudbase-init
    (hostname, WinRM settings) with **no credentials in it**. No network-config: Windows
    uses DHCP on the virtio NIC by default and identifies by MAC, so DHCP reservations work
    as for Linux
  - firmware `efi` + a per-VM NVRAM file (in the pool, so it's cleaned up on destroy)
  - **graphics:** VNC on `127.0.0.1` only, for emergency console access over an SSH
    tunnel (Windows has no serial console). Linux VMs are unchanged
  - same virtio disk/NIC, same guest-agent channel (the agent comes from the image)
- **`vm-build.yml`:**
  - validation and preflight get the Windows rules from §5
  - after apply, it waits for the guest-agent IP (as now), then for **port 5986**
  - the baseline play splits into **`baseline_linux`** (today's, via SSH) and a new
    **`baseline_windows`** (via WinRM). The new one sets the timezone, configures
    `w32time` with `ca.pool.ntp.org`, opens WinRM 5986 (and RDP 3389, LAN only), installs
    `vm_windows_features`, writes a baseline marker (registry), and reports
- **`vm-destroy.yml`:** unchanged apart from also removing the NVRAM file
- **`ci/validate_vm_spec.py`:** OS-aware rules from §5
- **`requirements.txt`, runner venv:** add `pywinrm` (pinned 0.5.0); add the
  `ansible.windows` collection to `requirements.yml` and the runner's collections
- **`hypervisor-prep.yml`:** Packer + qemu plugin; `virtio-win` download
- **Connection settings** for Windows VMs: `ansible_connection: winrm`, port 5986,
  `ansible_winrm_transport: ntlm`, `ansible_user: ansible`, `ansible_password` from the
  vault, or in CI from the `WINDOWS_ADMIN_PASSWORD` environment variable. All tasks that
  touch it use `no_log`

### WinRM server certificate

cloudbase-init creates a self-signed HTTPS certificate per VM. Ansible connects with
`ansible_winrm_server_cert_validation: ignore`, because a per-VM self-signed
certificate can't be pinned in advance. This is an accepted lab trade-off: traffic is
encrypted (TLS, plus NTLM message encryption), and 5986 is only open to 192.168.2.0/24.
A later step can pin each VM's certificate thumbprint, taken over the guest agent at
build time.

## 7. GitOps

- **No workflow changes needed**: `vm-gitops` already loops over specs and runs the same
  playbooks; Windows specs simply take the Windows branches.
- `vm-validate` installs `pywinrm`, so the syntax check covers the Windows play.
- The runner gets the password only as the **`WINDOWS_ADMIN_PASSWORD` environment
  secret**, in approved `apply-build`/`apply-destroy` jobs. `vm-gitops.yml` passes it to
  `ansible-playbook` as an environment variable (never as a command-line argument, which
  could appear in process lists or logs).
- The image build is **not** part of GitOps at first: you run `windows-image.yml` by hand.
  A later `windows-image` workflow (manual trigger + approval) is easy to add.

## 8. Delivery (one PR each, separate worktrees, logged in `working-hard.md`)

| Step | Content | Done when |
|---|---|---|
| **W1** | Packer + virtio-win on compute02 (`hypervisor-prep.yml`), ISO pins, Packer template + `autounattend.xml` + scripts, `windows-image.yml` | a `windows-2022-<date>-base.qcow2` exists in the pool; booting a throwaway copy shows sysprep OOBE handing over to cloudbase-init |
| **W2** | `terraform/vm` OS switch, cloudbase-init template, UEFI/NVRAM/VNC; validator + defaults | `win01` built **by hand** (`vm-build.yml`) gets a guest-agent IP, has 5986 open, and accepts a WinRM login as `ansible` from the Mac; **the password appears in no plan file, state or log** (grep-checked) |
| **W3** | `baseline_windows` (timezone, NTP, firewall, features, password re-set, marker) + `pywinrm` in venvs | baseline reports Server 2022, correct timezone, NTP synced, features installed; re-run `changed=0` |
| **W4** | GitOps: `WINDOWS_ADMIN_PASSWORD` environment secret + `ansible.windows` on the runner; end-to-end via PR | add `vms/win01.yml` → approve → built; edit → restart guard works; delete → approve → destroyed; base image untouched; the plan job has no access to the secret |
| **W5** | docs: Windows sections in build-vm.md (Part A) | how-to covers add/rebuild/refresh image/troubleshooting |

## 9. Risks and open points

- **Evaluation ISO URL:** Microsoft's evaluation download links are redirects that change
  with new builds. The pinned SHA-256 makes a changed file fail loudly, not silently. The
  fix is to download the new ISO and update the pin.
- **Expiry:** evaluations run 180 days (`slmgr /rearm` extends, a limited number of
  times). Rebuilding from a fresh image resets it, so keep Windows VMs rebuildable (state
  on separate disks or elsewhere).
- **Packer builds are the fragile part:** autounattend and update loops can hang. W1 adds
  a build timeout, and keeps the VNC console of the build VM (127.0.0.1) for debugging.
- **Disk size is fixed after creation** (the provider can't resize volumes), so pick
  `vm_disk_gib` generously. 60 GiB is the default; add `vm_extra_disks` for data.
- **NetBIOS 15-character names:** the validator enforces it.
- **Server certificate validation is off** (see §6). It's encrypted and LAN-only, but not
  pinned.
- **Shared admin password** across all Windows VMs (your choice). Keep it strong; rotate
  by updating the vault + environment secret and re-running builds.
- **The evaluation ISO is the March 2022 release build** (Last-Modified 2022-03-16), so
  the first image build has to install years of cumulative updates. They're cumulative, so
  it's a few large downloads, not hundreds.
- **Desktop Experience vs Core:** Desktop Experience is easier to debug over VNC/RDP
  but ~2× the disk and RAM of Core. Core is a later option as a second image.
- **Secure Boot/TPM** are available on compute02 but not used for Server 2022. They'd be
  needed for Windows 11.
- **RAM:** two Windows VMs at most next to db01 (the preflight enforces it).
