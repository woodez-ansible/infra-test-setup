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

### Connect

```bash
psql -h 192.168.2.174 -U appuser appdb
```

Change passwords later with `ansible-vault edit inventory/group_vars/dbservers/vault.yml`
and re-run the playbook. Tunables live in `inventory/group_vars/dbservers/vars.yml`.
