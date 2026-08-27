# Reaching `dlesieur.42.fr` from the host

**Status: solved, implemented in this repo, and verified end to end on
`c1r2s6.42madrid.com`.** No root, no SSH tunnel, no host `/etc/hosts` edit, and
nothing to re-run per session.

This replaces the earlier version of this file, which described the problem as
having no clean solution. It did have one — see [§3](#3-the-fix).

---

## 1. How to use it

```bash
make all          # builds the VM and wires up host access automatically
make inception    # clones Inception into the VM, builds it, verifies from the host
```

Then, from the host:

| What | URL |
|---|---|
| WordPress, exact subject URL | `inception-browser` → **`https://dlesieur.42.fr`** |
| WordPress, in Firefox | **`https://dlesieur.42.fr:8443`** |
| Bonus static site | **`http://dlesieur.42.fr:8090`** |
| From a terminal | `inception-curl -k https://dlesieur.42.fr/` |

`inception-browser` is a generated launcher (`~/.local/bin/`), also installed as
a desktop entry named *Inception (dlesieur.42.fr)*.

Other targets: `make host_access` (re-apply host wiring), `make verify_access`
(prove it works), `make host_access_undo` (put the host back exactly as it was).

---

## 2. What the problem actually was

Not ports, and not NGINX. Two separate things, and earlier sessions kept fixing
whichever one was not currently in the way.

**a) `dlesieur.42.fr` does not resolve on the host.** It is not a registered
domain. It exists only because something is told to map it to an IP — inside the
VM, the guest's own `/etc/hosts`, written by Inception's `make setup`. The host
was never told anything. On a 42 campus machine there is no root to add a
host-side `/etc/hosts` line, and `sudo` is not available.

**b) WordPress 301-redirects any `Host` it does not recognise.** Even once the
name resolves, WordPress compares the request's `Host` header against its stored
`siteurl` and redirects anything else back to the canonical domain. A request for
`dlesieur.42.fr:8443` was redirected to `https://dlesieur.42.fr/` — port 443,
where nothing on the host listens. That is why it kept looking like a networking
failure when the network was fine.

---

## 3. The fix

### 3a. Name resolution, in the browser

Resolution does not have to happen in the OS. Both browsers on these machines can
resolve one specific name themselves, and both mechanisms were verified working
here before anything was built on top of them:

| Browser | Mechanism | Gives you |
|---|---|---|
| Firefox | pref `network.dns.localDomains` | `https://dlesieur.42.fr:8443` |
| Chromium / Chrome | flag `--host-resolver-rules` | `https://dlesieur.42.fr` |

`setup/host/inception_host_access.sh` writes the Firefox pref into a delimited,
idempotent block in every profile's `user.js` (classic, snap and flatpak paths),
and generates the Chromium launcher. The traffic then rides the VirtualBox NAT
port-forward — the same path `ssh b2b` already uses.

**Why Chromium gets the bare URL and Firefox does not.**
`network.dns.localDomains` can only map a name to `127.0.0.1`; it cannot change
the port, so Firefox asks for `127.0.0.1:443`. Nothing may listen there:
`net.ipv4.ip_unprivileged_port_start` is `1024` on these machines, so no
unprivileged process — VirtualBox NAT included — can bind port 443, and changing
that sysctl needs root. Chromium's `MAP host:port host:port` syntax rewrites the
port *inside the browser*, so the connection lands on `127.0.0.1:8443` while the
URL bar, the SNI name and the `Host` header all still say `dlesieur.42.fr`.

**Why not the `ssh -D` SOCKS tunnel.** It works, but `doc/SSH_VSCODE_FIX.md` in
this same repo documents that a SOCKS tunnel over this exact VirtualBox NAT setup
goes silently stale after ~15 minutes idle, and that SSH keepalives do not fix
it. Twelve hours went into proving that once. The browser mechanisms above have
no tunnel and no daemon: they are static configuration, so there is nothing to
keep alive and nothing to go stale.

### 3b. The WordPress redirect

`srcs/requirements/wordpress/tools/entrypoint.sh` in the **inception** repo
derives `WP_HOME`/`WP_SITEURL` from `$_SERVER['HTTP_HOST']`, checked against a
whitelist (`dlesieur.42.fr`, `localhost`, `127.0.0.1` — the same three names in
the TLS certificate's SAN). The port is stripped for the whitelist test but kept
in the emitted URL, so `Host: dlesieur.42.fr:8443` yields
`WP_HOME=https://dlesieur.42.fr:8443` and every asset URL carries the port. Any
host outside the whitelist still falls back to the canonical domain, so this is
not an open redirect. WP-CLI has no HTTP context and always sees the canonical
domain, so `wp option get siteurl` is unchanged.

**This fix is required for the Firefox path.** Without it, Firefox is redirected
to port 443 and fails. Chromium is unaffected, because its `Host` header is the
bare canonical domain.

This was uncommitted for a while, which is why earlier attempts using a fresh
`git clone` kept failing in Firefox while working in Chromium. It is now pushed
(`Univers42/Inception`, commit *fix(wordpress): derive WP_HOME/WP_SITEURL from
the request Host*), so the plain `make inception` clone path is correct.

---

## 4. What changed in this repo

| File | Change |
|---|---|
| `setup/host/inception_host_access.sh` | **new** — NAT rules + Firefox pref + Chromium launcher + `inception-curl`. Idempotent, `--undo` supported. |
| `setup/host/deploy_inception.sh` | **new** — clones/uploads Inception into the VM over `ssh b2b`, builds it, verifies. |
| `setup/host/verify_inception_access.sh` | **new** — proves the chain from the host, including a real headless browser load. |
| `generate/orchestrate.sh` | `inception-static` (8090) NAT rule added; stale host keys for `[127.0.0.1]:<ssh-port>` are now purged on every run. |
| `Makefile` | `host_access`, `host_access_undo`, `inception`, `verify_access`; `all` now runs `host_access`. |

The stale-host-key purge fixes a real papercut: every rebuild gives the VM a new
host key on the same `127.0.0.1:4242`, so a direct
`ssh -p 4242 dlesieur@127.0.0.1` (and scp, and VS Code) failed with
`REMOTE HOST IDENTIFICATION HAS CHANGED` until `ssh-keygen -R` was run by hand.
`ssh b2b` never hit it because its generated config sets
`UserKnownHostsFile /dev/null`. The new key is then recorded with
`ssh-keyscan`, because dropping the stale one on its own only trades the scary
warning for a confirmation prompt — or, under `BatchMode` (scp, VS Code, any
script), an outright *Host key verification failed*.

---

## 5. Verifying

`make verify_access` checks, and fails loudly on any of:

1. the `https` and `inception-static` NAT rules exist;
2. `https://dlesieur.42.fr:<port>/` returns 200 over the forward;
3. the certificate presented for SNI `dlesieur.42.fr` has the matching CN;
4. the bonus static site returns 200;
5. **no redirect** away from `dlesieur.42.fr:<port>`, and page assets carry the
   port (this is the §3b regression test);
6. every Firefox profile carries the pref — and a headless Firefox really does
   resolve `dlesieur.42.fr` on its own, proven against a throwaway listener
   started on the host for the purpose;
7. a headless Chromium really loads the bare `https://dlesieur.42.fr/`.

Checks 6 and 7 drive actual browsers, so a pass is evidence rather than an
assertion that something *should* work.

---

## 6. Notes and caveats

- **Firefox must be restarted after `make host_access`.** `user.js` is read only
  when a profile starts, so a Firefox that was already running when the pref was
  written never sees it and reports the domain as *Server Not Found* — identical
  to having configured nothing. Quit it completely and reopen, or set
  `network.dns.localDomains` live in `about:config`. `make verify_access` fails
  when it detects this, because a scratch-profile test always passes and would
  otherwise hide it.
- **The certificate warning is expected in Firefox.** The CA is local and
  self-signed, as the subject intends, and the host does not trust it. Click
  through once per profile. The Chromium launcher does not warn: it pins that
  exact CA via `--ignore-certificate-errors-spki-list`, scoped to its own
  dedicated profile directory, so nothing about your normal browsing changes.
- **Snap confinement.** Snap's `home` interface only grants access to
  *non-hidden* paths in `$HOME`. A snap browser cannot use `~/.local/share` for
  a profile, so the launcher places it under `~/snap/<name>/common/` when the
  chosen browser is a snap. Test profiles must likewise not live in dot-dirs.
- **Guest sudo requires a TTY.** `deploy_inception.sh` uses `ssh -tt` for the one
  `sudo` it needs (the guest's `/etc/hosts` line); without it sudo refuses with
  *"you must have a tty"* no matter what is piped at it.
- **Two different passwords.** `vm_pass.txt` holds the LUKS passphrase; the
  `dlesieur` account password used by `sudo` comes from `preseeds/preseed.cfg`.
  Both are throwaway lab credentials, but both sit in plaintext in a public
  repository — worth rotating if this VM is ever reachable from anywhere but
  this host.
- **The port-80 `lighttpd`** inside the VM is this repo's own bonus web server,
  not an Inception component. It is the reason Inception's compliance suite
  reports "port 80 answered". Harmless.
