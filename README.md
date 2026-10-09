# infra-test-setup
Setting infra

## PostgreSQL server (db01 / 192.168.2.174)

Ansible playbook that installs PostgreSQL 17 (PGDG) on Ubuntu 24.04, tunes it for
6 vCPU / 5.8 GB RAM, creates `appdb` owned by `appuser`, and allows remote
connections from `192.168.2.0/24` only (pg_hba + UFW).

It also sets the host timezone to `America/Toronto` (Postgres `timezone` /
`log_timezone` match) and replaces `systemd-timesyncd` with `chrony`, syncing to
`[0-3].ca.pool.ntp.org`. The run fails if the clock doesn't sync within ~60s.

### One-time setup

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

### Run

```bash
source .venv/bin/activate
ansible db01 -m ping -K                                         # connectivity
ansible-playbook playbooks/postgres.yml -K --ask-vault-pass --check --diff   # dry run
ansible-playbook playbooks/postgres.yml -K --ask-vault-pass
```

`-K` prompts for kwood's sudo password. The dry run will report errors on tasks
that depend on packages not yet installed; that's expected on a fresh host.

### Check time sync

```bash
ssh kwood@192.168.2.174 'timedatectl; chronyc tracking; chronyc sources -v'
```

`timedatectl` should show `Time zone: America/Toronto` and
`System clock synchronized: yes`.

### Python tooling

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

### Web app (https://www.apexkube.xyz)

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

### Connect

```bash
psql -h 192.168.2.174 -U appuser appdb
```

Change passwords later with `ansible-vault edit inventory/group_vars/dbservers/vault.yml`
and re-run the playbook. Tunables live in `inventory/group_vars/dbservers/vars.yml`.

## Kubernetes cluster (master / kube01 / kube02)

kubeadm cluster: Kubernetes v1.37.1, containerd, Calico (VXLAN), MetalLB
(`192.168.2.240-250`), Envoy Gateway and local-path storage. The design and the
reasons for each choice are in [k8-plan.md](k8-plan.md). Versions are pinned in
`inventory/group_vars/k8s_cluster/vars.yml`.

```bash
source .venv/bin/activate
ansible-galaxy collection install -r requirements.yml -p ./collections

# Run one phase at a time; each ends with its own checks
ansible-playbook playbooks/k8s/00-prereqs.yml      # disk, swap, kernel, hosts, time
ansible-playbook playbooks/k8s/10-containerd.yml
ansible-playbook playbooks/k8s/20-kube-packages.yml
ansible-playbook playbooks/k8s/30-control-plane.yml
ansible-playbook playbooks/k8s/40-calico.yml
ansible-playbook playbooks/k8s/50-workers.yml
ansible-playbook playbooks/k8s/60-addons.yml
ansible-playbook playbooks/k8s/70-etcd-backup.yml
ansible-playbook playbooks/k8s/90-smoke-test.yml   # add -e keep_smoke_test=true to inspect

ansible-playbook playbooks/k8s.yml                 # or everything, in order (idempotent)
```

- **kubectl from the Mac:** `export KUBECONFIG=~/.kube/homelab.conf`. Phase 3
  writes this file; it holds cluster-admin credentials and is not in the repo.
  On `master`, `kubectl` works as kwood with no setup.
- **Expose an app:** create an `HTTPRoute` with `parentRefs: [{name: public,
  namespace: gateway}]`. The Gateway's IP is shown by
  `kubectl -n gateway get gateway public`.
- **Backups:** `/var/backups/etcd/` on master holds daily etcd snapshots and PKI
  archives, newest 7 of each. Run one now with `sudo systemctl start etcd-backup`.
- **Tear down:** `ansible-playbook playbooks/k8s/99-reset.yml -e confirm_reset=yes`.
