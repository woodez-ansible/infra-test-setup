# Kubernetes cluster plan (master / kube01 / kube02)

Status: **built 2026-10-09.** All phases ran, every phase re-runs with no changes, and the
Phase 8 smoke test passed. Gateway `public` is at 192.168.2.240.

Changes made while building:

- **`cri-tools` added in Phase 2.** kubeadm 1.37 no longer pulls in `crictl`, which the
  etcd backup script needs.
- **Calico pool defaults stated in the template.** `allowedUses`, `assignmentMode`,
  `disableBGPExport` and `disableNewAllocations` are now set explicitly. Without them,
  every run stripped them and the operator re-added them.
- **MetalLB's FRR-K8s turned off (`frrk8s.enabled: false`).** It's only used for BGP;
  this cluster uses L2.

Every phase below is a separate Ansible playbook, run one at a time, with a check at
the end before moving on.

## 1. Decisions

| Area | Choice |
|---|---|
| Kubernetes | **v1.37.1** (current stable), installed with **kubeadm** from `pkgs.k8s.io` |
| Topology | 1 control plane (`master`), 2 workers (`kube01`, `kube02`); master stays tainted (no app pods) |
| Container runtime | **containerd 2.2** + **runc 1.4** from Ubuntu 26.04 repos, systemd cgroup driver |
| Pod network (CNI) | **Calico** via the Tigera operator, VXLAN, BGP off |
| Load balancer IPs | **MetalLB**, L2 mode, pool **192.168.2.240–192.168.2.250** |
| Ingress | **Envoy Gateway** (Gateway API) |
| Storage | **local-path-provisioner**, default StorageClass (node-local, no replication) |
| Disk | Grow `/` from 19 GB to the full ~38 GB on every node |
| Package manager for add-ons | Helm 4 (v4.3.0) on `master`, driven by Ansible |

### Pinned versions (checked 2026-10-08)

| Component | Version | Compatibility with k8s 1.37 |
|---|---|---|
| Kubernetes | v1.37.1 | current stable |
| pause image | 3.10.2 | kubeadm v1.37.1 default |
| Calico | v3.33.0 | tested with 1.35–1.37 |
| MetalLB chart | 0.16.1 | requires >= 1.19 |
| Envoy Gateway | v1.9.2 | **tested with 1.33–1.36 only**; 1.37 support is so far only in Envoy Gateway's dev builds |
| local-path-provisioner | v0.0.37 | |
| Helm | v4.3.0 | Helm 3 is close to end of life; `kubernetes.core` 6.6 supports Helm 4 |
| kubeadm config API | `kubeadm.k8s.io/v1beta4` | the newer `v1` format is still marked unfinished in the 1.37 source |

## 2. What the nodes look like today

Checked over SSH (read-only) on 2026-10-08:

| | master | kube01 | kube02 |
|---|---|---|---|
| IP | 192.168.2.176 | 192.168.2.178 | 192.168.2.180 |
| OS / kernel | Ubuntu 26.04.1 / 7.0.0-38 | same | same |
| CPU / RAM | 2 / 5.2 GiB | 2 / 3.3 GiB | 2 / 3.3 GiB |
| Root LV / VG free | 19 GB / 19 GB free | 19 GB / 19 GB free | 19 GB / 19 GB free |
| Swap | 3.8 GiB `/swap.img` | same | same |

On all three:

- cgroup v2 is in use (required).
- `product_uuid` and MAC are unique (required by kubeadm).
- Passwordless sudo for `kwood` works.
- NTP is synced, timezone `Etc/UTC`.
- UFW is inactive and AppArmor is on.
- No container runtime or Kubernetes packages are installed.
- `br_netfilter` and `overlay` are not loaded, and `ip_forward=0`.
- `/etc/hosts` has no entries for the other nodes.

Resources meet kubeadm's minimum (2 CPU, 2 GB). The workers have about 2.3 GB left
for apps once Calico, MetalLB and Envoy Gateway are running, which is fine for
light workloads.

## 3. Network layout

| Range | Use |
|---|---|
| 192.168.2.0/24 | LAN (nodes, gateway 192.168.2.1) |
| 192.168.2.240–250 | MetalLB LoadBalancer IPs (pinged and ARP-checked: unused) |
| 10.244.0.0/16 | Pod network (Calico) |
| 10.96.0.0/12 | Service network (kubeadm default) |

Calico's default pod range is `192.168.0.0/16`, which **overlaps the LAN**. The plan
sets `10.244.0.0/16` explicitly in both kubeadm and Calico.

The API endpoint is `k8s-api:6443`. `k8s-api` is an `/etc/hosts` alias for
192.168.2.176. Using a name rather than the IP means a second control plane or a
VIP can be added later without re-issuing certificates.

## 4. Repo layout

New files only. Existing playbooks are not changed.

```
inventory/hosts.yml                        # + k8s_control_plane, k8s_workers, k8s_cluster groups
inventory/group_vars/k8s_cluster/vars.yml  # versions, CIDRs, MetalLB pool, chart versions
templates/k8s/kubeadm-config.yaml.j2       # InitConfiguration + ClusterConfiguration + KubeletConfiguration
templates/k8s/containerd-config.toml.j2
templates/k8s/calico-installation.yaml.j2
templates/k8s/metallb-pool.yaml.j2
templates/k8s/envoy-gateway.yaml.j2        # GatewayClass + shared Gateway
playbooks/k8s.yml                          # imports every phase in order
playbooks/k8s/00-prereqs.yml
playbooks/k8s/10-containerd.yml
playbooks/k8s/20-kube-packages.yml
playbooks/k8s/30-control-plane.yml
playbooks/k8s/40-calico.yml
playbooks/k8s/50-workers.yml
playbooks/k8s/60-addons.yml
playbooks/k8s/70-etcd-backup.yml
playbooks/k8s/90-smoke-test.yml
playbooks/k8s/99-reset.yml                 # destructive; requires -e confirm_reset=yes
requirements.yml                           # + kubernetes.core, ansible.posix
README.md                                  # + Kubernetes section
```

Inventory groups:

```yaml
k8s_control_plane: { hosts: { master: { ansible_host: 192.168.2.176 } } }
k8s_workers:
  hosts:
    kube01: { ansible_host: 192.168.2.178 }
    kube02: { ansible_host: 192.168.2.180 }
k8s_cluster: { children: { k8s_control_plane: {}, k8s_workers: {} } }
```

## 5. Phases

### Phase 0: OS prerequisites (`00-prereqs.yml`, all nodes)

1. **Grow the disk.** Extend `ubuntu-vg/ubuntu-lv` to 100% of the VG free space
   and resize the ext4 filesystem online (`community.general.lvol`, `resizefs: true`).
   No reboot is needed.
2. **Hostnames and names.** Confirm the hostnames `master`, `kube01` and `kube02`.
   Add all three plus `k8s-api` to `/etc/hosts` on every node.
3. **Swap off.** Run `swapoff -a`, remove the `/swap.img` line from `/etc/fstab`,
   then delete the file to free 3.8 GB.
4. **Kernel modules.** Load `overlay` and `br_netfilter` now, and persist them in
   `/etc/modules-load.d/k8s.conf`.
5. **sysctl.** Persist these in `/etc/sysctl.d/99-k8s.conf`:
   - `net.ipv4.ip_forward=1`
   - `net.bridge.bridge-nf-call-iptables=1`
   - `net.bridge.bridge-nf-call-ip6tables=1`
6. **Time.** Set the timezone to `America/Toronto` and use chrony with
   `ca.pool.ntp.org`, the same as db01. Certificates and etcd need agreeing clocks.
7. **Packages.** Install `apt-transport-https`, `ca-certificates`, `curl`, `gpg`,
   `conntrack`, `socat`, `ipset`, `ethtool` and `python3-kubernetes` (master only;
   needed by Ansible's `kubernetes.core` modules).
8. **Firewall.** Leave UFW **off** on these nodes. UFW's default FORWARD DROP
   breaks pod-to-pod traffic, and maintaining the ~10 port rules Kubernetes needs
   adds risk for little gain on a private LAN. Control traffic inside the cluster
   with Kubernetes NetworkPolicies instead (Calico enforces them).

**Check:**
- `df -h /` shows about 37 GB
- `swapon --show` is empty
- both modules are loaded and the sysctls are set
- every node resolves the other nodes and `k8s-api`

### Phase 1: container runtime (`10-containerd.yml`, all nodes)

1. Install `containerd` and `runc` from the Ubuntu repos.
2. Deploy `/etc/containerd/config.toml` (containerd 2.x config, version 3):
   - `SystemdCgroup = true` for the runc runtime
   - the sandbox (pause) image pinned to the version kubeadm v1.37.1 expects
     (`kubeadm config images list`)
3. Enable and restart containerd. Point `crictl` at the containerd socket in
   `/etc/crictl.yaml`.

**Check:** `crictl info` reports `SystemdCgroup: true` and the runtime is ready.

### Phase 2: Kubernetes packages (`20-kube-packages.yml`, all nodes)

1. Add the `https://pkgs.k8s.io/core:/stable:/v1.37/deb/` repo, with its key in
   `/etc/apt/keyrings/`.
2. Install `kubelet`, `kubeadm` and `kubectl` at `1.37.1-*`, plus `cri-tools` (`crictl`;
   kubeadm no longer pulls it in), then `apt-mark hold` the first three
   so a normal `apt upgrade` can't move the cluster version.
3. Enable kubelet. It will restart in a loop until kubeadm configures it, which is
   expected.

**Check:** `kubeadm version` reports v1.37.1 on all nodes.

### Phase 3: control plane (`30-control-plane.yml`, master)

1. Render `/etc/kubernetes/kubeadm-config.yaml`:
   - `kubernetesVersion: v1.37.1`
   - `controlPlaneEndpoint: k8s-api:6443`
   - `podSubnet: 10.244.0.0/16`, `serviceSubnet: 10.96.0.0/12`
   - API server certificate SANs: `k8s-api`, `master`, `192.168.2.176`
   - kubelet `cgroupDriver: systemd`
2. `kubeadm config images pull`, then `kubeadm init --config …`. This only runs if
   `/etc/kubernetes/admin.conf` doesn't exist, so re-runs are safe.
3. Copy `admin.conf` to `/home/kwood/.kube/config` on master, owned by kwood.
4. Fetch a copy to the Mac at `~/.kube/homelab.conf`. It is **not** stored in this
   repo because it holds cluster-admin credentials.

**Check:**
- `kubectl get nodes` shows `master` as `NotReady` (expected until Phase 4)
- `kubectl get pods -n kube-system` shows etcd, the API server, the controller
  manager and the scheduler `Running`

### Phase 4: pod network (`40-calico.yml`, run on master)

1. Apply the Tigera operator manifest, pinned to the latest Calico 3.x release that
   supports Kubernetes 1.37. The exact version is set in `vars.yml` at
   implementation time.
2. Apply an `Installation` resource: IP pool `10.244.0.0/16`,
   `encapsulation: VXLAN`, `bgp: Disabled`, `nodeAddressAutodetectionV4.cidrs:
   [192.168.2.0/24]`. VXLAN without BGP keeps Calico from competing with MetalLB
   and is the simplest mode on a flat LAN.

**Check:**
- `master` turns `Ready`
- the `calico-system` pods are `Running`
- CoreDNS pods are `Running`

### Phase 5: workers (`50-workers.yml`)

1. On master: `kubeadm token create --print-join-command`. The token is short-lived
   and never written to disk on the control machine.
2. On kube01 and kube02: run the join command, but only if
   `/etc/kubernetes/kubelet.conf` doesn't exist, so re-runs are safe.
3. Label both workers `node-role.kubernetes.io/worker=`.

**Check:** `kubectl get nodes -o wide` shows all 3 nodes `Ready` on v1.37.1, with
containerd 2.2.

### Phase 6: add-ons (`60-addons.yml`, run on master)

1. **Helm:** install Helm v4.3.0 on master from `get.helm.sh`, with its SHA-256 checksum verified.
2. **MetalLB:**
   - install the Helm chart (pinned) into `metallb-system`
   - create an `IPAddressPool` `lan-pool` for `192.168.2.240-192.168.2.250`
   - create an `L2Advertisement` for that pool
3. **Envoy Gateway:**
   - install the Helm chart (`oci://docker.io/envoyproxy/gateway-helm`, pinned) into
     `envoy-gateway-system`; it also installs the Gateway API CRDs
   - create a `GatewayClass` `envoy` and a shared `Gateway` `public` in namespace
     `gateway`, listening on HTTP 80
   - MetalLB gives that Gateway's Service an IP from the pool, probably `.240`
4. **local-path-provisioner:**
   - apply the pinned manifest; volumes live in `/opt/local-path-provisioner` on
     each node's root disk (now 37 GB)
   - mark `local-path` as the default StorageClass

**Check:**
- all add-on pods are `Running`
- `kubectl get gateway -n gateway public` shows `PROGRAMMED=True` and an address
  in .240–.250
- `kubectl get sc` shows `local-path (default)`

### Phase 7: etcd backups (`70-etcd-backup.yml`, master)

With a single control plane, losing master's disk means losing the cluster state.
This phase:

- installs a systemd timer that runs `etcdctl snapshot save` daily to
  `/var/backups/etcd/`
- keeps the last 7 snapshots
- also backs up `/etc/kubernetes/pki`

Copying these off the node (to the Mac or a NAS) is a later step.

**Check:** run the timer once by hand, and confirm a snapshot exists and passes
`etcdctl snapshot status`.

### Phase 8: smoke test (`90-smoke-test.yml`)

1. Creates namespace `smoke-test`, then deploys:
   - a 2-replica `nginx` Deployment, spread over both workers
   - a Service
   - an `HTTPRoute` on the `public` Gateway
   - a 1 Gi PVC mounted by one pod
2. From the Mac, `curl http://<gateway-ip>/` must return the nginx page. That proves
   MetalLB, Envoy Gateway, Services and Calico across nodes all work.
3. In-cluster DNS lookup of `kubernetes.default` must work.
4. The PVC must be `Bound`, and the pod must be able to write to and read back a file.
5. Deletes the namespace afterwards.

## 6. How it runs

```bash
source .venv/bin/activate
ansible-galaxy collection install -r requirements.yml -p ./collections
ansible-playbook playbooks/k8s/00-prereqs.yml       # then check, then the next phase
# ...
ansible-playbook playbooks/k8s.yml                  # later: whole thing, idempotent
```

The commands need no `-K`, because sudo is passwordless on these nodes. Ansible
also loads `vault.yml` for every host, so `.vault_pass` must be present, as it is today.

Use `kubectl` from the Mac with `KUBECONFIG=~/.kube/homelab.conf`. This needs
`kubectl` on the Mac (`brew install kubectl`), which is optional because every
check above can also run on master.

## 7. Day-2 notes

- **Upgrades:** one minor version at a time.
  1. Move the repo to the next minor (e.g. `v1.38`).
  2. Upgrade master: `kubeadm upgrade apply`.
  3. Upgrade each worker in turn: drain, upgrade, uncordon.
  4. Pin versions in `vars.yml` and add an `80-upgrade.yml` playbook when the time
     comes.
- **Certificates:** kubeadm certificates expire after 1 year. Any `kubeadm
  upgrade` renews them. Otherwise run `kubeadm certs renew all` before then.
- **Reset:** `99-reset.yml -e confirm_reset=yes` runs `kubeadm reset -f` on all
  nodes and removes CNI config, iptables rules and `~/.kube`. It does not touch
  the OS prerequisites from Phase 0.

## 8. Risks and assumptions

- **Ubuntu 26.04 is newer than Kubernetes' documented test matrix.** The
  `pkgs.k8s.io` packages are distro-agnostic, and containerd 2.2 and cgroup v2 are
  supported. Kernel 7.0 plus the nftables-based iptables could still turn up issues
  with kube-proxy or Calico. The Phase 4 and Phase 8 checks are where that would
  show. The fallback is kube-proxy `nftables` mode, which has been GA since 1.33.
- **Single control plane.** If master goes down, the API is down, but running apps
  keep running. The `k8s-api` alias keeps the door open to adding control planes
  later.
- **local-path storage is per node.** A pod's volume lives on one node. If that
  node dies, the data is gone. For replicated storage, Longhorn needs more RAM than
  the workers have.
- **MetalLB L2.** One node answers ARP for each LoadBalancer IP. If that node fails,
  another takes over within seconds. The range .240–.250 must stay out of the
  router's DHCP pool.
- **Versions.** Everything is pinned (see the table in section 1). Envoy Gateway
  v1.9.2 is one Kubernetes minor version past its tested range. Gateway API is a
  stable interface, and the Phase 8 smoke test would catch problems. If it breaks,
  move to the next Envoy Gateway patch release that lists 1.37.
- **Node IPs.** `/etc/hosts` maps each node's own name to `127.0.1.1` (Ubuntu
  default), so kubelet `--node-ip` and the API advertise address are set
  explicitly.
