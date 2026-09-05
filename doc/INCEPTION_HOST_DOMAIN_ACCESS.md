# Reaching `dlesieur.42.fr` from the host

**Status: solved, implemented in this repo, and verified end to end on
`c1r2s6.42madrid.com`.** No root, no SSH tunnel, no host `/etc/hosts` edit, and
nothing to re-run per session.

This replaces the earlier version of this file, which described the problem as
having no clean solution. It did have one — see [§3](#3-the-fix).

---

## 1. How to use it

```bash
make fresh        # everything: rebuild the VM, clone and build Inception,
                  # wire this host up, verify the whole chain
```

or the two halves separately:

```bash
make all          # builds the VM and wires up host access automatically
make inception    # clones Inception into the VM, builds it, verifies from the host
```

There is no manual step. A browser that was already open when the build ran
cannot see the new configuration — Firefox reads `user.js` only at profile
start, Chrome its proxy settings and certificate store only at launch — so
`setup/host/restart_browsers.sh` restarts them at the end, preserving their
sessions (Firefox via the same one-shot `resume_session_once` flag it uses for
its own updates, Chrome via `--restore-last-session`). It runs only once the
configuration is complete, so `make all` on its own never triggers it. Opt out
with `INCEPTION_NO_BROWSER_RESTART=1`.

Then, from the host:

| What                         | URL                                                |
| ---------------------------- | -------------------------------------------------- |
| WordPress, exact subject URL | `inception-browser` → **`https://dlesieur.42.fr`** |
| WordPress, in Firefox        | **`https://dlesieur.42.fr:8443`**                  |
| Bonus static site            | **`http://dlesieur.42.fr:8090`**                   |
| From a terminal              | `inception-curl -k https://dlesieur.42.fr/`        |

`inception-browser` is a generated launcher (`~/.local/bin/`), also installed as
a desktop entry named _Inception (dlesieur.42.fr)_.

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
`siteurl` and redirects anything else back to the canonical domain. A request
for `dlesieur.42.fr:8443` was redirected to `https://dlesieur.42.fr/` — port
443, where nothing on the host listens. That is why it kept looking like a
networking failure when the network was fine.

---

## 3. The fix

### 3a. Name resolution, in the browser

Resolution does not have to happen in the OS. Both browsers on these machines
can resolve one specific name themselves, and both mechanisms were verified
working here before anything was built on top of them:

| Browser           | Mechanism                       | Gives you                     |
| ----------------- | ------------------------------- | ----------------------------- |
| Firefox           | pref `network.dns.localDomains` | `https://dlesieur.42.fr:8443` |
| Chromium / Chrome | flag `--host-resolver-rules`    | `https://dlesieur.42.fr`      |
| Any browser       | local proxy + PAC (below)       | `https://dlesieur.42.fr`      |

Resolution alone is not enough for the **bare** URL, because it fixes the name
and not the port: Firefox then asks for `127.0.0.1:443` and gets _connection
refused_, since `ip_unprivileged_port_start` is 1024 and nothing running as this
user may bind 443. `setup/host/inception_proxy.py` closes that gap. A proxied
request carries the intended host _and port_ inside the request, so the proxy
sends `CONNECT dlesieur.42.fr:443` to the forwarded high port while the URL bar,
the SNI name and the `Host` header all still say the real domain on 443 — which
is why both the certificate and WordPress see exactly what they expect. It runs
as a `systemd --user` service, and the generated PAC routes _only_ this domain
through it (`DIRECT` for everything else, with `DIRECT` as a fallback so a
stopped proxy degrades instead of breaking the browser). Verified with a real
headless Firefox: a request to the bare URL arrived in the guest's nginx log
with a fully valid certificate and no error bypass.

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
port _inside the browser_, so the connection lands on `127.0.0.1:8443` while the
URL bar, the SNI name and the `Host` header all still say `dlesieur.42.fr`.

**Why not the `ssh -D` SOCKS tunnel.** It works, but `doc/SSH_VSCODE_FIX.md` in
this same repo documents that a SOCKS tunnel over this exact VirtualBox NAT
setup goes silently stale after ~15 minutes idle, and that SSH keepalives do not
fix it. Twelve hours went into proving that once. The browser mechanisms above
have no tunnel and no daemon: they are static configuration, so there is nothing
to keep alive and nothing to go stale.

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
(`Univers42/Inception`, commit _fix(wordpress): derive WP_HOME/WP_SITEURL from
the request Host_), so the plain `make inception` clone path is correct.

---

## 4. What changed in this repo

| File                                    | Change                                                                                                              |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `setup/host/inception_host_access.sh`   | **new** — NAT rules + Firefox pref + Chromium launcher + `inception-curl`. Idempotent, `--undo` supported.          |
| `setup/host/deploy_inception.sh`        | **new** — clones/uploads Inception into the VM over `ssh b2b`, builds it, verifies.                                 |
| `setup/host/verify_inception_access.sh` | **new** — proves the chain from the host, including a real headless browser load.                                   |
| `generate/orchestrate.sh`               | `inception-static` (8090) NAT rule added; stale host keys for `[127.0.0.1]:<ssh-port>` are now purged on every run. |
| `Makefile`                              | `host_access`, `host_access_undo`, `inception`, `verify_access`; `all` now runs `host_access`.                      |

The stale-host-key purge fixes a real papercut: every rebuild gives the VM a new
host key on the same `127.0.0.1:4242`, so a direct
`ssh -p 4242 dlesieur@127.0.0.1` (and scp, and VS Code) failed with
`REMOTE HOST IDENTIFICATION HAS CHANGED` until `ssh-keygen -R` was run by hand.
`ssh b2b` never hit it because its generated config sets
`UserKnownHostsFile /dev/null`. The new key is then recorded with `ssh-keyscan`,
because dropping the stale one on its own only trades the scary warning for a
confirmation prompt — or, under `BatchMode` (scp, VS Code, any script), an
outright _Host key verification failed_.

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
assertion that something _should_ work.

---

## 6. Notes and caveats

- **Firefox must be restarted after `make host_access`.** `user.js` is read only
  when a profile starts, so a Firefox that was already running when the pref was
  written never sees it and reports the domain as _Server Not Found_ — identical
  to having configured nothing. Quit it completely and reopen, or set
  `network.dns.localDomains` live in `about:config`. `make verify_access` fails
  when it detects this, because a scratch-profile test always passes and would
  otherwise hide it.
- **The certificate is not wrong, and neither browser warns any more.** The
  server certificate is issued in the guest by inception's `make certs`
  (`CN=<domain>`, SAN covering the domain, `localhost` and `127.0.0.1`) and
  verifies cleanly against the project's own CA. Firefox's full-page _"Someone
  pretending to be the site"_ warning means only that this CA is unknown to
  _that host_ — not that the certificate is bad. Firefox keeps its own store and
  ignores the system one, so `host_access` adds the CA to each profile's
  `cert9.db` with NSS's `certutil`. That tool lives in `libnss3-tools`, which
  needs root to install — but the package downloads and unpacks as an ordinary
  user (cached in `~/.cache/born2root/nss`) and links against the system
  `libnss3` Firefox already ships. Chromium instead pins the same CA by SPKI in
  its launcher, scoped to a dedicated profile directory, so normal browsing is
  untouched. A running Firefox needs a restart to pick up the new trust.
- **Chrome does not read Firefox's certificate store.** It uses NSS's shared
  database (`~/.pki/nssdb`, and `~/snap/chromium/*/.pki/nssdb` for the snap,
  which cannot see `~/.pki`). With the CA only in the Firefox profiles, Chrome
  reached the site and then refused it with `ERR_CERT_AUTHORITY_INVALID`.
  `host_access` populates every one of those stores.
- **Chrome refuses a `file://` PAC URL** that comes from the desktop proxy
  setting — it does not error, it silently falls back to no proxy, so the domain
  fails there with `DNS_PROBE_FINISHED_NXDOMAIN` while every other check passes.
  The proxy therefore serves the PAC itself over
  `http://127.0.0.1:<port>/inception.pac`, which Chrome accepts, and that is
  what the desktop setting points at. Firefox keeps a `file://` copy inside each
  profile, so its configuration does not depend on the proxy being up to be
  read.
- **Both browsers must be restarted** after `make host_access`: Firefox reads
  `user.js` only at profile start, and Chrome reads the proxy setting at launch.
- **Snap confinement.** Snap's `home` interface only grants access to
  _non-hidden_ paths in `$HOME`. A snap browser cannot use `~/.local/share` for
  a profile, so the launcher places it under `~/snap/<name>/common/` when the
  chosen browser is a snap. Test profiles must likewise not live in dot-dirs.
- **Guest sudo requires a TTY.** `deploy_inception.sh` uses `ssh -tt` for the
  one `sudo` it needs (the guest's `/etc/hosts` line); without it sudo refuses
  with _"you must have a tty"_ no matter what is piped at it.
- **Two different passwords.** `vm_pass.txt` holds the LUKS passphrase; the
  `dlesieur` account password used by `sudo` comes from `preseeds/preseed.cfg`.
  Both are throwaway lab credentials, but both sit in plaintext in a public
  repository — worth rotating if this VM is ever reachable from anywhere but
  this host.
- **The port-80 `lighttpd`** inside the VM is this repo's own bonus web server,
  not an Inception component. It is the reason Inception's compliance suite
  reports "port 80 answered". Harmless.
