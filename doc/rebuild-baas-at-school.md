# Rebuild baas at school from the profile

baas is the server VM `profiles/server.toml` describes: grobase following
the newest commit of its main branch, every engine, the tailnet name
`dlesieur42-1`, Funnel, an hourly backup pull. This page rebuilds it on
another seat from three inputs and two commands. It also says what stays
manual, what does not come back, and which facts about a school seat
nobody has checked yet.

`make all` pulls `origin main` before it builds, so the rebuild runs what is
on main.

## The three inputs

| Input | Where it goes on the new seat | Check |
| --- | --- | --- |
| The profile | `profiles/server.toml`, in the clone | `B2B_CONFIG=profiles/server.toml bash utils/b2b_config.sh --check` |
| The secrets file | `$HOME/.config/born2root/b2b-secrets`, mode 600 (`[dc] secrets_file`) | `ls -l ~/.config/born2root/b2b-secrets` shows `-rw-------` |
| The restic repository | `<backup_dest>/repo` | `B2B_CONFIG=profiles/server.toml bash setup/host/backup_pull.sh --where` prints `<backup_dest>` |

The secrets file must hold `RESTIC_PASSWORD`: without it the restore stops
and names the missing key (`setup/host/backup_pull.sh`). It must hold
`TS_AUTHKEY` too, or `make datacenter` skips the tailnet login. An auth key
that is spent or expired logs nothing in: mint a new one at
<https://login.tailscale.com/admin/settings/keys> and replace that line.

`[dc] backup_dest` and `[vm] path` are lists. Each resolves to the first entry
that exists and is writable, else the first that can be created
(`utils/host_path.py`):

```text
vm.path      /sgoinfre/students/$USER/virtual_machines
backup_dest  /mnt/storage/b2b-backups/baas   /sgoinfre/students/$USER/b2b-backups/baas
```

## Before you leave the seat that runs baas

1. Take a last snapshot and pull it to the host:

   ```sh
   make backup B2B_CONFIG=profiles/server.toml
   ```

2. Copy `/mnt/storage/b2b-backups/baas/repo` and `~/.b2b_secrets/.env` to
   what you carry. Keep `RESTIC_PASSWORD` in a password manager as well:
   without it every snapshot is unreadable.
3. Stop the VM: `systemctl --user stop b2b-vm-baas.service`. Anything written
   to baas after the snapshot in step 1 is not in what you carry.
4. Remove the node `dlesieur42-1` at
   <https://login.tailscale.com/admin/machines>. The name is in grobase's
   `kong.yml`, its certificate and `REALTIME_ALLOWED_ORIGINS`. While the old
   node holds it, the new one gets a suffix and `make tailnet` stops
   (`setup/host/tailnet.sh`).

To keep the old baas running instead, clean its firewall: the profile no
longer forwards Inception's FTP or the old dev-server ports, and
`make firewall B2B_CONFIG=profiles/server.toml` deletes the rules the guest
still has for them. A fresh build does not need this, because first boot
applies the profile's list.

## At school

```sh
git clone git@github.com:Univers42/born2root.git --recursive
cd born2root

mkdir -p ~/.b2b_secrets && chmod 700 ~/.b2b_secrets
cp /path/you/carried/.env ~/.b2b_secrets/.env
chmod 600 ~/.b2b_secrets/.env

dest=$(B2B_CONFIG=profiles/server.toml bash setup/host/backup_pull.sh --where)
mkdir -p "$dest" && cp -a /path/you/carried/repo "$dest/repo"

make all B2B_CONFIG=profiles/server.toml
make datacenter B2B_CONFIG=profiles/server.toml
```

`make all` builds the VM. First boot installs dc-full and grobase at
`[dc] grobase_ref` (`main`: its newest commit, recorded in
`/etc/b2b/grobase.conf`; a full SHA there pins one instead; each
`make grobase` takes main's newest commit again), with the keys in
`[dc.grobase_env]` in `/opt/grobase/.env.local`. `make all` then ends with
`make autostart`. If
first boot is still running when the host side finishes, `make all` says so
and exits 0. In that case run `make all` again later, then go on.

`make datacenter` runs these steps, in order (`Makefile`, target
`datacenter`):

1. Tailscale login with `TS_AUTHKEY`.
2. The restore, when `<backup_dest>/repo/snapshots` exists. It brings back
   the engines' dumps, grobase's `.env.secrets` and `.env.local`, the
   certificates and CA, vault42's admin env, the 42ctl files, and the MinIO
   and DynamoDB volumes. It then re-applies the profile's grobase keys.
3. `make tailnet`: the node name, MagicDNS, the certificate,
   `tailscale serve`, and grobase's `make expose` for the new address.
4. The realtime token.
5. Funnel (`[dc] funnel = true`).
6. The tenant key and the graph_render key.
7. A first backup of the rebuilt guest.
8. `make verify_platform`.

Every step that fails prints how to rerun it alone.

## What stays manual, and why

| Step | Why the build does not do it | What to do |
| --- | --- | --- |
| Remove the old tailnet node | Only the admin console can do it | See step 4 above. If the new node already joined under a suffixed name, remove the old one, rename the new one to `dlesieur42-1` in the console, then rerun `make tailnet` |
| Tailnet console switches | MagicDNS, HTTPS certificates and key expiry live in the console. Without an API credential in the secrets file, `make tailnet` stops at each one, prints what to click and waits for Enter | Click, press Enter |
| Funnel approval | Two console switches, once per tailnet (`setup/host/funnel.sh`). `make funnel_up` prints the enable URL | Click it, then `make funnel_up B2B_CONFIG=profiles/server.toml`. Check the campus acceptable-use policy first |
| A VM started from a terminal | Without linger (turning it on needs root) everything the login session started dies at logout, the VM included. `make autostart` therefore writes a crontab block instead of systemd units: cron's jobs outlive the logout. A VM already running from a terminal stays in the session until it is handed over | `make autostart_handover B2B_CONFIG=profiles/server.toml`: a graceful stop, then cron starts it again within a minute |
| Start at boot, stop at shutdown | `/dev/kvm` is yours only while you hold the seat's session (an ACL, not the kvm group), so cron starts the VM within a minute of your login, never at boot and never under TCG. Nothing runs at host shutdown without root, so a reboot cuts the guest's power | Stop it first: `make qemu_stop B2B_CONFIG=profiles/server.toml GRACEFUL=1`. It then stays down until the host boots again |
| The guest's GitHub key | baas has `~/.ssh/id_ed25519` and clones grobase over ssh. The backup does not carry `~/.ssh`, and a rebuild clones over https (`setup/install/dc/install_grobase.sh`) | To push from the guest, add a key by hand |
| The guest password | The evaluation expects you to change the temporary one with `passwd` | After the change, targets that sudo in the guest need `VM_SUDO_PASS=` or `VM_SUDO_PASS_FILE=` (`setup/host/provision_vm.sh`). The hourly backup timer has neither, so its pulls fail until that is solved |

## Password expiry

`[policy.password] max_days = 30` reaches every account through
`chage -M 30` (`preseeds/b2b-setup.sh`). On 2026-10-13 the live baas login's
password expired on 2026-11-09 (`chage -l dlesieur`, from the drift audit). A
rebuilt guest's password expires 30 days after it was last set. Nobody has
tested what an expired password does to the key-based ssh that every `make`
target uses. Change the password before it expires.

## Not verified on a school seat

One 42 Madrid seat was checked on 2026-10-14 before a rebuild:
`/sgoinfre` had 2675 GB free and the preflight passed, `/mnt/storage`
was absent, the seat had 31 GB of RAM and 16 CPUs, `/dev/kvm` was
writable through a per-login ACL (not the kvm group), the systemd user
manager answered, linger was off, and host ports 4242, 8082 and 8443
were free. Seats differ, so run the checks again on yours.

| Fact | Why it matters | Check before `make all` |
| --- | --- | --- |
| `/sgoinfre/students/$USER` is writable and has room | It is where `[vm] path` resolves; home has under 1 GB free and `/goinfre` is wiped. The build refuses to start when the filesystem cannot hold the 120 GB disk plus the 40 GB IDE disk (`utils/space_budget.sh --preflight`). A per-login sgoinfre quota, if any, is not visible to `df` | `df -h /sgoinfre` |
| `/mnt/storage` is absent | If it exists and is writable, it wins both lists | `ls -d /mnt/storage` |
| The seat's RAM is at least `ram_mb = 14336` | `qemu_vm.sh` refuses a VM larger than the host's RAM. A 16 GB seat passes and leaves the host under 2 GB (estimated: its MemTotal minus 14336) | `free -m`. If it is short, lower `ram_mb` in the profile, which the autostart unit reads too |
| `/dev/kvm` is usable | Without it QEMU falls back to TCG emulation (`setup/host/qemu_vm.sh`); a running VirtualBox VM holds VT-x and makes QEMU refuse to start | `ls -l /dev/kvm`, `id -nG` |
| cron runs user crontabs | Without linger, `make autostart` keeps the VM up and pulls the backup from cron | `crontab -l` answers (an empty table is fine) |
| `tailscale set --hostname` takes a freed name back | It decides whether removing the old node is enough, or the console rename is also needed | Watch the name `make tailnet` reports |
| The campus network lets Tailscale and Funnel through | The private and public planes depend on it | `make tailnet_status`, `make funnel_status` |
| Mongo's application users after a restore | They were not checked after a restore. If the mongo image has no `mongodump`, `b2b-backup` prints that it skipped Mongo | `make verify_platform` |

## What does not come back

- The engines with no dump in the backup set: MariaDB, CockroachDB, and the
  sqlite and functions volumes. Observability data (Grafana, Loki,
  Prometheus) is not backed up either. These start empty. The live volume
  list is from the 2026-10-13 audit. The backup set is
  `setup/install/dc/install_backup.sh`.
- The guest's `~/.ssh` private key (see the table above).
- Whatever reached baas after the last `make backup`.
- grobase's `FLY_TOKEN` has one copy, in the snapshot's `.env.local`. The
  host secrets file does not list it. `PAT_DOCKER`, `DOCKER_USER` and
  `GH_PAT` are in both. None of them belongs in the profile.
