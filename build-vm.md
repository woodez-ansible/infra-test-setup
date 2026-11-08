# Ubuntu VMs on compute02: how-to (GitOps with GitHub Actions, Terraform, Ansible)

**Status:** built and verified on 2026-11-07 (steps 1–5). Part A below is how to use and
run it. Part B is the original design, the decisions behind it and the test results.

**In one sentence:** each file `vms/<name>.yml` on `master` *is* a VM on compute02
(192.168.2.6). Merging a change plans it on a GitHub runner on compute02, and nothing is
applied until you approve it in GitHub.

```
PR edits vms/<name>.yml ──► vm-validate (GitHub's runners: checks only, never touches compute02)
merge to master ─────────► vm-gitops on the compute02 runner
                             plan   every spec + every builder VM without a spec (no approval)
                             ⏸ you approve in "vm-build" / "vm-destroy"
                             apply  exactly the plan you saw, one VM at a time
```

---

# Part A: how-to

## A1. Add a VM

1. Copy the example and edit it. **The file name must equal `vm_name`.**
   ```bash
   cp vms/example.yml vms/web01.yml     # then set vm_name: web01, size, release...
   ```
   Every setting is optional except `vm_name`; see the table in **§4** (Part B).
   Common ones: `vm_vcpus`, `vm_memory_mib`, `vm_disk_gib`, `vm_ubuntu_release`
   (`"26.04"` or `"24.04"`, quoted), `vm_packages`, `vm_description`.
2. Open a PR. The exact commands are in **A1a** below. **`vm-validate`** must pass: it
   checks the spec (ranges, choices, file name = `vm_name`, **unknown keys are errors**, so
   typos can't fall back to defaults silently), the Terraform code and the Ansible syntax.
   Fix and push until it's green.
3. Merge. Then go to **Actions → vm-gitops** (latest run):
   - the **plan** job's summary shows exactly what will be created
   - a yellow **Review deployments** banner appears: tick **vm-build** → **Approve and
     deploy** (or **Reject**)
4. When `apply-build` finishes, its summary shows the VM's **IP and MAC**. Log in with
   `ssh kwood@<ip>`. Your Mac's key (`vm_admin_authorized_keys`) and the runner's key are
   both installed, and `sudo` needs no password.
5. **Pin the IP:** add a DHCP reservation on the router for the MAC shown. The MAC is
   derived from the VM name, so it stays the same across rebuilds.

Timing, measured on `test01`: the plan job took 28 s. The apply took about 4.5 minutes
after approval, most of it the first-boot `apt` upgrade, then the baseline (timezone,
chrony, packages).

## A1a. The exact commands (git + GitHub CLI)

Run from the repo root on the Mac. Changes reach `master` only through a PR: the
`master-protection` ruleset blocks direct pushes. This example adds `web01`.

```bash
# 1. Start from an up-to-date master, on a new branch
git switch master && git pull --ff-only
git switch -c vms/add-web01

# 2. Write the spec (file name = vm_name) and check it locally, before GitHub does
cp vms/example.yml vms/web01.yml            # edit: vm_name: web01, size, release...
source .venv/bin/activate
python ci/validate_vm_spec.py vms/web01.yml

# 3. Commit, push and open the PR
git add vms/web01.yml
git commit -m "vms: add web01"
git push -u origin vms/add-web01
gh pr create --base master --title "vms: add web01" \
  --body "Adds vms/web01.yml: 2 vCPU, 2 GiB, 20 GiB, Ubuntu 26.04."

# 4. Wait for the required check, then merge with a merge commit
gh pr checks --watch
gh pr merge --merge --delete-branch

# 5. Follow the vm-gitops run the merge started, and open it in the browser to approve
gh run list --workflow vm-gitops.yml --limit 1
gh run watch "$(gh run list --workflow vm-gitops.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view --web "$(gh run list --workflow vm-gitops.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

In the browser: **Review deployments** → tick **vm-build** (or **vm-destroy**) →
**Approve and deploy**, or **Reject**. `gh run watch` keeps showing progress; when it
finishes, `gh run view <id>` shows the job summary with the VM's IP.

**Same steps for a change or a removal**, with a different branch, file and message:

```bash
# Change: edit the spec (add vm_allow_restart: true if it restarts the VM, see A2)
git switch master && git pull --ff-only && git switch -c vms/resize-web01
$EDITOR vms/web01.yml && python ci/validate_vm_spec.py vms/web01.yml
git commit -am "vms: web01 to 4 GiB" && git push -u origin vms/resize-web01
gh pr create --base master --fill

# Remove: delete the spec, then approve the destroy in "vm-destroy"
git switch master && git pull --ff-only && git switch -c vms/remove-web01
git rm vms/web01.yml
git commit -m "vms: remove web01" && git push -u origin vms/remove-web01
gh pr create --base master --fill
```

`--fill` uses the commit message as the PR title and body. Then continue from step 4.

**Approving from the terminal** (optional; the browser is simpler). This approves every
deployment waiting in `vm-build` for the latest run. Use the `vm-destroy` environment
for removals:

```bash
R=woodez-ansible/infra-test-setup
RUN=$(gh run list --workflow vm-gitops.yml --limit 1 --json databaseId --jq '.[0].databaseId')
ENV=$(gh api repos/$R/environments/vm-build --jq .id)
gh api repos/$R/actions/runs/$RUN/pending_deployments          # what is waiting
gh api -X POST repos/$R/actions/runs/$RUN/pending_deployments \
  -F "environment_ids[]=$ENV" -f state=approved -f comment="approved from the CLI"
```

Use `-f state=rejected` to reject. Only a required reviewer of the environment
(`kevinwood75`) can approve or reject.

## A2. Change a VM

Edit its spec in a PR, merge, approve. What happens depends on the change:

| Change | Effect | Needs in the spec |
|---|---|---|
| `vm_disk_gib` (any change) | **refused at plan time**. Provider 0.9.9 can't change a volume in place ("Storage volumes cannot be updated"), so the apply would only fail. For more space, add a disk with `vm_extra_disks`, which restarts the VM | (not possible) |
| **Any other in-place change**: `vm_vcpus`, `vm_memory_mib`, `vm_description`, `vm_autostart`, ... | the VM **restarts**: clean shutdown, forced after 30 s, then started again | `vm_allow_restart: true` |
| `vm_ubuntu_release`, `vm_mac` | the VM is **rebuilt** and its **disk is lost** | `vm_allow_replace: true` |
| `vm_packages`, `vm_timezone` | **not applied by GitOps on their own.** They're baseline settings, not Terraform ones, so the plan says "No changes" and nothing is applied. Apply them with the manual fallback (A4: `vm-build.yml -e @vms/<name>.yml`), or together with a change that Terraform does see | nothing |
| `vm_user`, `vm_ssh_authorized_keys`, `vm_password_login`, `vm_passwordless_sudo` | **ignored for an existing VM**: cloud-init only reads them on first boot | (rebuild to change) |

Without the needed flag, the **plan job fails** with a message explaining why, and nothing
is applied. Remove `vm_allow_restart`/`vm_allow_replace` again after the change, so a later
edit can't restart or rebuild the VM by accident.

## A3. Remove a VM

Delete `vms/<name>.yml` in a PR and merge. The plan shows **"<name>: DESTROY (its spec was
removed)"** with every resource that will be deleted. Approve in **vm-destroy**. The VM, its
disks and its Terraform workspace are deleted; base images and other VMs are never touched.

**Any VM the builder manages but has no spec on `master` is proposed for destruction on
every run.** If you see a destroy you didn't expect, **Reject** it, then add the spec back.

## A4. Without GitHub (manual fallback from the Mac)

Same code and settings, run directly. You need the repo's venv; no approvals are
involved, so you are the approval.

```bash
source .venv/bin/activate
ansible-playbook playbooks/vm-list.yml                                      # VMs, IPs, sizes, free RAM/pool
ansible-playbook playbooks/vm-build.yml -e @vms/web01.yml                   # build/update (plan + apply)
ansible-playbook playbooks/vm-build.yml -e @vms/web01.yml -e vm_phase=plan  # plan only, change nothing
ansible-playbook playbooks/vm-destroy.yml -e vm_name=web01 -e confirm=yes   # destroy
```

Commit the spec afterwards. Otherwise the next GitOps run will propose destroying the VM
(see A3).

## A5. Operations

| Task | How |
|---|---|
| Is the runner up? | GitHub → Settings → Actions → Runners (`compute02`, Idle/Active), or `systemctl status actions.runner.woodez-ansible-infra-test-setup.compute02` on compute02 |
| Restart the runner | `sudo systemctl restart actions.runner.woodez-ansible-infra-test-setup.compute02` |
| Re-install / upgrade the runner | change `gha_runner_version` + `gha_runner_sha256` in `inventory/group_vars/hypervisors/vars.yml` (the SHA-256 is in the release notes), remove, then re-run `hypervisor-prep.yml` |
| Remove the runner | `ansible-playbook playbooks/hypervisor-prep.yml -e gha_runner_remove=yes` |
| Re-run prep (idempotent) | `ansible-playbook playbooks/hypervisor-prep.yml`; a clean host reports `changed=0` |
| Newer Ubuntu image | add the new dated build (URL + SHA-256 from `SHA256SUMS`) under `ubuntu_images` in `group_vars/hypervisors/vars.yml`, run `hypervisor-prep.yml`. A new base volume is added; existing VMs keep theirs |
| Capacity | `vm-list.yml`; builds refuse to start if RAM (keeping 1 GiB reserve) or pool space don't fit |
| State backups | nightly in `/var/backups/vm-builder/state-*.tgz` (14 days). Restore: stop the runner, untar over `/opt/vm-builder` |
| Re-run a plan by hand | Actions → vm-gitops → **Run workflow**: reconciles everything, same approvals |

## A6. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| **`ssh` says "REMOTE HOST IDENTIFICATION HAS CHANGED"** for a VM's IP | A rebuilt VM got an IP your Mac knew from an older VM (DHCP reuse); CI builds clean `known_hosts` on the runner, not your Mac. **Check before trusting:** on compute02 run `sudo -u gha-runner sh -c 'ssh-keygen -F <ip> -f ~/.ssh/known_hosts \| ssh-keygen -lf -'`. That's the key the runner saw right after building. If it matches the fingerprint ssh shows you: `ssh-keygen -R <ip>`, then connect again |
| Plan job fails: "This change restarts …" / "would REBUILD …" | Expected guard. Add `vm_allow_restart: true` / `vm_allow_replace: true` if you mean it (A2) |
| Plan job fails: "This change resizes a disk …" | Disks can't be resized by this provider. Revert `vm_disk_gib`, and add space with `vm_extra_disks` (A2) |
| Plan job fails: "Not enough RAM" / pool space | Free capacity or shrink the spec; see `vm-list.yml` |
| Plan job fails: "… already exists but isn't managed by the VM builder" | The name belongs to a hand-made VM (e.g. `node03`); pick another name. The builder never touches unmanaged VMs |
| `vm-validate` fails: "unknown setting" | A typo in a key (e.g. `vm_memroy_mib`); see §4 |
| Jobs stay "Queued" / "Waiting for a runner" | Runner offline: check and restart it (A5) |
| A run shows "failure" after you clicked **Reject** | Normal: GitHub marks rejected deployments as failed. Nothing was applied |
| The VM's IP changed after a restart | Should not happen: VMs identify to DHCP by MAC (`dhcp-identifier: mac`). Add a router reservation for the MAC to pin it |
| `Permission denied` under `/opt/vm-builder` in CI | Something there isn't group-writable for `vm-builder` (kwood and gha-runner share it). Re-run `hypervisor-prep.yml`, which fixes Terraform's own files |
| VM fails to start: "Could not open … base.qcow2: Permission denied" | Disks must be file-type in `terraform/vm` (AppArmor only allows a disk's backing chain for file-type disks); see §5 "Terraform details". Never set `security_driver = "none"` |
| `terraform plan` says a volume will be updated in place, but apply fails "Storage volumes cannot be updated" | Provider quirk: any volume change means recreate. For base images (`prevent_destroy`) do a deliberate one-time recreate when nothing uses them |

## A7. Safety rules (public repo, root-capable runner)

- **Never** add a `pull_request` or `pull_request_target` trigger to a job that runs on
  `[self-hosted, compute02, vm-builder]`. Only `vm-validate` runs on PRs, and only on
  GitHub's runners.
- Keep the `master-protection` ruleset: PR required, `vm-validate` required, no
  force-push or deletion.
- Keep both environments' required reviewer, and their `master`-only branch policy.
- Pin new actions to a full commit SHA with a `# vX.Y.Z` comment; allowed actions are
  limited to GitHub-owned ones.
- `gha-runner` has passwordless sudo on the host that runs db01. Anything merged to
  `master` can run as root there, so review workflow and playbook changes carefully.

---

# Part B: design, decisions and build history

The original plan as approved, kept as the record of *why* things are the way they are,
with the findings and test results from building it.

## 1. Decisions

| Area | Choice |
|---|---|
| Hypervisor | **compute02**, 192.168.2.6, SSH as `kwood`, sudo to root |
| IaC tool | **Terraform v1.17.1** with provider **`dmacvicar/libvirt` v0.9.9**, both pinned |
| Trigger | **GitOps:** one spec file per VM in `vms/`. Merging to `master` builds, updates or destroys VMs through GitHub Actions, and **every run waits for your approval** |
| CI runner | **Self-hosted GitHub runner on compute02**, registered to this repo only, running as a dedicated `gha-runner` user with **passwordless sudo** (your choice; see section 9) |
| Where Terraform runs | **On compute02**, against `qemu:///system`: as `gha-runner` from CI, or as `kwood` for the manual fallback. Both are in the `libvirt` group and a shared `vm-builder` group that owns `/opt/vm-builder` |
| Orchestration | **Ansible** syncs the Terraform code, renders the VM's settings, runs Terraform, waits for the VM, then configures it. It runs on the runner in CI, or on the Mac for the manual fallback |
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
| Tools present | `xorriso`. **Terraform 1.11.0 was already installed** (correcting this plan's first version, which said it wasn't), from a hand-made 2025 HashiCorp repo entry whose keyring lacks HashiCorp's current signing key. That broke `apt update`; step 1 replaced the entry and upgraded Terraform to 1.17.1. No existing Terraform state or projects were found on the host |
| Access | SSH key login works. kwood is in `libvirt` and `kvm`, and has **passwordless sudo** (confirmed 2026-11-06) |
| Security | AppArmor enforcing, with one `libvirt-<uuid>` profile per VM; `qemu.conf` at defaults apart from the standard `swtpm_user`/`swtpm_group` lines |

## 3. How a build works

### From GitHub Actions (the normal path)

```
PR adds/edits/deletes vms/web01.yml
  └─► vm-validate.yml   GitHub-hosted runner, no access to your network
        yamllint · spec schema check · terraform fmt -check · terraform validate
merge to master (or "Run workflow")
  └─► vm-gitops.yml     self-hosted runner on compute02 (labels: self-hosted, compute02, vm-builder)
        job "plan"           reconcile EVERYTHING, no approval needed (it changes nothing):
                               - vm-build.yml -e vm_phase=plan for every vms/<name>.yml
                               - vm-destroy.yml -e vm_phase=plan for every builder-managed VM
                                 that has no spec any more
                             readable plans go to the job summary; only VMs with real
                             changes are passed on
        job "apply-destroy"  ⏸ approval in environment vm-destroy → destroy (one VM at a time)
        job "apply-build"    ⏸ approval in environment vm-build → apply exactly the saved
                             plan, then the steps below (one VM at a time; runs after
                             destroys, which free RAM, and not at all if a destroy fails or
                             is rejected) → summary: name, IP, MAC
```

**Why reconcile everything, not just what the push changed?** GitHub keeps only one
pending run per concurrency group and cancels older pending ones. With "what this push
changed", a cancelled run would lose that push's VM changes for good. Reconciling every
spec on every run makes a cancelled run harmless, because the next run catches up.
Approvals are still only asked for VMs with actual changes. **Consequence:** any
builder-managed VM without a spec in `master` (e.g. one built by hand from an uncommitted
spec) is proposed for destruction. You'd see it in the plan and can reject it.

- **One run at a time:** the whole workflow is one concurrency group, and apply jobs run
  one VM at a time, so two runs can never touch Terraform at once.
- **Approval:** the run shows Terraform's real plan before you approve, so you're
  approving the exact change, not just a YAML diff. If the VM changes between plan and
  apply, the saved plan no longer applies and the job fails rather than doing something
  else.
- **Manual run:** "Run workflow" (`workflow_dispatch`) reconciles everything, e.g.
  after someone changed a VM by hand. It goes through the same approvals.
- **Plan/apply split in the playbooks:** `vm_phase=plan` saves the Terraform plan plus a
  readable copy in `/opt/vm-builder/plans/` and stops; `vm_phase=apply` applies exactly
  that saved plan. Terraform rejects it if the VM changed in between. `vm_phase=all`
  (the default) is the manual one-shot.

### The build steps (shared by CI and the manual fallback)

```
ansible-playbook playbooks/vm-build.yml -e @vms/web01.yml
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

A VM is one small YAML file in `vms/`, reviewed in a PR like any other change.
Anything you leave out takes the default shown. Defaults live in
`playbooks/vars/vm_defaults.yml`, which both plays of `vm-build.yml` load, so the new VM
sees them as well as the hypervisor. They were first put in `group_vars/hypervisors/`,
where the VM couldn't see them.

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
| `vm_disk_gib` | `20` | root disk; it grows the base image, which is about 3.5 GB. **Fixed after creation** (the provider can't resize volumes); use `vm_extra_disks` for more |
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
| `vm_allow_restart` | `false` | set `true` in the spec to let a vCPU/RAM change restart the VM |
| `vm_allow_replace` | `false` | set `true` to let a release or MAC change rebuild the VM; **its disk is lost** |

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
  example.yml              # documented example settings (ignored by the workflows)
  <name>.yml               # one file per VM: the VM exists while its file does
.github/workflows/
  vm-validate.yml          # PRs: static checks on GitHub-hosted runners only
  vm-gitops.yml            # master + manual: plan → approval → apply on compute02
ci/
  ansible.cfg              # CI config: inventory/ci.yml, no vault
  validate_vm_spec.py      # spec schema/range checks (used by both workflows and the playbook)
inventory/ci.yml           # compute02 as localhost (connection: local) for the runner
inventory/hosts.yml        # + hypervisors: compute02
inventory/group_vars/hypervisors/vars.yml   # pool, bridge, image URLs, versions, defaults
playbooks/
  hypervisor-prep.yml      # one-time: Terraform, /opt/vm-builder, base images, GitHub runner
  vm-build.yml             # build or update a VM from vms/<name>.yml
  vm-destroy.yml           # -e vm_name=web01 -e confirm=yes
  vm-list.yml              # VMs, state, IPs, resources; host capacity left
build-vm.md                # this plan, then the how-to
```

### Why base images have their own Terraform state

If each VM's state also owned the Ubuntu base image, `terraform destroy` of any one VM
would delete the base image that every other VM's disk depends on. So:

- `terraform/images` manages one base volume per release, in its own state.
  - Names include the image's build date, e.g. `ubuntu-26.04-20261016-base.qcow2`.
  - Refreshing an image adds a new volume; it never changes one that VMs are built on.
- **Images are pinned and verified.** `group_vars/hypervisors/vars.yml` pins each dated
  cloud-image URL and its SHA-256. Ansible downloads the image to
  `/opt/vm-builder/cache/` and checks the sum (the provider can't verify checksums),
  then Terraform loads the volume from that verified local file.
- VM disks are copy-on-write volumes backed by those images.
- Base volumes have `prevent_destroy`, so Terraform refuses to delete one.

### Terraform details

- **Code location:** `/opt/vm-builder` on compute02, owned by group `vm-builder` (setgid,
  group-writable), so `gha-runner` and `kwood` share the same code and state. Terraform's
  state lock stops them running at the same time. `terraform init` creates
  `.terraform/` and the lock file without group write, whatever the umask, so
  `hypervisor-prep.yml` fixes their permissions after each init. State lives in
  `/opt/vm-builder/vm/terraform.tfstate.d/<name>/` (one directory per workspace).
  `hypervisor-prep.yml` adds a nightly copy of all state to `/var/backups/vm-builder/`.
- **Provider:** `uri = "qemu:///system"`. Terraform runs locally on compute02, so
  there's no SSH tunnel inside Terraform.
- **Domain:** `q35` machine type; virtio disk and NIC; an `org.qemu.guest_agent.0`
  channel; a serial console, so `virsh console web01` works.
- **Disks are given to libvirt as file paths, not pool/volume names.** This matters
  for AppArmor: libvirt's `virt-aa-helper` only adds a disk's backing chain to the VM's
  profile when the disk is file-type. With volume-type disks, QEMU was silently denied
  the base image ("Permission denied", nothing logged). Base volumes are also created
  `0644`; that wasn't the cause, but it's right for shared, read-only images.
- **The provider's cloud-init ISOs live in `/opt/vm-builder/cloudinit-tmp/`**
  (`TMPDIR`), not `/tmp`. The provider records the ISO's path in state, and if the
  file disappears it plans to recreate the cloud-init disk, replace its volume and
  update the VM. `/tmp` is wiped on every reboot, so that would hit every VM; this was
  verified by hiding `test02`'s ISO. Its subdirectory also belonged to whichever user
  ran first, which broke the first CI build. The directory is created group-writable
  (`2775`, `vm-builder`). VMs built before this change (`test02`, `test03`) still point
  at `/tmp`.
- **cloud-init content changes are ignored after creation** (`ignore_changes`).
  cloud-init only reads its config on first boot, so rebuilding the config disk of an
  existing VM achieves nothing.
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
  because interface names differ between machine types, and sets
  **`dhcp-identifier: mac`**. Without it, systemd-networkd identifies the VM to the DHCP
  server by a DUID rather than its MAC: `test01` came back from a shutdown and start on a
  new IP (`.141` → `.119`). With it, `test03` kept its IP through the same sequence, and
  a MAC-based reservation on the router works.
- **First-build upgrade:** the full upgrade runs until the marker file
  `/var/lib/vm-builder/baseline-done` exists. That file is written only when the
  baseline completes, so a first run that fails part-way still gets upgraded next time.

## 6. Playbooks

| Playbook | Runs on | What it does |
|---|---|---|
| `hypervisor-prep.yml` | compute02 (sudo), run once from the Mac | adds the HashiCorp apt repo and installs `terraform=1.17.1-*` (held); creates group `vm-builder` and `/opt/vm-builder`, with a pinned Ansible venv for CI; runs `terraform -chdir=images apply`; sets up the state backup; checks `virt-host-validate`; **installs the GitHub runner** (see section 6a) |
| `vm-build.yml` | compute02, then the new VM | steps 1–8 of section 3; re-running it with changed settings updates the VM in place where libvirt allows (see below) |
| `vm-destroy.yml` | compute02 | needs `-e vm_name=<name> -e confirm=yes`. **Only destroys VMs the builder created** (it refuses any name without a builder workspace, so db01 and hand-made VMs are safe). Runs `terraform destroy` in that VM's workspace, removes the workspace, tfvars and saved plan, removes the VM's SSH host key from the machine running Ansible, checks the domain and its volumes are gone, and reports the RAM freed |
| `vm-list.yml` | compute02 | table of VMs with state, IP (from the agent), vCPU, RAM and disk, plus free host RAM and pool space |

**What a re-run can change:**

- **Applied with a restart of the VM: ANY in-place change** to it (vCPU, RAM,
  description, autostart, …). Provider 0.9.9 updates a running VM by stopping it,
  redefining it and starting it again. The stop is a clean guest shutdown, forced after
  30 s. This needs `vm_allow_restart: true` in the spec (or `-e vm_allow_restart=true`
  by hand). Learned on 2026-11-07, when a description-only change restarted `test01`:
  the original rule only covered vCPU/RAM, and the playbook's own restart step was
  redundant (so step 2's RAM test actually restarted `test01` twice). The step was
  removed. The 30 s limit could be raised with the provider's `update.shutdown.timeout`,
  but adding that setting is itself an in-place change, so it would restart every
  existing VM once. It's left at the default for now.
- **Disk size: not changeable.** Planned as "grown in place", but provider 0.9.9 can't update volumes, so `vm-build.yml` refuses any `vm_disk_gib` change at plan time (found while writing the how-to, 2026-11-07). Use `vm_extra_disks` for more space.
- **Replaces the VM:** a different Ubuntu release or a new MAC address. Terraform's plan
  shows this, and the run stops unless the spec sets `vm_allow_replace: true` (or
  `-e allow_replace=yes` by hand).

## 6a. The GitHub runner on compute02

| Item | Design |
|---|---|
| Software | `actions/runner` **v2.338.2** (2.338.0 when planned) in `/opt/actions-runner`, as a systemd service; SHA-256 checked against the value published in the release notes |
| User | `gha-runner`: system user with groups `libvirt`, `kvm` and `vm-builder`, **passwordless sudo** via `/etc/sudoers.d/gha-runner`, and its own ed25519 SSH key. Every VM gets **`vm_admin_authorized_keys`** (your Mac's public key, in `group_vars/hypervisors/vars.yml`) plus the keys of whoever runs the build, so CI-built VMs stay reachable from the Mac |
| Registration | **repo-level** to `woodez-ansible/infra-test-setup`; labels `self-hosted, linux, x64, compute02, vm-builder`. `hypervisor-prep.yml` fetches a short-lived registration token with your `gh` login; no long-lived token is stored |
| Workspace | `/opt/actions-runner/_work`; every job starts from a clean checkout |
| Ansible in CI | `/opt/vm-builder/venv` (ansible-core 2.21.4) with `community.general` in `/opt/vm-builder/collections`; `ANSIBLE_CONFIG=ci/ansible.cfg` with inventory `inventory/ci.yml` (compute02 with `ansible_connection: local`) and **no vault**, so no vault password is stored on the runner or in GitHub |
| PR checks | `vm-validate` on `ubuntu-latest`: `ci/validate_vm_spec.py` (ranges, choices, **file name = `vm_name`**, **unknown keys rejected**, so a typo can't silently fall back to a default), all YAML parses, `terraform fmt`/`validate` with a SHA-256-checked Terraform 1.17.1, and an Ansible syntax check |
| Removal | `hypervisor-prep.yml -e remove_runner=yes` unregisters the runner and removes the service |

### GitHub settings (approved 2026-11-06)

| Setting | Value | Why |
|---|---|---|
| Fork PR workflows | require approval for **all outside contributors** | was only first-time contributors |
| Allowed actions | **GitHub-owned only**; workflows pin `actions/checkout` to a full commit SHA | the workflows need nothing else |
| Ruleset on `master` | changes only through a PR; no force-push or deletion; `vm-validate` required once that workflow exists (step 5) | a required check that doesn't exist yet would block every merge |
| Environments | `vm-build` and `vm-destroy`: required reviewer **kevinwood75**; deployments from `master` only | your approval on every run |
| Workflow permissions | `contents: read` in every workflow; nothing pushes commits, so nothing can re-trigger itself | least privilege; no workflow loops |

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
8. **GitHub Actions** (step 5):
   - a PR with a bad spec (e.g. `vm_memory_mib: 99999`) fails `vm-validate`, and
     nothing runs on compute02
   - merging `vms/test01.yml` runs `plan`, then **waits for approval**; approving builds
     it, and the summary shows its IP
   - editing the spec, with `vm_allow_restart: true`, updates the VM after approval
   - deleting the spec waits in `vm-destroy`; approving destroys only `test01`
   - rejecting an approval leaves the VM untouched
   - a PR from a fork runs only `vm-validate` on GitHub's runners; the runner's job
     history shows nothing ran on compute02

### Step 2 results (2026-11-07)

| Test | Result |
|---|---|
| 2. build `test01` (1 vCPU / 1 GiB / 10 GiB, 26.04) | running, autostart on, guest-agent IP; SSH as kwood from the Mac; `sudo -n` OK; hostname `test01`; `vda` 10G; 26.04.1; Toronto time, synced; 0 pending upgrades |
| 3. re-run the same build | `changed=0` on compute02 and on the VM; Terraform apply skipped |
| 4. RAM 1024 → 2048 | **refused** without `vm_allow_restart`, with the VM untouched; with it, the VM restarted and now has 2 GiB (1962 MiB visible in the guest). (It actually restarted twice: once by the provider, once by a redundant playbook step that has since been removed.) |
| 5. 24.04 VM, and a second 26.04 VM | `test02` (24.04) and `test03` (26.04) built first time; `test01` and `test03` share `ubuntu-26.04-20261016-base.qcow2` |
| IP stability (`dhcp-identifier: mac`) | `test02` and `test03` kept their IPs through a reboot, and `test03` through a shutdown and start |

### Step 3 results (2026-11-07)

| Test | Result |
|---|---|
| 6. destroy `test01` | 4 resources destroyed (VM, root disk, cloud-init ISO, config disk); 0 `test01` volumes left; workspace removed; **both base images byte-identical** before and after; `test02` and `test03` stayed up throughout; ~3 GiB pool space returned; known_hosts entry for its IP removed |
| 7a. destroy without `confirm=yes` | refused |
| 7b. destroy unmanaged `node03` with `confirm=yes` | **refused**: "not a VM-builder VM … Nothing was changed" |
| 7c. build with the name of unmanaged `node03` | refused |
| 7d. build needing 16 GiB RAM | refused: "needs 16384 MiB more, but only 8549 MiB is available" |
| 7e. build named `Web_01` | refused: invalid spec |

For 7a–7e, every libvirt domain, domain state and pool volume was identical before and
after, and no Terraform workspace was created. `test02` and `test03` remain running for
step 5's GitHub Actions tests; `vms/test01.yml` was removed along with its VM.

### Step 5 results (2026-11-07): GitHub Actions end-to-end

| Test | Result |
|---|---|
| 1. no-change run | plan on `compute02`: "builds: none; destroys: none"; no approvals asked |
| 2. add `vms/test01.yml`, approve | built by CI after approval in `vm-build`; reachable from the Mac with the admin key (and the runner's key); sudo, 26.04, 10G, synced Toronto time |
| 5. reject | `apply-build` never ran (no runner, 0 steps); VM untouched (description unchanged, no restart) |
| 3. approve an update (manual run) | applied. Found that **any** in-place change restarts the VM, now gated by `vm_allow_restart` (PR #11) |
| 4. delete the spec, approve | `apply-destroy` in `vm-destroy`: 4 resources destroyed, 0 volumes, workspace gone; base images byte-identical; other VMs untouched |
| PRs | only `vm-validate` ever ran for PR branches; nothing reached the runner |

**Found and fixed during these runs** (each verified as `gha-runner` before its PR):

- **#7:** a plan summary file owned by `kwood` couldn't be chmod-ed by `gha-runner`. It's
  now written with temp file + rename.
- **#9:** the provider's cloud-init ISOs were in `/tmp`: a shared subdirectory owned by
  the first user, and wiped on reboot, after which every VM planned changes. They're now
  in persistent, group-writable `/opt/vm-builder/cloudinit-tmp`.
- **#11:** a description-only change restarted the VM, because provider 0.9.9 stops,
  redefines and starts for any update. Any update now needs `vm_allow_restart`, and the
  redundant playbook restart step was removed.
- The Mac's `known_hosts` kept a stale key for a reused DHCP IP. It was verified against
  the VM's own key and replaced; the procedure is in A6.

## 8. Delivery

Per your git rules, the work goes on a branch with a PR rather than straight onto
`master`, and each step gets a `working-hard.md` entry:

1. `hypervisor-prep.yml` + `terraform/images`, then run and verify (section 7, step 1)
2. `terraform/vm` + `vm-build.yml` + `vm-list.yml`, then verify (steps 2–5)
3. `vm-destroy.yml` + negative checks, then verify (steps 6–7)
4. Turn this plan into a how-to section in this file, with a reference for every setting
5. GitHub runner + `vm-validate.yml` + `vm-gitops.yml` + `ci/`, the environments, and
   the `vm-validate` required check, then verify (step 8)

All five steps are done (PRs #3–#5 for steps 1–3, #6–#12 for step 5 with its fixes, plus
this how-to for step 4).

The three repo settings that don't depend on the workflows (fork PR approval, allowed
actions, the base `master` ruleset) are applied now, ahead of the build.

## 9. Risks, assumptions and open items

- **The runner has passwordless sudo on the host that runs db01.** You chose this, so
  the workflow can also run host preparation. Any workflow change merged to `master`
  then runs as root on compute02. The safeguards:
  - every change to `master` goes through a reviewed PR
  - every run needs your approval
  - PR code never runs on the runner

  Once things are stable, consider narrowing `gha-runner`'s sudo rule to what VM
  builds need.
- **Public repo.** The runner never runs pull-request code; only `vm-validate` runs on
  PRs, on GitHub's own runners. Keep it that way: never add `pull_request` or
  `pull_request_target` triggers to a job with `runs-on: [self-hosted, …]`.
- **The approved plan is computed on the runner.** You approve what the runner shows,
  so the runner itself has to be trusted. That's another reason it only ever runs
  reviewed code from `master`.
- **sudo for kwood is passwordless** (fixed and confirmed 2026-11-06). The manual
  fallback only uses it for `hypervisor-prep.yml`.
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
- **Provider quirk: volumes can't be updated.** Changing an attribute of an existing
  volume shows as an in-place update in `terraform plan`, but the apply fails with
  "Storage volumes cannot be updated". For base volumes (`prevent_destroy`), that means
  a deliberate, one-time recreate when nothing uses them, as happened on 2026-11-07 to
  add `0644`.
- **AppArmor** confines each VM to its own files. The backing-chain problem this item
  warned about did happen. It was solved without weakening AppArmor, by giving libvirt
  file-type disks (see "Terraform details"). Never set `security_driver = "none"`.
- **Terraform's licence** (BSL) is fine for internal use. OpenTofu could replace it
  later with no code changes.
