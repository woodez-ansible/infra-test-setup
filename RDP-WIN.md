# Remote Desktop (RDP) into a Windows VM from a Mac

How to open a desktop session on a Windows VM built by the VM pipeline
(`vms/<name>.yml` with `vm_os: windows-2022`; see [build-vm.md](build-vm.md) A8).
The example is `win01` at 192.168.2.125.

## 1. Find the VM's IP

The `vm-gitops` **apply-build** job summary shows it:
`win01: VM win01 (Windows Server 2022) ready at 192.168.2.125 (MAC 52:54:00:3a:46:ea)`.

Or ask compute02:
```bash
ssh 192.168.2.6 'virsh -c qemu:///system domifaddr win01 --source agent'
```

## 2. Install the client (once)

Install **Windows App** from the Mac App Store. It's Microsoft's free RDP client
(formerly "Microsoft Remote Desktop").

## 3. Add the VM

In Windows App, click **+** → **Add PC**:

| Field | Value |
|---|---|
| PC name | the VM's IP, e.g. `192.168.2.125` |
| Credentials | "Ask when required", or add one: |
| – Username | `ansible`. If Windows rejects it, use the full local name, e.g. `WIN01\ansible` |
| – Password | the Windows admin password (step 5) |
| Friendly name | optional, e.g. `win01` |

## 4. Connect

Double-click the PC. A **certificate warning** appears because every VM uses its own
self-signed certificate; that's expected. Click **Continue**, or **Show certificate** →
"Always trust" so it doesn't ask again for this VM.

## 5. The password

All Windows VMs share one local admin, **`ansible`**, with the same password. It never
changes. To see it, run this from the repo root on the Mac (it needs `.vault_pass`):

```bash
source .venv/bin/activate
ansible-vault view playbooks/vars/windows-vault.yml
```

It's shown only in your terminal. Don't paste it into chats, tickets or files.

## Good to know

- **LAN only.** The VM's firewall accepts RDP only from the local subnet
  (192.168.2.x). From outside, connect to the LAN first (e.g. over a VPN).
- **Security:** Network Level Authentication is on, so you log in before a session
  starts. The account is a local administrator.
- **Keep the IP stable:** the VM gets its address by DHCP. Add a DHCP reservation on the
  router for its MAC (`52:54:00:3a:46:ea` for `win01`). The MAC is derived from the VM
  name, so it stays the same across rebuilds.
- **If RDP doesn't work**, use the VNC console through compute02 (works even when the
  VM's network is down): [build-vm.md](build-vm.md) A8.4.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Unable to connect" / times out | Check the VM is running and the IP is right (step 1), and that your Mac is on 192.168.2.x. Test the port: `nc -z -G 5 <ip> 3389` |
| "Your credentials did not work" | Use `WIN01\ansible` (the VM's name, in capitals, then `\ansible`), and check the password (step 5) |
| Certificate warning every time | Expected for self-signed certificates; choose "Always trust" in the certificate dialog |
| Connected, but a black screen | Wait a minute after a fresh build or reboot; if it persists, use the VNC console (build-vm.md A8.4) |
