# Rebuild baas at school from the profile

baas is the server VM `profiles/server.toml` describes: grobase following
the newest commit of its main branch, every engine, an hourly backup pull. It
stays off Tailscale, by decision (2026-11-04): the WAF is reached on the host's
8443, LAN and Wi-Fi included. This page rebuilds it on another seat from three
inputs and two commands. It also says what stays
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
and names the missing key (`setup/host/backup_pull.sh`). The three
`BAAS_*_PASSWORD`/`PASSPHRASE` keys are `make all`'s to mint on a new build, and
are the only way into a built disk, so they must come along when an existing
baas moves: `make secrets_push`, or a password manager. It must hold
nothing about Tailscale: `features.dc-netmesh = false` keeps the guest off it
whatever keys the file carries, and `make tailscale`, `make tailnet` and
`make funnel_up` refuse.

Data needs one of two sources, tried in this order:

1. A restic repository at `<backup_dest>/repo`, the newest thing there is.
2. The team's seeds in vault42, which needs nothing carried: `[dc] seeds_env`
   names the 42ctl credentials file (`~/.config/42ctl/secrets/42admin.env`) and
   `[dc] seeds_project` the project. `make all` loads them into an empty platform
   and keeps them in the guest at `/mnt/storage/seeds`, a bind mount of `/var`.
   They are as old as the last `make vault-seed` in grobase (their `MANIFEST.json`
   says when, and the run prints it).

The credentials file is the only input a new machine needs. 42ctl's own recovery
wants a code from your mailbox, so the file carries the sealed keystore
(`FT_KEYSTORE_B64`): run `make seeds_bundle` once where the keystore exists, and
keep the updated file. Without that line, `make set_seeds` needs a terminal.

`make set_seeds` runs that step alone. A platform that holds data is never
touched: `make set_seeds FORCE=1` replaces it, after a snapshot. The vault's
`JWT_SECRET`, `VAULT_ENC_KEY` and API keys come with the data, because the rows
were written under them. The engines keep this guest's own passwords.

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

make all B2B_CONFIG=profiles/server.toml        # the VM, and the seeds when no backup copy exists
make datacenter B2B_CONFIG=profiles/server.toml # the keys, a first backup, the proof
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

1. The restore, when `<backup_dest>/repo/snapshots` exists. It brings back
   the engines' dumps, grobase's `.env.secrets` and `.env.local`, the
   certificates and CA, vault42's admin env, the 42ctl files, and the volumes
   that have no dump. It then re-applies the profile's grobase keys. With no
   copy there, the seeds load instead (above).
2. The realtime token.
3. The tenant key and the graph_render key.
4. A first backup of the rebuilt guest.
5. `make verify_platform`.

Tailscale's steps run only for a profile that leaves `dc-netmesh` on.

Every step that fails prints how to rerun it alone.

## What stays manual, and why

| Step | Why the build does not do it | What to do |
| --- | --- | --- |
| A VM started from a terminal | Without linger (turning it on needs root) everything the login session started dies at logout, the VM included. `make autostart` therefore writes a crontab block instead of systemd units: cron's jobs outlive the logout. A VM already running from a terminal stays in the session until it is handed over | `make autostart_handover B2B_CONFIG=profiles/server.toml`: a graceful stop, then cron starts it again within a minute |
| Start at boot, stop at shutdown | `/dev/kvm` is yours only while you hold the seat's session (an ACL, not the kvm group), so cron starts the VM within a minute of your login, never at boot and never under TCG. At host shutdown a guard started by cron asks the guest for an ACPI power-off as soon as logind announces it (no delay lock: the seats' polkit refuses one), so the guest gets a head start, not a full graceful stop | Before a planned reboot, stop it first: `make qemu_stop B2B_CONFIG=profiles/server.toml GRACEFUL=1`. It then stays down until the host boots again |
| The guest's GitHub key | baas has `~/.ssh/id_ed25519` and clones grobase over ssh. The backup does not carry `~/.ssh`, and a rebuild clones over https (`setup/install/dc/install_grobase.sh`) | To push from the guest, add a key by hand |
| The guest password | The evaluation expects you to change the temporary one with `passwd` | After the change, targets that sudo in the guest need `VM_SUDO_PASS=` or `VM_SUDO_PASS_FILE=` (`setup/host/provision_vm.sh`). The hourly backup timer has neither, so its pulls fail until that is solved |

## Password expiry

`[policy.password] max_days = 30` reaches every account through
`chage -M 30` (`preseeds/b2b-setup.sh`). An expired password refuses a key
login that has no terminal: measured on trixie on 2026-11-04,
`Password change required but no TTY available`, exit 1, and with `ssh -tt`
the same login hangs on the prompt. Every `make` target reaches the guest
that way, so nothing survives the expiry on its own.

`make backup`, hourly, therefore runs `setup/host/rotate_password.sh --if-due`:
with 10 days left it mints new login and root passwords into the secrets file
and sets them in the guest. `make rotate_password` does it now. Only a profile
whose passwords are `secret:NAME` can rotate.

A guest powered off across the whole margin wakes up expired. `make backup`
then says so: `ssh -t` into it, give the old password (in the secrets file) and
a new one, put the new one in the secrets file, and run `make rotate_password`.

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
| The seat's RAM is at least `ram_mb = 10240` | `qemu_vm.sh` refuses a VM larger than the host's RAM. A 16 GB seat passes and leaves the host under 6 GB (estimated: its MemTotal minus 10240) | `free -m`. If it is short, lower `ram_mb` in the profile, which the autostart unit reads too |
| `/dev/kvm` is usable | Without it QEMU falls back to TCG emulation (`setup/host/qemu_vm.sh`); a running VirtualBox VM holds VT-x and makes QEMU refuse to start | `ls -l /dev/kvm`, `id -nG` |
| cron runs user crontabs | Without linger, `make autostart` keeps the VM up and pulls the backup from cron | `crontab -l` answers (an empty table is fine) |
| Mongo's application users after a restore | They were not checked after a restore. If the mongo image has no `mongodump`, `b2b-backup` fails the run naming Mongo | `make verify_platform` |

## What does not come back

- Redis, which is a cache. Observability data (Grafana, Loki, Prometheus) is
  not backed up either, and `mysql8-data` has no dump. These start empty. The
  backup set is `setup/install/dc/install_backup.sh`.
- The guest's `~/.ssh` private key (see the table above).
- Whatever reached baas after the last `make backup`.
- grobase's `FLY_TOKEN` has one copy, in the snapshot's `.env.local`. The
  host secrets file does not list it. `PAT_DOCKER`, `DOCKER_USER` and
  `GH_PAT` are in both. None of them belongs in the profile.
