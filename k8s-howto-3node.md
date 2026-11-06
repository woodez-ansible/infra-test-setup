# How to build, connect to and use the 3-node Kubernetes test cluster

This guide covers the cluster as it was built on 2026-10-09 from this repo. The design
and the reasons behind each choice are in [k8-plan.md](k8-plan.md). This guide is the
practical companion: how to build it, how to reach it, and how to run things on it.

## 1. What you get

| Node | IP | Role | CPU / RAM / disk |
|---|---|---|---|
| `master` | 192.168.2.176 | control plane (no app pods) | 2 / 5.2 GiB / 38 GB |
| `kube01` | 192.168.2.178 | worker | 2 / 3.3 GiB / 38 GB |
| `kube02` | 192.168.2.180 | worker | 2 / 3.3 GiB / 38 GB |

| Component | Version | What it does |
|---|---|---|
| Ubuntu | 26.04.1 LTS, kernel 7.0 | OS on all nodes |
| Kubernetes (kubeadm) | v1.37.1 | the cluster |
| containerd / runc | 2.2.2 / 1.4.0 | container runtime (systemd cgroups) |
| Calico | v3.33.0 | pod network: VXLAN, BGP off, pods in `10.244.0.0/16` |
| MetalLB | 0.16.1 (L2 mode) | gives `LoadBalancer` Services an IP from **192.168.2.240–250** |
| Envoy Gateway | v1.9.2 (Gateway API v1.6.1) | HTTP routing; shared Gateway `public` at **192.168.2.240** |
| local-path-provisioner | v0.0.37 | default StorageClass `local-path` |
| Helm | v4.3.0 | installed on `master` |

Other facts:

- Services use `10.96.0.0/12`. The API server is at `https://192.168.2.176:6443`
  (`k8s-api:6443` inside the cluster).
- Daily etcd and certificate backups go to `master:/var/backups/etcd/`.

## 2. Build it from scratch

### Prerequisites

- **Three VMs** running Ubuntu 26.04 with the IPs above.
  - `kwood` must be able to SSH in with a key and run `sudo` without a password.
  - Each VM needs a unique MAC address and `product_uuid`. Cloned VMs often share
    them, so check.
- **On the Mac,** this repo with its venv. The vault is loaded for every host, so
  `.vault_pass` must exist even though the cluster uses no secrets.
  ```bash
  cd ~/projects/coding-repos/infra-test-setup
  python3.13 -m venv .venv && source .venv/bin/activate
  pip install -r requirements.txt
  export SSL_CERT_FILE=$(python -m certifi)          # python.org builds lack a CA bundle
  ansible-galaxy collection install -r requirements.yml -p ./collections
  ```
- **192.168.2.240–250 must stay free.** Keep those addresses out of the router's
  DHCP pool.
- **First-time SSH.** If the nodes have never been reached from this Mac, accept
  their host keys once, e.g. `ssh kwood@192.168.2.176 true`. Do the same for .178
  and .180.

Settings live in [inventory/hosts.yml](inventory/hosts.yml) (nodes and groups) and
[inventory/group_vars/k8s_cluster/vars.yml](inventory/group_vars/k8s_cluster/vars.yml).
That file holds the versions, network ranges, MetalLB pool, timezone and backup
retention.

### Run the phases

Run them one at a time. Each phase ends with its own checks and stops on failure.
Each phase can also be re-run safely: a second run should report `changed=0`.
Phase 7 is the one exception, because it takes a fresh backup every run.

```bash
source .venv/bin/activate
ansible-playbook playbooks/k8s/00-prereqs.yml
ansible-playbook playbooks/k8s/10-containerd.yml
ansible-playbook playbooks/k8s/20-kube-packages.yml
ansible-playbook playbooks/k8s/30-control-plane.yml
ansible-playbook playbooks/k8s/40-calico.yml
ansible-playbook playbooks/k8s/50-workers.yml
ansible-playbook playbooks/k8s/60-addons.yml
ansible-playbook playbooks/k8s/70-etcd-backup.yml
ansible-playbook playbooks/k8s/90-smoke-test.yml
```

Once you trust it, `ansible-playbook playbooks/k8s.yml` runs all of them in order.

| Phase | What it does | Healthy result |
|---|---|---|
| **00 prereqs** | grows `/` to the whole disk; sets hostnames and `/etc/hosts`; turns swap off and deletes `/swap.img`; loads `overlay` and `br_netfilter`; sets the forwarding sysctls; sets America/Toronto time with chrony | report shows `root: 38G`, `swap: 0 active`, `modules: 2/2`, `ip_forward: 1`, and every node resolves the others and `k8s-api` |
| **10 containerd** | installs containerd and runc; writes `/etc/containerd/config.toml` (systemd cgroups, pause 3.10.2) and `/etc/crictl.yaml` | the assert on `SystemdCgroup = true` and the pause image passes |
| **20 kube-packages** | adds the `pkgs.k8s.io` v1.37 repo; installs and **holds** kubelet, kubeadm and kubectl 1.37.1; installs `cri-tools`; sets each node's IP in `/etc/default/kubelet` | `kubeadm version` is `v1.37.1` on every node |
| **30 control-plane** | runs `kubeadm init` on master (skipped if already done); installs `~/.kube/config` for kwood; writes `~/.kube/homelab.conf` on the Mac | 4 control plane pods `Running`; master `NotReady` (expected) |
| **40 calico** | Tigera operator plus the `Installation` | TigeraStatus `calico` is `Available`; master `Ready`; CoreDNS running |
| **50 workers** | creates a 30-minute join token; joins kube01 and kube02 (skipped if already joined); labels them `worker` | all 3 nodes `Ready` |
| **60 addons** | Helm, then MetalLB with its pool, Envoy Gateway with GatewayClass `envoy` and Gateway `public`, then local-path as the default StorageClass | `Gateway 'public' address: 192.168.2.240` |
| **70 etcd-backup** | backup script plus a daily systemd timer; runs one backup now | log ends `backup ok: /var/backups/etcd/etcd-<timestamp>.db` |
| **90 smoke-test** | deploys a test app across both workers, routed through the gateway, plus a PVC and a DNS check; fetches it from the Mac; then deletes it all | `Smoke test passed`, `Gateway http://192.168.2.240/ -> HTTP 200` |

To keep the smoke-test objects around for inspection, run
`ansible-playbook playbooks/k8s/90-smoke-test.yml -e keep_smoke_test=true`.
Remove them later with `kubectl delete ns smoke-test`.

## 3. Connect to the cluster

### From the Mac

Phase 3 writes the admin kubeconfig to `~/.kube/homelab.conf`. Its server is
`https://192.168.2.176:6443`, because `k8s-api` only resolves on the nodes. This file
is **cluster-admin**: keep it at mode `600`, never commit it, and don't share it.

```bash
brew upgrade kubectl            # needs v1.36-1.38 to match the v1.37 cluster
export KUBECONFIG=~/.kube/homelab.conf
kubectl get nodes -o wide
```

To keep it alongside other clusters, merge it instead of exporting:

```bash
KUBECONFIG=~/.kube/config:~/.kube/homelab.conf kubectl config view --flatten > /tmp/merged \
  && mv /tmp/merged ~/.kube/config && chmod 600 ~/.kube/config
kubectl config get-contexts                       # context: kubernetes-admin@homelab
kubectl config use-context kubernetes-admin@homelab
```

### On master

```bash
ssh kwood@192.168.2.176
kubectl get pods -A             # ~/.kube/config is already set up for kwood
sudo helm --kubeconfig /etc/kubernetes/admin.conf list -A
```

### Quick health check

```bash
kubectl get nodes                                   # 3 x Ready
kubectl get pods -A | grep -vE 'Running|Completed'  # only the header line
kubectl get tigerastatus                            # all AVAILABLE=True
kubectl -n gateway get gateway public               # PROGRAMMED=True, 192.168.2.240
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.2.240/   # 404 with no routes = healthy
```

## 4. Use the cluster

Apps run on `kube01` and `kube02` only; master keeps its control-plane taint. There
are three ways to reach an app from the LAN:

| Method | Use for | Address |
|---|---|---|
| `HTTPRoute` on the shared Gateway | HTTP apps (preferred) | `http://192.168.2.240/...`, split by hostname or path |
| `Service` of type `LoadBalancer` | non-HTTP, or an app that needs its own IP | next free IP from .241–.250 |
| `kubectl port-forward` | quick debugging from the Mac | `localhost:<port>` |

### Example: HTTP app behind the Gateway

This is the same pattern the smoke test proved end to end.

```yaml
# hello.yaml
apiVersion: v1
kind: Namespace
metadata: { name: hello }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: hello, namespace: hello }
spec:
  replicas: 2
  selector: { matchLabels: { app: hello } }
  template:
    metadata: { labels: { app: hello } }
    spec:
      containers:
        - name: web
          image: nginx:stable-alpine
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata: { name: hello, namespace: hello }
spec:
  selector: { app: hello }
  ports: [{ port: 80, targetPort: 80 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: hello, namespace: hello }
spec:
  parentRefs: [{ name: public, namespace: gateway }]
  hostnames: ["hello.lab"]          # route by Host header; omit to match every host
  rules:
    - backendRefs: [{ name: hello, port: 80 }]
```

```bash
kubectl apply -f hello.yaml
kubectl -n hello get httproute hello -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'  # True
curl -H 'Host: hello.lab' http://192.168.2.240/
```

To use the hostname in a browser, add `192.168.2.240 hello.lab` to the Mac's
`/etc/hosts`, or add a DNS record on the router.

**Several apps on one Gateway.** Give each `HTTPRoute` its own `hostnames:` entry,
or split by path:

```yaml
  rules:
    - matches: [{ path: { type: PathPrefix, value: /api } }]
      backendRefs: [{ name: api, port: 8080 }]
```

### Example: a Service with its own LAN IP

```yaml
apiVersion: v1
kind: Service
metadata: { name: hello-lb, namespace: hello }
spec:
  type: LoadBalancer
  selector: { app: hello }
  ports: [{ port: 80, targetPort: 80 }]
```

```bash
kubectl -n hello get svc hello-lb       # EXTERNAL-IP from 192.168.2.241-250
```

To pin a specific address, add the annotation `metallb.io/loadBalancerIPs:
192.168.2.245`. The pool has 11 addresses, and the Gateway already uses `.240`.

### Example: persistent storage

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: data, namespace: hello }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
  # storageClassName omitted -> local-path (the default)
```

Mount it in a pod with `volumes: [{ name: data, persistentVolumeClaim: { claimName:
data } }]`. Things to know about `local-path`:

- The PVC stays `Pending` until a pod uses it (`WaitForFirstConsumer`).
- The volume is a directory under `/opt/local-path-provisioner/` on **one** node,
  and the pod stays tied to that node.
- If that node is lost, the data is lost. There is no replication.
- Deleting the PVC deletes the data (reclaim policy `Delete`).
- The size request isn't enforced. All volumes share the node's root disk.

### Clean up an example

```bash
kubectl delete ns hello
```

### Installing charts

Helm is on master. To use it from the Mac, run `brew install helm`; it reads the
same `KUBECONFIG`.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install my-redis bitnami/redis -n redis --create-namespace
```

Keep requests modest: each worker has about 2.4 GiB free.

## 5. Day-to-day operations

### Backups

- `master:/var/backups/etcd/` holds `etcd-<timestamp>.db` and `pki-<timestamp>.tgz`.
  The newest 7 of each are kept. The timer runs daily around 02:30 Toronto time.
- Run a backup now with `ssh kwood@192.168.2.176 sudo systemctl start etcd-backup`.
- Check them with `sudo ls -l /var/backups/etcd/` and
  `systemctl list-timers etcd-backup.timer`.
- **Backups only live on master's own disk.** Copy them elsewhere regularly:
  ```bash
  ssh kwood@192.168.2.176 'sudo tar -C /var/backups -cf - etcd' > ~/k8s-backups-$(date +%F).tar
  ```

### Restore etcd from a snapshot (not yet tested on this cluster)

`etcdutl` isn't installed on the host. Download the matching etcd release first:

```bash
# on master, as root
ver=v3.7.0
curl -fsSL https://github.com/etcd-io/etcd/releases/download/$ver/etcd-$ver-linux-amd64.tar.gz | tar -xz -C /tmp
mkdir -p /etc/kubernetes/manifests.off
mv /etc/kubernetes/manifests/{kube-apiserver,etcd}.yaml /etc/kubernetes/manifests.off/   # stops both pods
mv /var/lib/etcd /var/lib/etcd.broken
/tmp/etcd-$ver-linux-amd64/etcdutl snapshot restore /var/backups/etcd/etcd-<timestamp>.db \
  --data-dir /var/lib/etcd --name master \
  --initial-cluster master=https://192.168.2.176:2380 \
  --initial-advertise-peer-urls https://192.168.2.176:2380
mv /etc/kubernetes/manifests.off/*.yaml /etc/kubernetes/manifests/
```

Then check that `kubectl get nodes` works. If master's disk was lost entirely,
first restore `/etc/kubernetes/pki` from the matching `pki-*.tgz`.

### Upgrades

- **Don't run `apt upgrade` expecting Kubernetes to move.** kubelet, kubeadm and
  kubectl are held, so OS updates are safe.
- **Moving to a new Kubernetes minor version:**
  1. Change `k8s_version` in `vars.yml`.
  2. On master: unhold kubeadm, upgrade it, then run `kubeadm upgrade apply`.
  3. For each worker in turn: `kubectl drain`, upgrade the packages, then
     `kubectl uncordon`.

  There's no playbook for this yet (`80-upgrade.yml` is a planned addition). Check
  Calico and Envoy Gateway support for the new version first.
- **Certificates:** they expire **2027-10-09**. Any `kubeadm upgrade` renews them.
  Otherwise, before then, run `sudo kubeadm certs renew all` on master, restart the
  control plane pods, and refresh `~/.kube/homelab.conf` by re-running Phase 3.

### Rebuild from scratch

```bash
ansible-playbook playbooks/k8s/99-reset.yml -e confirm_reset=yes   # destroys the cluster
ansible-playbook playbooks/k8s/30-control-plane.yml                # then 40, 50, 60, 70, 90
```

Reset leaves the Phase 0–2 OS setup in place, so a rebuild starts at Phase 3. It
does not delete `/var/backups/etcd` or `~/.kube/homelab.conf` on the Mac. Phase 3
overwrites the kubeconfig.

### Adding a worker

1. Prepare a VM the same way.
2. Add it under `k8s_workers` in `inventory/hosts.yml`.
3. Run Phases 00, 10, 20 and 50 with `--limit <newnode>,master`.

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Ansible: `Attempting to decrypt but no vault secrets found` | `.vault_pass` is missing; the vault is loaded for every host |
| `kubectl` from the Mac warns or misbehaves | client too old; `kubectl version` must be within one minor of v1.37 |
| `crictl: not found` | Phase 2 not run; `cri-tools` is installed separately from kubeadm |
| Node `NotReady` right after Phase 3 | expected; Calico (Phase 4) makes it Ready |
| Wrong node IP, e.g. 127.0.1.1 | Ubuntu maps the hostname to 127.0.1.1; `/etc/default/kubelet` must hold `--node-ip=<LAN IP>` (Phase 2) |
| `LoadBalancer` Service stuck at `<pending>` | pool exhausted (11 IPs), or MetalLB not running: `kubectl -n metallb-system get pods` |
| `http://192.168.2.240/` times out | MetalLB speaker or Envoy proxy down. `arp -n 192.168.2.240` on the Mac shows which node answers; check `kubectl -n envoy-gateway-system get pods` |
| `http://192.168.2.240/` returns 404 | no `HTTPRoute` matches: check `hostnames`, the `parentRefs`, and the route's `Accepted` condition |
| PVC stays `Pending` | normal until a pod uses it |
| `kubectl top` fails | metrics-server isn't installed (not chosen as an add-on) |

Useful commands:

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kubectl -n <ns> describe pod <pod>
kubectl -n <ns> logs <pod> [-c <container>] [--previous]
ssh kwood@<node> 'sudo crictl ps -a; sudo journalctl -u kubelet -n 50 --no-pager'
```

## 7. Reference

| Item | Location |
|---|---|
| Playbooks | `playbooks/k8s/00-…99-*.yml`, `playbooks/k8s.yml` (all) |
| Templates | `templates/k8s/` (kubeadm, containerd, Calico, MetalLB, Gateway, backup script) |
| Settings | `inventory/group_vars/k8s_cluster/vars.yml` |
| Admin kubeconfig | Mac: `~/.kube/homelab.conf`; master: `/etc/kubernetes/admin.conf`, `~kwood/.kube/config` |
| kubeadm config | master: `/etc/kubernetes/kubeadm-config.yaml` |
| Downloaded manifests | master: `/opt/k8s-manifests/` |
| Volumes | each worker: `/opt/local-path-provisioner/` |
| Backups | master: `/var/backups/etcd/` |
| Helm releases | `metallb` (metallb-system), `eg` (envoy-gateway-system) |
| Namespaces | `calico-system`, `tigera-operator`, `metallb-system`, `envoy-gateway-system`, `gateway`, `local-path-storage`, `kube-system` |

## 8. CI/CD with GitHub Actions (admin guide)

Developers deploy with GitHub Actions; their guide is [dev-howto-k8s.md](dev-howto-k8s.md).

- **Builds** run on GitHub-hosted runners and push to GHCR.
- **Deploy jobs** run on `runs-on: k8s-deploy`, a self-hosted runner scale set managed
  by Actions Runner Controller (ARC) in the cluster.
  - Runner pods start per job, at most 2 at a time, on kube01 or kube02.
  - They have no cluster access of their own.
  - Each app's deploy job uses a token limited to that app's namespace.

| Piece | Where |
|---|---|
| ARC controller | `arc-systems` (Helm release `arc`, chart 0.15.0) |
| Runner scale set `k8s-deploy` | `arc-runners` (Helm release `k8s-deploy`); org `woodez`, runner group `k8s-deploy` |
| GitHub App credentials | Secret `arc-runners/arc-github-app`, from the vault |
| GHCR pull token | Secret `ghcr-pull` in each app namespace, from the vault |
| Route permissions | ClusterRole `gateway-routes-edit` (aggregated into `edit`) |
| Playbooks | `playbooks/k8s/65-cicd.yml`, `app-onboard.yml`, `app-offboard.yml` |
| Developer templates | `examples/github-actions/` (workflow + manifests), `examples/demo-app/` |

### One-time setup

1. **Create the GitHub App.** Go to github.com → org **woodez** → Settings → Developer
   settings → GitHub Apps → **New GitHub App**.
   - **Name:** e.g. `woodez-k8s-arc`. **Homepage URL:** anything, e.g. the org URL.
   - **Webhook:** untick **Active**.
   - **Permissions:** Organization → **Self-hosted runners: Read and write**.
     Repository → Metadata: Read-only (default).
   - **Where can this app be installed:** Only on this account.
   - Create it, then note the **App ID** on its settings page.
   - **Private keys → Generate a private key**, which downloads a `.pem` file.
   - **Install App** → woodez → **All repositories**. The number at the end of the
     installation page URL (`.../installations/<id>`) is the **Installation ID**.
2. **Create the image-pull token.** github.com → your profile → Settings → Developer
   settings → Personal access tokens → **Tokens (classic)** → Generate.
   - Scope: **`read:packages` only**. Set an expiry and note when it needs renewing.
   - GHCR needs a classic token; fine-grained tokens don't work with it.
3. **Put the values in the vault:**
   ```bash
   cp inventory/group_vars/k8s_cluster/vault.yml.example inventory/group_vars/k8s_cluster/vault.yml
   # edit: App ID, Installation ID, paste the .pem contents (indented 2 spaces), the PAT
   ansible-vault encrypt inventory/group_vars/k8s_cluster/vault.yml   # same password as .vault_pass
   rm ~/Downloads/<app-name>.*.private-key.pem                        # once it's in the vault
   ```
4. **Give `gh` org-admin scope.** Runner groups need it: run
   `gh auth refresh -h github.com -s admin:org`.
5. **Org setting:** Settings → Actions → General → Fork pull request workflows →
   **Require approval for all outside collaborators**.
6. **Install ARC:** `ansible-playbook playbooks/k8s/65-cicd.yml`. The run ends by
   showing the listener pod `Ready`, which proves the App credentials work.

### Onboard / offboard an app

```bash
ansible-playbook playbooks/k8s/app-onboard.yml  -e app=myapp -e repo=woodez/myapp
ansible-playbook playbooks/k8s/app-onboard.yml  -e app=myapp -e repo=woodez/myapp -e rotate_token=true
ansible-playbook playbooks/k8s/app-offboard.yml -e app=myapp -e repo=woodez/myapp -e confirm=yes
```

Onboarding:

- creates namespace `myapp`, with a quota, default limits, `baseline` pod security and
  the GHCR pull secret
- creates the `deployer` ServiceAccount with `edit` on that namespace only
- sets the repo's `KUBE_TOKEN` and `KUBE_CA` secrets and its `KUBE_NAMESPACE`,
  `APP_NAME` and `APP_HOSTNAME` variables
- finishes by checking that the token **can** deploy in `myapp` and **can't** read
  `kube-system` or list nodes

It's safe to re-run. It always re-uploads the repo secrets, so it reports `changed`.
Offboarding deletes the namespace and everything in it.

### Verified end to end (2026-10-10)

A private demo repo, [`woodez/k8s-deploy-demo`](https://github.com/woodez/k8s-deploy-demo),
was onboarded and pushed. The run took about 75 seconds:

1. The build on `ubuntu-latest` pushed `ghcr.io/woodez/k8s-deploy-demo:<sha>`. GHCR
   refuses anonymous pulls of it, confirming it's private.
2. A runner pod `k8s-deploy-runner-*` started in `arc-runners`, ran the deploy job, and
   was deleted.
3. 2 pods, one on kube01 and one on kube02, pulled the private image with `ghcr-pull`.
4. The HTTPRoute was `Accepted`, and
   `curl -H 'Host: k8s-deploy-demo.apexkube.xyz' http://192.168.2.240/` answers from both
   pods.

Keep the repo as the reference app for developers.

### CI/CD troubleshooting

| Symptom | Fix |
|---|---|
| `65-cicd.yml` waits on the listener; `kubectl -n arc-runners get autoscalingrunnerset` shows `Pending` | read the controller log: `kubectl -n arc-systems logs deploy/arc-gha-rs-controller \| grep ERROR \| tail -3` |
| log: `failed to parse RSA private key from PEM` | the key in the vault is mangled; check the `-----BEGIN/END RSA PRIVATE KEY-----` lines have 5 dashes each and every key line is indented 2 spaces. Fix with `ansible-vault edit`, re-run `65-cicd.yml`, then `kubectl -n arc-systems rollout restart deploy/arc-gha-rs-controller`, because the controller backs off and doesn't retry promptly after a fix |
| log: `401`/`404` fetching an access token | wrong App ID or Installation ID, or the App isn't installed on woodez; check with `gh api orgs/woodez/installations --jq '.installations[] \| [.app_slug,.id]'` |
| `gh: This API operation needs the "admin:org" scope` | `gh auth refresh -h github.com -s admin:org` |
| deploy job stays `queued`, no pod in `arc-runners` | the listener isn't running (see the first row), the repo isn't allowed in runner group `k8s-deploy`, or `runs-on` isn't exactly `k8s-deploy` |
| pods `ImagePullBackOff` with `401` | GHCR PAT expired or lacks `read:packages`; update the vault and re-run `app-onboard.yml` |

### Notes

- **Private repos on the free plan.** GitHub environments aren't available for them,
  so the deploy credentials are repository secrets. GitHub never gives them to fork
  PRs, and the workflow only deploys from `main`, but anyone with write access to the
  repo could read them. That's acceptable here because a token only affects its own
  namespace.
- **Rotating the GitHub App key.** Generate a new key, update the vault, re-run
  `65-cicd.yml`, then delete the old key in the App settings.
- **Renewing the GHCR PAT.** Update the vault, then re-run `app-onboard.yml` for each
  app. Each run rewrites that app's `ghcr-pull` secret.
