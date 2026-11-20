# infra-test-setup

Ansible, Terraform and GitHub Actions automation for a homelab on `192.168.2.0/24`:

- a **VM build pipeline** on the KVM host `compute02` that builds Ubuntu and Windows
  Server VMs from spec files, GitOps-style (§2)
- a **3-node Kubernetes cluster** built in phases with kubeadm, with CI/CD for apps
  through GitHub Actions (§3)
- a **PostgreSQL / web host**, `db01` (§4)

This README is the design overview: how each system is built, why it's built that way,
and where to find the details. The step-by-step how-tos are linked from each section.

## 1. Overview

### 1.1 Hosts

| Host | IP | Role | Managed by |
|---|---|---|---|
| `compute02` | 192.168.2.6 | KVM/libvirt hypervisor; GitHub Actions self-hosted runner for the VM pipeline | `playbooks/hypervisor-prep.yml` |
| `master` | 192.168.2.176 | Kubernetes control plane | `playbooks/k8s.yml` |
| `kube01`, `kube02` | 192.168.2.178, .180 | Kubernetes workers | `playbooks/k8s.yml` |
| `db01` | 192.168.2.174 | PostgreSQL 17, nginx web app | `playbooks/postgres.yml`, `webapp.yml` |
| VMs built by the pipeline | DHCP on the LAN | anything you specify in `vms/` | `vm-gitops` workflow |

Inventory: `inventory/hosts.yml`. Shared settings: `inventory/group_vars/<group>/`.

### 1.2 Toolchain and pinned versions

| Tool | Version | Where |
|---|---|---|
| Python | 3.13, in `.venv/` | the Mac (control machine) |
| ansible-core | 2.21.4 | `requirements.txt` (also the compute02 runner's venv) |
| Collections | `community.general`, `community.postgresql`, `kubernetes.core`, `ansible.posix`, `ansible.windows` | `requirements.yml`, installed into `./collections` |
| pywinrm | 0.5.0 | `requirements.txt`; Ansible's WinRM client for Windows VMs |
| Terraform | 1.17.1, provider `dmacvicar/libvirt` 0.9.9 | compute02 only |
| Packer | 1.16.2, qemu plugin 1.1.8 | compute02 only (Windows golden image) |
| Kubernetes | 1.37.1 (kubeadm) | the cluster; all component versions in `inventory/group_vars/k8s_cluster/vars.yml` |

Every download (Ubuntu cloud images, the Windows ISO, VirtIO drivers, Helm, runners) is
pinned by version **and** checksum in group vars. Upgrades are deliberate edits.

### 1.3 Principles

- **Git is the source of truth.** `master` is protected (ruleset `master-protection`):
  changes go through PRs, the `vm-validate` check must pass, no force-pushes. PRs are
  merged with merge commits.
- **Nothing changes infrastructure without a human approval** in the VM pipeline:
  GitHub environments `vm-build` and `vm-destroy` require a reviewer and only accept
  `master`.
- **Secrets never live in git in plain text.** Ansible Vault for the Mac
  (`*/vault.yml`, password in `.vault_pass`, git-ignored); GitHub environment or repo
  secrets for CI. Tasks that touch them use `no_log`.
- **Idempotent by design.** Every playbook can be re-run; a clean re-run reports
  `changed=0`.
- **Least privilege in CI.** Workflows declare `permissions: contents: read` and use the
  built-in `GITHUB_TOKEN`; third-party actions are pinned to a commit SHA.

### 1.4 Repo map

```
README.md                 this design overview
build-vm.md               VM pipeline how-to (Part A) and design history (Part B)
build-windows-vm.md       Windows design, golden image, build log
k8s-howto-3node.md        Kubernetes build/operations guide (§8: CI/CD admin)
dev-howto-k8s.md          app developers: deploying to the cluster
inventory/                hosts.yml, ci.yml (runner), group_vars/
playbooks/                hypervisor-prep, vm-build, vm-destroy, vm-list, windows-image,
                          k8s.yml + k8s/00..99, app-onboard/offboard, postgres, webapp
playbooks/vars/           vm_defaults.yml, windows-vault.yml (encrypted)
terraform/images/         base images in the libvirt pool (one shared state)
terraform/vm/             one VM per Terraform workspace
packer/windows-2022/      Windows golden image: Packer template, answer file, scripts
templates/                vm-builder/, k8s/, chrony, nginx, ...
vms/                      VM specs: one file = one VM (example*.yml are references)
ci/                       validate_vm_spec.py, ansible.cfg for the runner
.github/workflows/        vm-validate.yml, vm-gitops.yml
examples/                 GitHub Actions + manifests for apps on Kubernetes
```

### 1.5 One-time setup on the Mac

```bash
python3.13 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export SSL_CERT_FILE=$(python -m certifi)   # python.org builds lack a CA bundle
ansible-galaxy collection install -r requirements.yml -p ./collections
# Vault password in .vault_pass (git-ignored); encrypted vars live in */vault.yml
```

---

## 2. VM build pipeline (Ubuntu and Windows)

**How-to:** [build-vm.md](build-vm.md) Part A (Ubuntu: A1–A7, Windows: A8).
**Design history and tests:** `build-vm.md` Part B, [build-windows-vm.md](build-windows-vm.md).

### 2.1 Goals and non-goals

**Goals**
- A VM is a reviewed YAML file: `vms/<name>.yml` on `master` *is* the VM. Adding,
  changing and deleting the file builds, updates and destroys it.
- A human approves every change before it's applied, after reading the exact plan.
- Ubuntu and Windows Server go through the same pipeline, the same guards and the same
  approvals.
- New VMs come up configured: timezone, NTP, access, packages/features. No manual steps
  inside the guest.
- Credentials never reach Terraform state, plan files, cloud-init data or logs.

**Non-goals**
- Multiple hypervisors, live migration, HA. One host, `compute02`.
- Resizing disks in place (the provider can't; see 2.9).
- Configuration management of the apps running *inside* the VMs.

### 2.2 Architecture

```
GitHub (woodez-ansible/infra-test-setup)
  PR ─────────────► vm-validate   GitHub-hosted runner; static checks; required to merge
  merge to master ► vm-gitops     self-hosted runner on compute02:
                      plan          every spec + every spec-less VM (no approval)
                      ⏸ approve     environment vm-build / vm-destroy (reviewer, master only)
                      apply         the exact saved plan, one VM at a time

compute02 (192.168.2.6)
  gha-runner ──► Ansible (/opt/vm-builder/venv) ──► Terraform ──► libvirt/KVM
  /opt/vm-builder/          vm/ (code + terraform.tfstate.d/<vm>/), images/, vms/*.tfvars.json,
                            plans/, cache/ (Ubuntu images), venv/, collections/, packer-plugins/
  /var/lib/libvirt/images/  pool "default": base images, VM disks, cloud-init ISOs, UEFI vars;
                            .vm-builder-cache/ + .vm-builder-packer/ (Windows image builds)
  br0 ──► LAN: VMs get DHCP addresses; MAC derived from the VM name
```

**Why a self-hosted runner on the hypervisor:** Terraform's libvirt provider and Packer's
KVM builder need local access to libvirt. Pull-request code never reaches it:
`vm-gitops` has **no `pull_request` trigger** and only runs code merged to `master`.
PRs are checked by `vm-validate` on GitHub's runners.

### 2.3 Components

| Component | What it does |
|---|---|
| `.github/workflows/vm-validate.yml` | On every PR and push: spec validator, YAML parse, `terraform fmt`/`validate`, Ansible syntax checks. Required check on `master` |
| `.github/workflows/vm-gitops.yml` | On push to `master` (VM-related paths) or manual run: reconcile all specs, then approval-gated destroy and build jobs |
| `ci/validate_vm_spec.py` | Spec schema: types, ranges, file name = `vm_name`, unknown keys are errors, OS-specific rules |
| `playbooks/vm-build.yml` | Preflight checks → tfvars → Terraform plan/apply → find the VM → baseline (Linux play over SSH, Windows play over WinRM) |
| `playbooks/vm-destroy.yml` | Destroys one builder-managed VM (refuses anything else) |
| `playbooks/vm-list.yml` | VMs, IPs, sizes, free RAM and pool space |
| `playbooks/hypervisor-prep.yml` | One-off host setup: libvirt, Terraform, Packer, runner, venvs, image downloads, base volumes, backups |
| `playbooks/windows-image.yml` | Builds the Windows golden image with Packer and loads it as a base volume |
| `terraform/images/` | Base volumes (Ubuntu releases, dated Windows builds), `prevent_destroy` |
| `terraform/vm/` | One VM: copy-on-write root disk, extra disks, cloud-init disk, domain |
| `playbooks/vars/vm_defaults.yml` | Defaults for every spec setting |

### 2.4 Lifecycle of a VM

1. **Spec.** `vms/<name>.yml` sets only what differs from `vm_defaults.yml`
   (references: `vms/example.yml`, `vms/example-windows.yml`).
2. **PR checks** (`vm-validate`, GitHub-hosted): the spec is validated statically. Typos
   in keys fail instead of silently falling back to defaults.
3. **Reconcile** (`vm-gitops` plan job, no approval). For **every** spec: `vm-build.yml
   -e vm_phase=plan`. For **every** Terraform workspace without a spec: a destroy plan.
   Readable plans go to the job summary; only VMs with real changes go on.
4. **Preflight** (inside the plan): name format, ranges, the base image exists, enough
   free RAM (keeping a 1 GiB reserve) and pool space, and the name isn't a VM the
   builder doesn't manage.
5. **Plan guards.** The plan is classified and refused unless the spec allows it:
   - an in-place change to a running domain **restarts** it → needs `vm_allow_restart: true`
   - a change that recreates the domain or root disk **loses the disk** → needs
     `vm_allow_replace: true`
   - a disk resize is **always refused** (the provider can't update volumes)
6. **Approval.** A reviewer reads the plan and approves `vm-build` or `vm-destroy`.
7. **Apply** (one VM at a time): `terraform apply` of the **exact saved plan**, then the
   plan file is deleted.
8. **Discovery.** The playbook asks the QEMU guest agent for the VM's IPv4 (ignoring
   link-local addresses), so no static IPs or DHCP scraping are needed.
9. **Baseline** (see 2.5), then the job summary shows the IP and MAC.

Each VM is its own **Terraform workspace** (`terraform.tfstate.d/<name>/`), so a failure
or change in one VM can't affect another, and "workspaces without a spec" is how the
reconcile finds VMs to destroy.

### 2.5 Ubuntu vs Windows

| | Ubuntu | Windows Server 2022 |
|---|---|---|
| Spec | `vm_ubuntu_release: "26.04"` (default) or `"24.04"` | `vm_os: windows-2022` |
| Base image | Canonical cloud image, pinned URL + SHA-256, downloaded by `hypervisor-prep.yml` | **golden image** built on compute02 by Packer (2.6) |
| Root disk | copy-on-write qcow2 on the base volume | same |
| Firmware | BIOS (default) or UEFI | UEFI (OVMF), per-VM NVRAM file in the pool; Hyper-V enlightenments |
| First boot | **cloud-init** (NoCloud disk): user, SSH keys, sudo, hostname, network (match by MAC, DHCP identifier = MAC) | **cloudbase-init** (same NoCloud disk): hostname, WinRM HTTPS listener (self-signed cert), user-data script limits 5986 to the LAN. **No credentials** in the disk |
| "Ready" signal | `cloud-init status --wait` over SSH | registry flag `UserDataPlugin = 1` read via the guest agent, then port 5986 |
| Access | SSH as `kwood` (keys from the Mac and the runner), passwordless sudo | WinRM HTTPS 5986 (NTLM) and RDP 3389 as local admin `ansible`; LAN only |
| Baseline | first-build `apt` upgrade, packages, timezone, chrony (`ca.pool.ntp.org`), guest agent | timezone (IANA → Windows ID map), w32time (`ca.pool.ntp.org`), RDP with NLA, firewall scoped to LAN, Windows features |
| Defaults | 2 vCPU, 2 GiB, 20 GiB | 2 vCPU, 4 GiB (min 2), 60 GiB (min 40); name ≤ 15 chars |
| Apply time | ~4.5 min (mostly the first `apt` upgrade) | ~95 s |
| Console | `virsh console <name>` (serial) | VNC on 127.0.0.1 via SSH tunnel |

### 2.6 Base images

- **One Terraform state for all base images** (`terraform/images`), separate from the
  per-VM workspaces, with `prevent_destroy`: a VM change can never delete a base image.
- **A VM stays on the base it was built from** (`ignore_changes = [backing_store]`). New
  images serve new VMs only; moving a VM to a new image is a rebuild.
- **Ubuntu:** add a new dated build (URL + SHA-256) to `ubuntu_images`, run
  `hypervisor-prep.yml`.
- **Windows golden image** (`playbooks/windows-image.yml`, ~70 min, monthly after Patch
  Tuesday), built by Packer on compute02 with KVM:
  1. unattended install from the pinned evaluation ISO (`autounattend.xml` rendered by
     Packer with the vault password; VirtIO drivers loaded during setup)
  2. VirtIO guest tools + QEMU guest agent installed **before** WinRM is enabled (the
     driver install resets the network)
  3. four Windows Update rounds with reboots in between (`check_registry` waits out
     update servicing); the last rounds normally find nothing left
  4. cloudbase-init installed and configured; cleanup (DISM, TRIM)
  5. build-only WinRM HTTP/Basic access and auto-logon removed, then **sysprep
     /generalize /oobe**
  6. offline checks with libguestfs (image generalized, cloudbase-init present), a
     `.complete` marker, then loaded as `windows-2022-<YYYYMMDD>-base.qcow2`

  Only builds with the marker become base images, so a failed build never does.

### 2.7 Secrets

| Secret | Where it lives | Who can use it |
|---|---|---|
| Vault password | `.vault_pass` on the Mac (git-ignored) | manual runs |
| Windows admin password (`ansible`, same on every Windows VM; **never rotated**, by decision) | golden image; `playbooks/vars/windows-vault.yml` (encrypted); GitHub environment secret `WINDOWS_ADMIN_PASSWORD` on `vm-build`/`vm-destroy` | the Windows image build (Mac), the Windows baseline (Mac or the **approved** apply step only) |
| SSH keys for Ubuntu VMs | public keys only, in group vars and cloud-init | n/a |

The Windows password is **never** passed to Terraform: it's baked into the golden image
and only used by Ansible to log in. Verified by grepping plans, state, tfvars, cloud-init
ISOs and logs (0 matches). The runner has no vault; it can't decrypt anything.

### 2.8 Safety guards (summary)

| Risk | Guard |
|---|---|
| Untrusted PR code runs on the root-capable runner | no `pull_request` trigger on self-hosted jobs; `vm-validate` runs on GitHub's runners |
| An unreviewed change is applied | environments with a required reviewer, `master` only; apply uses the saved, reviewed plan |
| A change silently restarts or rebuilds a VM | plan classification + `vm_allow_restart` / `vm_allow_replace` |
| A disk resize fails half-way | refused at plan time |
| Touching VMs the pipeline didn't create (e.g. `db01`, `node03`) | refused unless the name has a builder workspace |
| A deleted spec destroys a VM unnoticed | destroys need their own approval (`vm-destroy`) and show the full resource list |
| Losing a base image | separate state + `prevent_destroy` |
| Host out of capacity | RAM (1 GiB reserve) and pool-space preflight |
| Lost Terraform state | nightly backups to `/var/backups/vm-builder/` (14 days) |

### 2.9 Known limits and trade-offs

- **Disks are fixed after creation** (provider 0.9.9 can't update volumes). Add
  `vm_extra_disks` instead.
- **Any in-place domain change restarts the VM** (provider behaviour), hence the
  restart guard.
- **Baseline-only settings** (`vm_packages`, `vm_windows_features`, `vm_timezone`) don't
  produce a Terraform change, so GitOps doesn't apply them alone; use the manual
  fallback (`vm-build.yml -e @vms/<name>.yml`).
- **A VM built by hand without a spec gets a destroy queued** on the next run (by
  design: spec-less workspaces are destroyed). Commit the spec.
- **Windows:** evaluation licence (180 days per VM, lab use), one shared admin password,
  WinRM certificate validation off (per-VM self-signed certs; TLS + LAN-only port).

---

## 3. Kubernetes cluster build automation

**Build and operations guide:** [k8s-howto-3node.md](k8s-howto-3node.md).
**App developers:** [dev-howto-k8s.md](dev-howto-k8s.md).

### 3.1 Goals

- A reproducible kubeadm cluster on three existing Ubuntu hosts, built and rebuilt by
  Ansible, each phase verifying itself before the next starts.
- Apps reachable over HTTP by name (`http://<app>.apexkube.xyz`) and over LAN IPs, with
  persistent storage.
- Developers deploy with GitHub Actions without cluster-admin access; each app is
  confined to its own namespace.

### 3.2 Topology and components

| Node | IP | Role | CPU / RAM / disk |
|---|---|---|---|
| `master` | 192.168.2.176 | control plane (tainted; no app pods) | 2 / 5.2 GiB / 38 GB |
| `kube01` | 192.168.2.178 | worker | 2 / 3.3 GiB / 38 GB |
| `kube02` | 192.168.2.180 | worker | 2 / 3.3 GiB / 38 GB |

| Layer | Choice | Version |
|---|---|---|
| OS | Ubuntu 26.04 LTS | |
| Runtime | containerd + runc, systemd cgroups, pinned pause image | 2.2.2 / 1.4.0 |
| Kubernetes | kubeadm, kubelet, kubectl (apt, held) | 1.37.1 |
| Pod network | Calico via the Tigera operator: **VXLAN, BGP off**, pods `10.244.0.0/16` | v3.33.0 |
| Services | `10.96.0.0/12`; API `https://192.168.2.176:6443` (`k8s-api` alias in-cluster) | |
| Load balancer | MetalLB, L2 mode, pool **192.168.2.240–250** | 0.16.1 |
| Ingress | Envoy Gateway (Gateway API); shared Gateway `public` at **192.168.2.240** | v1.9.2 |
| Storage | local-path-provisioner, default StorageClass `local-path` | v0.0.37 |
| Packages | Helm on `master`, checksum-verified | v4.3.0 |

### 3.3 Build pipeline (phased playbooks)

`playbooks/k8s.yml` runs every phase in order; each phase is also runnable on its own,
is idempotent, and ends with checks that must pass.

| Phase | Playbook | What it does | Verifies |
|---|---|---|---|
| 0 | `k8s/00-prereqs.yml` | grow root LV, hostname, `/etc/hosts` (nodes + `k8s-api`), swap off, kernel modules + sysctls, base packages, Python k8s client, timezone, chrony | clock synchronised; swap, modules and sysctls verified |
| 1 | `k8s/10-containerd.yml` | containerd + runc, config (systemd cgroups, pinned pause image), crictl | effective config has the systemd driver and pause image |
| 2 | `k8s/20-kube-packages.yml` | Kubernetes apt repo, kubelet/kubeadm/kubectl pinned + held, kubelet node IP | kubeadm version |
| 3 | `k8s/30-control-plane.yml` | `kubeadm init` from a rendered config (skipped if already initialised); kubeconfig for `kwood` on master and `~/.kube/homelab.conf` on the Mac | API server up, control-plane pods running |
| 4 | `k8s/40-calico.yml` | Tigera operator + Calico Installation | Calico Available, node Ready, CoreDNS running |
| 5 | `k8s/50-workers.yml` | short-lived join token, `kubeadm join` (skipped if joined), worker labels | each worker Ready |
| 6 | `k8s/60-addons.yml` | Helm, MetalLB + address pool, Envoy Gateway + GatewayClass + Gateway `public`, local-path-provisioner | add-on deployments Available; Gateway `public` Programmed with its IP |
| 7 | `k8s/70-etcd-backup.yml` | daily systemd timer: etcd snapshot + PKI archive to `master:/var/backups/etcd/` (keep 7) | a backup runs now |
| 8 | `k8s/90-smoke-test.yml` | nginx spread over both workers, Service, HTTPRoute, PVC, DNS job | pods on 2 nodes, PVC Bound, HTTP through MetalLB + Envoy from the Mac; then deletes itself |
| – | `k8s/99-reset.yml -e confirm_reset=yes` | teardown: stop backups, `kubeadm reset`, remove CNI/Calico state, VXLAN interface, iptables rules | |

**Design notes**
- **Check-then-act:** init and join first look at the node's state, so re-running the
  whole pipeline on a built cluster changes nothing.
- **Versions in one place** (`group_vars/k8s_cluster/vars.yml`); upgrades are version
  edits plus a kubeadm upgrade (guide §5).
- **Networking:** VXLAN avoids needing BGP on the home router; MetalLB L2 answers ARP for
  the pool, so `LoadBalancer` Services get real LAN IPs; one shared Gateway gives every
  app a hostname under `apexkube.xyz`.

### 3.4 CI/CD for apps

```
git push (main) in an app repo
  └─► build job   GitHub-hosted runner: docker build ─► ghcr.io/woodez/<repo>:<commit-sha>
  └─► deploy job  runs-on: k8s-deploy (ARC runner pod in the cluster, fresh per job)
        kubectl apply k8s/*.yaml with a token valid only in namespace <app>
        kubectl rollout status
                                 http://<app>.apexkube.xyz ◄── Gateway 192.168.2.240 ◄── Pods
```

| Piece | Design |
|---|---|
| Runners | **Actions Runner Controller** (chart 0.15.0) with runner scale set `k8s-deploy` for org `woodez` (runner group `k8s-deploy`). Ephemeral pods, 0–2 at a time, on the workers. Authenticated with a **GitHub App** (credentials from the vault). Runner pods have no cluster permissions of their own |
| Builds | on GitHub-hosted runners; images pushed to GHCR with the workflow's `GITHUB_TOKEN` (`packages: write`), tagged with the commit SHA (roll back = redeploy an older commit) |
| Per-app isolation | `app-onboard.yml` creates namespace `<app>` with a ResourceQuota (1–2 CPU, 1–2 GiB, 10 pods), a LimitRange (defaults per container), a `deployer` ServiceAccount bound to the built-in `edit` role **in that namespace only** (plus HTTPRoutes via an aggregated ClusterRole), and a GHCR pull secret used by every pod |
| Credentials in the app repo | repo secrets `KUBE_TOKEN` (the deployer's token) and `KUBE_CA`; variables `APP_NAME`, `APP_HOSTNAME`, `KUBE_NAMESPACE`. Set by `app-onboard.yml` with `gh`; `-e rotate_token=true` issues a new token |
| Offboarding | `app-offboard.yml`: deletes the namespace and removes the repo secrets and variables |
| Templates | `examples/github-actions/` (workflow + Deployment/Service/HTTPRoute), `examples/demo-app/` |

```bash
ansible-playbook playbooks/k8s/65-cicd.yml                                         # runners (once)
ansible-playbook playbooks/k8s/app-onboard.yml -e app=myapp -e repo=woodez/myapp   # per app
```

### 3.5 Operating the cluster

- **kubectl from the Mac:** `export KUBECONFIG=~/.kube/homelab.conf` (written by phase 3;
  cluster-admin, not in the repo). On `master`, `kubectl` works as `kwood`.
- **Expose an app:** an `HTTPRoute` with `parentRefs: [{name: public, namespace: gateway}]`,
  or a `LoadBalancer` Service for its own LAN IP.
- **Backups:** `/var/backups/etcd/` on master; run one now with
  `sudo systemctl start etcd-backup`.
- **Rebuild from scratch:** `99-reset.yml -e confirm_reset=yes`, then `k8s.yml`.

---

## 4. db01: PostgreSQL and the web app

### PostgreSQL server (db01 / 192.168.2.174)

Ansible playbook that installs PostgreSQL 17 (PGDG) on Ubuntu 24.04, tunes it for
6 vCPU / 5.8 GB RAM, creates `appdb` owned by `appuser`, and allows remote
connections from `192.168.2.0/24` only (pg_hba + UFW).

It also sets the host timezone to `America/Toronto` (Postgres `timezone` /
`log_timezone` match) and replaces `systemd-timesyncd` with `chrony`, syncing to
`[0-3].ca.pool.ntp.org`. The run fails if the clock doesn't sync within ~60s.

#### One-time setup

```bash
python3.13 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export SSL_CERT_FILE=$(python -m certifi)   # python.org builds lack a CA bundle
ansible-galaxy collection install -r requirements.yml -p ./collections

cp inventory/group_vars/dbservers/vault.yml.example inventory/group_vars/dbservers/vault.yml
# edit vault.yml and set real passwords, then:
ansible-vault encrypt inventory/group_vars/dbservers/vault.yml
```

#### Run

```bash
source .venv/bin/activate
ansible db01 -m ping -K                                         # connectivity
ansible-playbook playbooks/postgres.yml -K --ask-vault-pass --check --diff   # dry run
ansible-playbook playbooks/postgres.yml -K --ask-vault-pass
```

`-K` prompts for kwood's sudo password. The dry run will report errors on tasks
that depend on packages not yet installed; that's expected on a fresh host.

#### Check time sync

```bash
ssh kwood@192.168.2.174 'timedatectl; chronyc tracking; chronyc sources -v'
```

`timedatectl` should show `Time zone: America/Toronto` and
`System clock synchronized: yes`.

#### Python tooling

`playbooks/python.yml` installs the system Python 3.12 with `python3-pip`,
`python3-venv` and `python3-virtualenv`, then smoke-tests a throwaway venv.

```bash
ansible-playbook playbooks/python.yml
```

Ubuntu 24.04 blocks `pip install` into the system Python (PEP 668), so install
packages inside a venv:

```bash
python3 -m venv ~/myenv && source ~/myenv/bin/activate && pip install <pkg>
```

#### Web app (https://www.apexkube.xyz)

`playbooks/webapp.yml` clones
[apexkube-company-web](https://github.com/woodez/apexkube-company-web), builds the
static site with its own venv as the `apexkube` system user, and serves it with
nginx over HTTPS on 443 using a Let's Encrypt certificate. Port 80 only answers
Let's Encrypt checks and redirects everything else to HTTPS.

**Prerequisites**

- Router forwards TCP **80** and **443** to `192.168.2.174`.
- `www.apexkube.xyz` resolves to your public IP (currently a CNAME to
  `mydev.dyndns.org`).
- Optional: at register.com, URL-forward `apexkube.xyz` to
  `https://www.apexkube.xyz` (the cert covers `www` only).

```bash
ansible-playbook playbooks/webapp.yml
```

The first run starts nginx on port 80, requests the certificate, then enables
443. The run checks HTTPS and the HTTP redirect from db01 itself. To test from
outside, use a phone on cellular: many routers can't reach their own public IP
from inside the LAN.

- **Update:** re-run the playbook. It pulls `master`; a new commit is built into
  `/var/www/apexkube/releases/<commit>/` and `current` is switched to it. No new
  commit means no rebuild. The newest 3 releases are kept.
- **Pin / roll back:** set `webapp_version` in
  `inventory/group_vars/webservers/vars.yml` to a commit SHA or tag and re-run.
- **Layout on the host:** source + venv in `/opt/apexkube-web`, served files in
  `/var/www/apexkube/current`, nginx config in `/etc/nginx/sites-available/apexkube`,
  logs in `/var/log/nginx/apexkube.*.log`, certificate in
  `/etc/letsencrypt/live/www.apexkube.xyz/`.
- **Renewal:** automatic via `certbot.timer`; a deploy hook reloads nginx.
  Test with `sudo certbot renew --dry-run` on db01.
- **HSTS:** once HTTPS has worked reliably for a while, set `webapp_hsts: true`
  and re-run. Browsers then refuse plain HTTP for the site for 2 years, so only
  turn it on when you're sure.

#### Connect

```bash
psql -h 192.168.2.174 -U appuser appdb
```

Change passwords later with `ansible-vault edit inventory/group_vars/dbservers/vault.yml`
and re-run the playbook. Tunables live in `inventory/group_vars/dbservers/vars.yml`.

