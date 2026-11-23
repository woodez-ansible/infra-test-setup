# Salt master and salt-api on compute02

`compute02` (192.168.2.6) runs a **Salt master** and **salt-api**, installed and
configured by `playbooks/salt-master.yml`. Built and verified on 2026-11-23.

```bash
source .venv/bin/activate
ansible-playbook playbooks/salt-master.yml      # install / re-apply (idempotent)
```

## What's installed

| Piece | Setting |
|---|---|
| Version | Salt **3008.5**, the current LTS (3008: released 2026-05-27, active support until 2027-06). apt-pinned to `3008.*` and held |
| Packages | `salt-common`, `salt-master`, `salt-api` from Salt Project's signed repo (`packages.broadcom.com`); signing key checked by SHA-256 (fingerprint `1085 7FFD D3F9 1EAE 577A 21D6 64CB BC81 73D7 6B3F`) |
| Master | listens on **192.168.2.6** ports **4505** (publish) and **4506** (return); runs as user `salt` |
| Minion keys | **auto-accepted** (`auto_accept: True`): any machine that reaches 4505/4506 joins |
| States / pillar | `/srv/salt` / `/srv/pillar` (`base` environment) |
| salt-api | `rest_cherrypy` on **https://192.168.2.6:8000**, self-signed certificate (`/etc/salt/pki/api/`, CN `compute02`, SAN `IP:192.168.2.6`, 10 years) |
| API login | PAM user **`saltapi`** (system user, no shell); password in `playbooks/vars/salt-vault.yml` (Ansible Vault, key `vault_salt_api_password`) |
| API permissions | `saltapi` may run any execution module on any minion (`.*`) and call `@runner`, `@wheel`, `@jobs` |
| API clients enabled | `local`, `local_async`, `local_batch`, `runner`, `runner_async`, `wheel`, `wheel_async` |
| Config files | `/etc/salt/master.d/10-master.conf`, `20-api.conf` (from `templates/salt/`) |
| Firewall | none added (UFW stays off on the hypervisor; it can break libvirt networking) |

## Using the API

Log in once, then send the token with each request. Run from any machine on the LAN;
`-k` because the certificate is self-signed.

```bash
# Log in (prompts for the password; it isn't stored in your shell history)
read -rs -p "saltapi password: " PW; echo
TOKEN=$(printf '{"username":"saltapi","password":"%s","eauth":"pam"}' "$PW" |
  curl -sk https://192.168.2.6:8000/login -H 'Content-Type: application/json' -d @- |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["return"][0]["token"])')
unset PW

# Which minions are up?
curl -sk https://192.168.2.6:8000/ -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '[{"client":"runner","fun":"manage.status"}]'

# Run a command on minions
curl -sk https://192.168.2.6:8000/ -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '[{"client":"local","tgt":"*","fun":"test.ping"}]'
```

Tokens expire after 12 hours (Salt's default). On compute02 itself, the CLI works too:
`sudo salt '*' test.ping`, `sudo salt-key -L`, `sudo salt-run manage.status`.

To see the password (terminal only; don't paste it anywhere):
`ansible-vault view playbooks/vars/salt-vault.yml`.

## Windows minions

`playbooks/salt-minion-windows.yml` installs **salt-minion 3008.5** (same version as the
master) on the Windows VMs in the `windows_vms` inventory group (`win01`) over WinRM:

```bash
source .venv/bin/activate
ansible-playbook playbooks/salt-minion-windows.yml -l win01
```

1. downloads `Salt-Minion-3008.5-Py3-AMD64.msi` from Salt Project (SHA-256 checked) to
   `C:\Windows\Temp\salt`
2. installs it silently with `MASTER=192.168.2.6 MINION_ID=win01` (skipped if the
   `salt-minion` service already exists)
3. writes `C:\ProgramData\Salt Project\Salt\conf\minion.d\10-ansible.conf` (master + id),
   so a later change is applied by re-running; restarts the service only if it changed
4. on compute02: waits until the master lists `win01` as accepted (auto-accept), then
   `test.ping` and reads the minion's OS and Salt version

It needs the Windows admin password from `playbooks/vars/windows-vault.yml` (the playbook
loads it). Add another Windows VM by listing it under `windows_vms` in
`inventory/hosts.yml`. Then, on compute02: `sudo salt win01 test.ping`,
`sudo salt win01 cmd.run 'hostname'`.

## Operating it

| Task | How |
|---|---|
| Change config | edit `templates/salt/*.j2` (or the vars at the top of the playbook), re-run the playbook; it restarts only what changed |
| Upgrade within 3008 | set `salt_version` (e.g. `3008.6`) in the playbook, re-run. Minions should run the same version as the master |
| Move to a new LTS | change `salt_series` and `salt_version` together, after reading the release notes |
| Change the API password | `ansible-vault edit playbooks/vars/salt-vault.yml`, re-run |
| Accept keys by hand instead | set `salt_auto_accept: false`, re-run, then `sudo salt-key -a <minion-id>` per minion |
| Logs | `/var/log/salt/master`, `/var/log/salt/api` |
| Status | `systemctl status salt-master salt-api` |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| API returns **400 Bad Request**; `/var/log/salt/api` says "Client disabled: '…'" | Salt 3006+ disables API clients by default. Add the client to `netapi_enable_clients` in `templates/salt/api.conf.j2` |
| API login returns **401** with the right password | The `salt` user must be in the `shadow` group to check PAM passwords (the playbook adds it; `id salt` should list `shadow`), and `saltapi` must exist |
| Minion can't connect | It must reach 192.168.2.6:4505 and 4506 (`nc -z 192.168.2.6 4505`); the master listens only on that address |
| `salt-run manage.status` prints "No minions matched the target" | Normal while no minions are connected |

## Security notes

- **Auto-accept** means any machine on the LAN can register as a minion and receive
  states and pillar data. Don't put secrets in pillar without targeting it, or switch to
  manual acceptance.
- The API account can run anything as root on every minion. Keep its password in the
  vault only, and the API on the LAN: never forward 4505, 4506 or 8000 on the router
  (today it forwards only 80/443, to db01).
- `compute02` also runs the GitHub runner; anyone who can merge to `master` can already
  run code as root there. The Salt master adds no new path from GitHub.
