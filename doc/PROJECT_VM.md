# A project-specific VM, without changing born2root

born2root stays general: `born2root.toml` holds the shipped defaults and
nothing in it is about one project. A VM for a particular project (a big
`/var` for Docker, more RAM, a fixed feature set) is a **profile file** passed
with `B2B_CONFIG`, next to `profiles/school.toml` and `profiles/server.toml`.
`born2root.toml` is never edited for it, so `git pull` and `git restore` leave
it alone.

## 1. Make the profile

```bash
cp born2root.toml profiles/myproject.toml
```

It has to be a whole file, not a fragment: `utils/b2b_config.py --check`
refuses a config without `system.root_password`, `system.luks_passphrase` and a
`[users.<login>]` table. Copying the file you already use carries your user
section with it. Then change only what the project needs, usually `[disk]`:

```toml
[disk]
swap_mb = 4096
volumes = [
  { name = "root",    mount = "/",        floor_mb = 8192, share = 0 },
  { name = "home",    mount = "/home",    floor_mb = 8192, share = 0 },
  { name = "opt",     mount = "/opt",     floor_mb = 2048, share = 0 },
  { name = "srv",     mount = "/srv",     floor_mb = 256,  share = 0 },
  { name = "tmp",     mount = "/tmp",     floor_mb = 2048, share = 0 },
  { name = "var-log", mount = "/var/log", floor_mb = 1024, share = 0 },
  { name = "var",     mount = "/var",     floor_mb = 2048, share = "rest" },
]
```

Every volume but `/var` has `share = 0`, so it gets exactly its floor and
`/var`, the `rest` volume, takes everything else. The shipped table gives
`/var` about 40% of the disk; this one gives it the disk minus 26 377 MB
(the floors, swap and boot), so 91 GB leaves `/var` 60.7 GiB mounted.

## 2. The knobs, and where each is read

| What | Knob | Notes |
| --- | --- | --- |
| Disk size, GB | `SIZE_B2B=` (or `VM_SIZE=`) | One of the two, not both |
| VM RAM, MB | `VM_RAM_MB=` | Also sizes swap, see below |
| Swap, MB | `[disk] swap_mb` | `"auto"` or a number |
| Layout | `[disk] volumes` | Floor, share and cap per volume |
| Install set | `PROFILE=`, `FEATURES=` | `make features` lists the names |
| Which file | `B2B_CONFIG=` | Relative to the repo root |

- **Swap.** With `ram_mb = "auto"` the ISO's swap is sized from 2048 MB
  whatever the host has, while the QEMU guest boots with a quarter of the
  host's RAM. Give `VM_RAM_MB` on the command line (swap becomes the RAM,
  clamped to 1-4 GB) and pin `swap_mb` so the layout cannot drift.
- **Feature names.** "devtools" is two rows: `devtools-apt` (always on) and
  `devtools-extra`, which needs `nodejs`. `FEATURES="+a +b"` adds to the
  profile; `PROFILE=minimal` starts from the base tier. Setting `FEATURES`
  also skips the interactive picker.

## 3. Check it before building

Neither command builds anything:

```bash
make partitions B2B_CONFIG=profiles/myproject.toml SIZE_B2B=91 VM_RAM_MB=8192
make features   B2B_CONFIG=profiles/myproject.toml SIZE_B2B=91 VM_RAM_MB=8192 \
  PROFILE=minimal FEATURES="+docker +claude-code +nodejs +devtools-extra"
```

The mounted size in `make partitions` is what `df` will show, about 7% under
the partman figure. Raise `SIZE_B2B` until `/var` is what the project needs,
and let `make features` say the install set fits.

## 4. What the disk can cost

The qcow2 is thin, but its worst case is its virtual size plus about 0.2 GiB of
metadata, plus about 1.7 GB of ISOs until `make slim`. `make all` refuses
before building when `utils/space_budget.sh` finds that will not fit; ask it
first with `bash utils/space_budget.sh --preflight <MB>`.

## 5. Build

```bash
make re BACKEND=qemu B2B_CONFIG=profiles/myproject.toml SIZE_B2B=91 \
  VM_RAM_MB=8192 PROFILE=minimal FEATURES="+docker +claude-code"
```

- `make re` deletes the existing VM first. Run `git pull --ff-only origin main`
  beforehand: a pull that changes the Makefile stops the run with "run the same
  command again", after the VM is already gone.
- A profile file that is untracked is not touched by `prepare`'s autostash,
  and neither is a clean `born2root.toml`.
- The host is only changed when the profile asks for it. Inception's host
  access (a local proxy, browser profiles, the desktop proxy, a launcher)
  is configured only when the profile includes `inception-data`, which
  `standard` and `full` do and `minimal` does not. `make host_access` opts in
  later and `make host_access_undo` removes every piece of it.
