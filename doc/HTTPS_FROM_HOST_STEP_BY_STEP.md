# `https://dlesieur.42.fr` from the host, without the warning — step by step

> **Written for a beginner.** Every step says *what to type*, *what you should
> see*, and *what you are learning*. Every command was run on this machine
> (`c1r2s6`, 2026-09-03) against the VM as it is right now, so the expected
> outputs are real outputs, not guesses. Where a step could **not** be verified
> here (the two GUI import dialogs), it says so.

---

## 0. Read this first: what the Firefox warning actually means

Firefox shows:

> **Warning: Potential Security Risk Ahead**
> Firefox detected a potential security threat and did not continue to
> `dlesieur.42.fr`. Someone pretending to be the site could try to steal
> things like credit card info, passwords, or emails.

Click *Advanced* and the technical line underneath is `SEC_ERROR_UNKNOWN_ISSUER`.
That single line is the whole story:

- The site **is** encrypted. The TLS handshake succeeded, TLS 1.3 was negotiated,
  and the bytes between the browser and nginx are already unreadable to anyone
  in between. **Nothing about the encryption is broken.**
- What failed is **trust**. The server sent a certificate that says *"I am
  `dlesieur.42.fr`, signed by `Inception Local CA`"*. Firefox looked in its list
  of authorities it trusts and did not find *that* `Inception Local CA`. So it
  cannot tell whether it is talking to your VM or to an impostor, and it stops.

Two facts that decide everything in this document:

1. **Trust is decided by the client, never by the server.** The server cannot
   make itself trusted. Only *you*, on the host, can add the VM's authority to
   the browser's list. So the fix is always on the host side.
2. **The authority changes every time the VM is rebuilt.** Inception's
   `make` generates a brand-new CA key when `secrets/ca.crt` does not exist,
   and `secrets/` is not in git. A new VM = a new CA = the old trust on the
   host is worthless, even though the CA has exactly the same name.

That second fact is why you are seeing the warning **today**:

| | Issued on | SHA-256 fingerprint (first bytes) |
|---|---|---|
| CA your Firefox and Chrome currently trust | Aug 28 2026, 10:51 UTC | `37:14:F3:A8:28:84:…:B7:FD` |
| CA actually signing the VM's certificate now | **Sep 3 2026, 11:35 UTC** | `6F:E7:F1:3A:14:D6:…:12:D5` |

Same name, different key. Firefox is right to refuse.

> **📚 What you are learning:** *encryption* and *authentication* are two
> separate jobs of TLS. A self-signed setup gives you the first for free; the
> second only exists once the client has been told whom to trust.

---

## 1. The map: where the bytes go

```
  HOST (your session, no root)                      VM "debian"  (hostname dlesieur42)
  ┌───────────────────────────────┐                 ┌──────────────────────────────────┐
  │ Firefox / Chrome / curl       │                 │  Docker network                  │
  │   "https://dlesieur.42.fr"    │                 │   ┌──────────┐    ┌───────────┐  │
  │        │                      │                 │   │  nginx   │───▶│ wordpress │  │
  │   name → 127.0.0.1 (see §4.5) │   VirtualBox    │   │ :443 TLS │    │  :9000    │  │
  │   port → 8443                 │   NAT forward   │   └────▲─────┘    └───────────┘  │
  │        │                      │  host 8443      │        │                          │
  │   127.0.0.1:8443 ─────────────┼──────────────▶ ─┼──▶ guest 443                     │
  └───────────────────────────────┘                 └──────────────────────────────────┘
                 ◀──────────── one TLS session, end to end, never decrypted ───────────▶
```

- The VM has no IP you can reach directly (VirtualBox **NAT** mode). VirtualBox
  listens on host `127.0.0.1:8443` and copies every byte to guest port `443`.
  That rule is named `https` and already exists (§4.1 shows how to check).
- The TLS session is between **your browser and nginx**. VirtualBox only moves
  bytes; it cannot read them. So there is no separate "tunnel" to encrypt — the
  HTTPS *is* the encrypted tunnel, and it already works. What is missing is the
  browser agreeing to *trust* the far end.
- You do **not** need an SSH tunnel (`ssh -L` / `ssh -D`). This repo tried the
  SOCKS variant and documented in `doc/SSH_VSCODE_FIX.md` that VirtualBox NAT
  silently drops it after ~15 minutes idle. The NAT forward has nothing to keep
  alive.

> **📚 What you are learning:** *port forwarding* — a host port is a door;
> VirtualBox opens it and pipes it to a door inside the VM. The host's
> `localhost:8443` and the VM's `localhost:443` are the same conversation.

---

## 2. Cheat sheet (if you already understand and just want to fix it)

```bash
# host, one command. It restarts both browsers itself when it managed to
# install the CA; if it warns that it could not, restart them yourself.
make host_access && make verify_access
```

If `make host_access` prints `Firefox: no certutil — accept the certificate
warning once per profile`, it could not download `libnss3-tools`; do §4.3 by
hand. The rest of this document is the same thing done step by step so you
understand each piece.

---

## 3. Inside the VM: check that the server side is right (nothing to change)

Log in from the host:

```bash
ssh b2b
```

You are `dlesieur@dlesieur42`. Inception lives in `~/inception` (not
`~/Documents/inception`; the deploy script's default differs, the clone is here).

### 3.1 The stack is up and nginx listens on 443

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
ss -ltn | grep -E ':(443|80|8090|8080) '
```

Expected: eight containers `Up … (healthy)` — `nginx` with `0.0.0.0:443->443/tcp`,
plus `wordpress`, `mariadb`, `redis`, `adminer` (8080), `staticsite` (8090),
`ftp`, `dbbackup`. `ss` shows `443` listening.

Port `80` is **not** Inception: it is Born2beRoot's own lighttpd/WordPress bonus.
Inception is HTTPS-only on 443 and has no HTTP→HTTPS redirect.

### 3.2 The name resolves inside the VM

```bash
grep 42.fr /etc/hosts
```

Expected: `127.0.0.1 dlesieur.42.fr`. If it is missing:

```bash
echo "127.0.0.1 dlesieur.42.fr" | sudo tee -a /etc/hosts
```

> **📚 What you are learning:** `dlesieur.42.fr` is not a real domain. No DNS
> server on Earth knows it. It exists only where a file says so — here
> `/etc/hosts` in the VM, and (§4.5) a browser preference on the host.

### 3.3 Look at the certificates — this is the heart of it

```bash
ls -la ~/inception/secrets/
```

```
-rw-rw-r--  ca.crt        the authority's public certificate  (world-readable, meant to be copied)
-rw-------  ca.key        the authority's PRIVATE key          (never leaves the VM, never given to a container)
-rw-rw-r--  server.crt    the site's certificate, SIGNED by the CA
-rw-------  server.key    the site's private key (nginx only)
-rw-rw-r--  ca.srl        serial-number counter
```

How they were made — the four `openssl` calls in Inception's `Makefile`
target `certs` (paraphrased, so you can read them as sentences):

```bash
# 1. a private key for the authority (elliptic curve P-256)
openssl ecparam -genkey -name prime256v1 -out secrets/ca.key
# 2. a SELF-signed certificate for that key: "I am Inception Local CA", valid 10 years
openssl req -new -x509 -nodes -days 3650 -key secrets/ca.key -out secrets/ca.crt \
    -subj "/C=FR/ST=IDF/L=Paris/O=42/OU=Inception/CN=Inception Local CA"
# 3. a private key + a signing REQUEST for the site: "I am dlesieur.42.fr"
openssl ecparam -genkey -name prime256v1 -out secrets/server.key
openssl req -new -key secrets/server.key -out secrets/server.csr -subj "/…/CN=dlesieur.42.fr"
# 4. the authority signs the request, adding the names the certificate is valid for (SAN)
openssl x509 -req -days 365 -in secrets/server.csr -CA secrets/ca.crt -CAkey secrets/ca.key \
    -CAcreateserial -out secrets/server.crt -extfile <(printf 'subjectAltName=DNS:dlesieur.42.fr,DNS:localhost,IP:127.0.0.1\n…')
```

Now read them back:

```bash
cd ~/inception/secrets
openssl x509 -in ca.crt     -noout -subject -dates -fingerprint -sha256
openssl x509 -in server.crt -noout -subject -issuer -dates -ext subjectAltName
openssl verify -CAfile ca.crt server.crt
```

Expected (today's values; **yours will differ after every rebuild**):

```
subject=C = FR, ST = IDF, L = Paris, O = 42, OU = Inception, CN = Inception Local CA
notBefore=Sep  3 11:35:17 2026 GMT
notAfter=Aug 31 11:35:17 2036 GMT
sha256 Fingerprint=6F:E7:F1:3A:14:D6:2A:E9:57:91:90:12:B0:15:4D:98:67:28:78:4F:95:7E:FE:02:CE:D7:95:B7:76:7D:12:D5

subject=C = FR, ST = IDF, L = Paris, O = 42, OU = 42, CN = dlesieur.42.fr
issuer=C = FR, ST = IDF, L = Paris, O = 42, OU = Inception, CN = Inception Local CA
notAfter=Sep  3 11:35:17 2027 GMT
X509v3 Subject Alternative Name:
    DNS:dlesieur.42.fr, DNS:localhost, IP Address:127.0.0.1

server.crt: OK
```

**Write down the CA fingerprint** (the `6F:E7:…` line). It is the CA's identity
card. In §4.2 you will compare it against what the host received; they must be
byte-for-byte identical, or you are trusting the wrong thing.

> **📚 What you are learning:**
> - A **CA** (certificate authority) is just a key pair whose certificate is
>   signed by itself. Anyone can create one in one command. What makes a CA
>   "real" is only that clients have chosen to trust it.
> - The **server certificate** is a statement *"this public key belongs to
>   `dlesieur.42.fr`"* signed with the CA's private key. `openssl verify` checks
>   that signature — that is what a browser does too.
> - **SAN** (Subject Alternative Name) is the list of names the certificate is
>   valid for. Browsers ignore `CN` and read SAN. `dlesieur.42.fr` is in it, so
>   the *name* is not the problem — only the *issuer* is.
> - The **fingerprint** is a SHA-256 of the whole certificate. Two certificates
>   with the same name but different keys have different fingerprints. That is
>   how you tell the Aug 28 CA from the Sep 3 CA.

### 3.4 Prove it works from inside the VM

```bash
curl -k                                 -s -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' https://dlesieur.42.fr/
curl --cacert ~/inception/secrets/ca.crt -s -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' https://dlesieur.42.fr/
```

Expected:

```
200 verify=20      ← -k: "ignore trust". Page served, but verify=20 = unknown issuer
200 verify=0       ← --cacert: "trust THIS authority". Fully valid.
```

That second line is the entire fix, in miniature: hand the client the CA and
the same server becomes trusted. The VM itself does **not** trust its own CA
(nothing installs it into `/etc/ssl`), which is fine — nothing in the VM
needs to.

### 3.5 If something above is wrong

```bash
cd ~/inception && make        # regenerates missing certs (never overwrites existing ones) and rebuilds
```

Two traps to know: the `certs` target only re-issues the server certificate
when it is **missing** or its SAN no longer matches `DOMAIN_NAME`. It does
**not** re-issue on **expiry** (Sep 3 2027 for today's file) — you would delete
`secrets/server.crt` by hand. And deleting `ca.crt` creates a **new CA**, which
sends you back to §4 on the host.

Type `exit` to return to the host.

---

## 4. On the host: make the browsers trust the VM's authority

### 4.1 Check the road exists (NAT rule and the VM is up)

```bash
VBoxManage showvminfo debian --machinereadable | grep -E '^VMState=|Forwarding.*"https,'
```

Expected:

```
VMState="running"
Forwarding(8)="https,tcp,,8443,,443"
```

If the `https` line is missing: `make host_access` recreates it (it never
rewrites an existing rule), or by hand
`VBoxManage controlvm debian natpf1 "https,tcp,,8443,,443"`. (`make
fix_app_ports` repairs only the app-stack rules, not this one.)
If the VM is not running: `make start_vm`.

### 4.2 Copy the CA out of the VM and check it is the right one

```bash
mkdir -p ~/Downloads && scp b2b:inception/secrets/ca.crt ~/Downloads/inception-ca.crt
openssl x509 -in ~/Downloads/inception-ca.crt -noout -subject -dates -fingerprint -sha256
```

The fingerprint must equal the one you wrote down in §3.3. Then look at what
the host **actually receives** on the forwarded port:

```bash
echo | openssl s_client -connect 127.0.0.1:8443 -servername dlesieur.42.fr 2>/dev/null \
     | grep -E 'subject=|issuer=|Verify return code|Protocol'
```

Expected:

```
subject=C = FR, …, CN = dlesieur.42.fr
issuer=C = FR, …, CN = Inception Local CA
Verify return code: 21 (unable to verify the first certificate)   ← before trust: expected
Protocol  : TLSv1.3
```

`-servername` matters: it is **SNI**, the browser's way of saying which site it
wants before encryption starts; nginx uses it to pick the certificate. And
"return code 21" is *not* a broken chain: the server sends only its own
certificate, and the CA is supposed to come from **your** trust store, not
from the wire.

Now prove that trusting the CA is sufficient, with no browser involved:

```bash
# WITHOUT trust → curl refuses, exactly like Firefox
curl -s -o /dev/null -w 'http=%{http_code} verify=%{ssl_verify_result}\n' \
     --resolve dlesieur.42.fr:8443:127.0.0.1 https://dlesieur.42.fr:8443/ ; echo "exit=$?"
# WITH the CA → fully valid
curl -s -o /dev/null -w 'http=%{http_code} verify=%{ssl_verify_result}\n' \
     --cacert ~/Downloads/inception-ca.crt \
     --resolve dlesieur.42.fr:8443:127.0.0.1 https://dlesieur.42.fr:8443/ ; echo "exit=$?"
```

Expected:

```
http=000 verify=20
exit=60                 ← curl error 60 = "SSL certificate problem: unable to get local issuer certificate"
http=200 verify=0
exit=0
```

> **📚 What you are learning:** `--resolve` is curl's private `/etc/hosts`:
> "when I say `dlesieur.42.fr:8443`, connect to `127.0.0.1`". The browser needs
> the same two things: a way to resolve the name (§4.5) and a way to trust the
> CA (§4.3/§4.4). Once `curl --cacert` says `200 verify=0`, everything left is
> browser bookkeeping.

### 4.3 Firefox

Firefox keeps **its own** certificate store, one per profile, in a file called
`cert9.db`. It ignores the system store. So the CA goes into the profile.

**Find your profile.** This Firefox is the **snap** build, so profiles are
*not* in `~/.mozilla`:

```bash
grep -A4 '^\[Profile' ~/snap/firefox/common/.mozilla/firefox/profiles.ini
```

The one with `Default=1` is yours. Today it is
`~/snap/firefox/common/.mozilla/firefox/iggelx2z.default-release`. (Or open
`about:profiles` in Firefox: "Root Directory" of the profile marked *in use*.)

```bash
FFP=~/snap/firefox/common/.mozilla/firefox/iggelx2z.default-release   # adjust to yours
```

**Get `certutil`.** It is the command-line tool for NSS databases. It is not
installed, and there is no root — but the package can be unpacked as a normal
user (this is exactly what `make host_access` does):

```bash
mkdir -p ~/.cache/born2root/nss && cd ~/.cache/born2root/nss
apt-get download libnss3-tools && dpkg-deb -x libnss3-tools_*.deb . && cd -
CU=~/.cache/born2root/nss/usr/bin/certutil
$CU -H 2>&1 | head -3   # prints its usage (on stderr) → it runs
```

**See what Firefox trusts right now:**

```bash
$CU -L -d "sql:$FFP"
$CU -L -d "sql:$FFP" -n "Inception Local CA" -a | openssl x509 -noout -dates -fingerprint -sha256
```

Expected today: `Inception Local CA   C,,` is listed, but its fingerprint is
`37:14:F3:A8:…` dated Aug 28 — the **old** one. This is the proof of the
diagnosis in §0.

**Replace it.** Quit Firefox completely first (every window; the process must
exit — check with `pgrep -f /firefox/firefox`, which should print nothing):

```bash
$CU -D -n "Inception Local CA" -d "sql:$FFP"                                          # remove the old
$CU -A -n "Inception Local CA" -t "C,," -d "sql:$FFP" -i ~/Downloads/inception-ca.crt # add the new
$CU -L -d "sql:$FFP" -n "Inception Local CA" -a | openssl x509 -noout -fingerprint -sha256
```

The last line must now print the **§3.3 fingerprint** (`6F:E7:F1:3A:…`).
`-t "C,,"` means *"trusted to sign server (SSL) certificates"* — and nothing
else (no e-mail, no code signing).

Start Firefox and open **`https://dlesieur.42.fr:8443/`** — no warning. Click
the padlock → *Connection secure* → *More information*: **Verified by: 42**.
`https://dlesieur.42.fr` (no port) also works, via the proxy in §4.5.

*Alternative without `certutil` — the GUI (standard Firefox dialog, not
re-tested here):* Settings → Privacy & Security → scroll to *Certificates* →
**View Certificates…** → tab **Authorities** → select *Inception Local CA*
under *42* → **Delete or Distrust…**; then **Import…** →
`~/Downloads/inception-ca.crt` → tick **"Trust this CA to identify
websites."** → OK. No restart needed with the GUI path.

*What "Accept the Risk and Continue" would do instead:* store a one-off
exception for `dlesieur.42.fr:8443` in `cert_override.txt`. The page loads,
the padlock stays crossed out, and it says nothing about *why*. Fine for a
lab; not what the subject means by a working TLS setup.

> **📚 What you are learning:** every application decides for itself whom to
> trust. Firefox has its own store; Chrome uses NSS's shared one; curl uses
> the system bundle. Adding a CA in one place changes nothing for the others.

### 4.4 Chrome

Chrome (the `.deb`, version 149) reads the NSS **shared** database at
`~/.pki/nssdb`. Same tool, different directory. Quit Chrome first.

```bash
$CU -L -d sql:$HOME/.pki/nssdb                          # today: the old Aug 28 CA is in there too
$CU -D -n "Inception Local CA" -d sql:$HOME/.pki/nssdb
$CU -A -n "Inception Local CA" -t "C,," -d sql:$HOME/.pki/nssdb -i ~/Downloads/inception-ca.crt
$CU -L -d sql:$HOME/.pki/nssdb -n "Inception Local CA" -a | openssl x509 -noout -fingerprint -sha256
```

Start Chrome and open **`https://dlesieur.42.fr`**. It resolves through the
desktop proxy setting (§4.5); the certificate is now trusted, so no
`ERR_CERT_AUTHORITY_INVALID`. (GUI alternative, not re-tested here:
`chrome://certificate-manager` → *Custom* / *Installed by you* → Import.)

Two things about the `inception-browser` launcher you may have used before:
it currently execs `/snap/bin/chromium`, which is **no longer installed** on
this host, and it pins the **old** CA's public key. Re-running
`make host_access` rewrites it for Google Chrome with the new key. Note also
that the pin alone is not enough when the CA is absent from `~/.pki/nssdb`
(verified: Chrome still shows *Privacy error*); the NSS store is what counts.

### 4.5 The name and the port — already configured, here is what to check

Nothing on the host resolves `dlesieur.42.fr` by itself (no root → no
`/etc/hosts`). Three pieces do it instead, all written by `make host_access`:

| Piece | Where | What it does | Check |
|---|---|---|---|
| Firefox pref `network.dns.localDomains` | `$FFP/user.js` | resolves the name to `127.0.0.1` inside Firefox → `https://dlesieur.42.fr:8443` works directly | `about:config` → search `localDomains` |
| Local proxy `inception-proxy.service` | `systemd --user`, `127.0.0.1:8118` | for the **bare** URL: takes `CONNECT dlesieur.42.fr:443` and sends it to `127.0.0.1:8443`, without decrypting anything | `systemctl --user is-active inception-proxy.service` → `active` |
| PAC file | Firefox: `$FFP/inception.pac`; Chrome/desktop: `http://127.0.0.1:8118/inception.pac` | "use the proxy for this one domain, DIRECT for everything else" | `curl -s http://127.0.0.1:8118/inception.pac`; `gsettings get org.gnome.system.proxy mode` → `'auto'` |

Why a proxy for the port-less URL: Firefox can resolve the name but cannot
change the port, so `https://dlesieur.42.fr` means `127.0.0.1:443`, and no
process without root may listen on 443 (`ip_unprivileged_port_start` is
1024). A proxied request carries the wanted host **and port** inside the
request, so the proxy can go to 8443 while the URL bar, the SNI and the
`Host` header still say the real domain on 443 — which is exactly what the
certificate and WordPress expect. Everything not this domain stays `DIRECT`.

End-to-end check of that path, with full verification:

```bash
curl -s --proxy 127.0.0.1:8118 --cacert ~/Downloads/inception-ca.crt \
     -o /dev/null -w 'http=%{http_code} verify=%{ssl_verify_result}\n' https://dlesieur.42.fr/
```

Expected: `http=200 verify=0`.

> **📚 What you are learning:** a browser has *three* things to get right for
> one HTTPS URL: the **name** (DNS/hosts/pref), the **socket** (IP:port —
> here a NAT forward, optionally behind a proxy), and the **trust** (CA in the
> right store). Each one fails with a different message: *Server Not Found*,
> *Connection refused*, *Potential Security Risk*. Reading the message tells
> you which of the three to look at.

### 4.6 The automated version, and what it does not check

```bash
make host_access      # §4.1 rules + §4.3 + §4.4 + §4.5, then restarts both browsers (opt out: INCEPTION_NO_BROWSER_RESTART=1)
make verify_access    # NAT, TLS/SNI, no WordPress redirect, proxy, PAC, headless Firefox + Chrome load
```

`host_access` fetches `ca.crt` over `ssh b2b` (it searches `~/inception`,
`~/Documents/inception`, then `find`), so the VM must be up. It downloads
`libnss3-tools` if `~/.cache/born2root/nss` is missing — which it is today,
so it needs the campus mirror to answer.

Known gap: `verify_access` checks that a CA **named** *Inception Local CA* is
present in each store; it does not compare its fingerprint with the CA that
signs the served certificate. After a rebuild it can therefore say *All
required checks passed* while Firefox still warns. The fingerprint comparison
in §4.3 is the check that catches it.

---

## 5. Every time you rebuild the VM

`make re`, `make fresh`, deleting `~/inception/secrets` in the guest, or
re-cloning Inception all create a **new CA**. Then:

1. §4.2 — copy the new `ca.crt` and compare fingerprints (it *will* differ).
2. §4.3 + §4.4 — remove the old *Inception Local CA*, add the new one.
3. Restart both browsers completely.

Or simply `make host_access`, then check the fingerprint in §4.3.

---

## 6. Troubleshooting: read the message, pick the row

| Browser says | Which of the three | Cause | Fix |
|---|---|---|---|
| **Potential Security Risk / `SEC_ERROR_UNKNOWN_ISSUER`** (Firefox) | trust | CA not in `cert9.db`, or an **old** CA with the same name (rebuild) | §4.3; compare fingerprints |
| **`ERR_CERT_AUTHORITY_INVALID`** / *Privacy error* (Chrome) | trust | same, for `~/.pki/nssdb` | §4.4 |
| **Server Not Found** / `DNS_PROBE_FINISHED_NXDOMAIN` | name | `user.js` pref not read (Firefox started before it was written) or PAC not served | quit Firefox fully and reopen; `systemctl --user restart inception-proxy.service` |
| **Unable to connect** / *Connection refused* on `:8443` | socket | VM off, or `https` NAT rule missing | `make start_vm`; §4.1 |
| **Connection refused** on bare `https://dlesieur.42.fr` | socket | proxy down, browser fell back to `DIRECT` → `127.0.0.1:443` | `systemctl --user restart inception-proxy.service` |
| Page loads, then jumps to `https://dlesieur.42.fr/` and fails | WordPress | the guest's WordPress redirects unknown `Host` headers; only happens with an old Inception checkout | `cd ~/inception && git pull && make` in the VM |
| CSS/JS missing on the `:8443` URL | WordPress | same cause: asset URLs without the port | same |
| `make host_access`: *no certutil — accept the warning* | tooling | `apt-get download libnss3-tools` failed (mirror) | retry, or §4.3 download by hand |
| **`SSL received a record that exceeded the maximum permissible length`** on `:8090` | browser | Firefox's `dom.security.https_first` (default **true** since 129) rewrote `http://` to `https://`, but the bonus site speaks plain HTTP — so an HTTP reply was parsed as TLS. `https_only_mode` is a *different* pref and does not cover it | `make host_access` (writes `dom.security.https_first=false`), then restart Firefox |
| `scp b2b:…` → *Host key verification failed* | ssh | VM rebuilt, stale key for `[127.0.0.1]:4242` | `ssh-keygen -R '[127.0.0.1]:4242'` then `ssh-keyscan -p 4242 127.0.0.1 >> ~/.ssh/known_hosts` |

---

## 7. What was verified for this document, and how

All run on 2026-09-03 on this host, against the running VM, **without touching
your real browser profiles**:

- Guest: `openssl verify` → `server.crt: OK`; `curl --cacert` → `200 verify=0`;
  nginx `listen 443 ssl`, `ssl_protocols TLSv1.2 TLSv1.3`; TLS 1.1 refused.
- Host: `scp b2b:inception/secrets/ca.crt` works with the `b2b` alias; the
  fetched CA has fingerprint `6F:E7:F1:3A:…`; `curl` fails with exit 60 without
  it and returns `200 verify=0` with it, both direct on `:8443` and through the
  proxy on the bare URL.
- `apt-get download libnss3-tools` + `dpkg-deb -x` yields a working `certutil`
  as a normal user; `-N`, `-D`, `-A`, `-L` were exercised on a scratch database.
- A **throwaway Firefox profile** with only `network.dns.localDomains` and the
  new CA in `cert9.db`, run headless, loaded `https://dlesieur.42.fr:8443/`
  and screenshotted the Inception site (not the warning page). Without the CA
  the headless load never completes.
- **Chrome** with an isolated `HOME` whose `.pki/nssdb` holds the new CA
  loaded the bare `https://dlesieur.42.fr/` (title *Inception – infra docs &
  engineering journal*). With the real `~/.pki/nssdb` (old CA) it shows
  *Privacy error*, pin or no pin.
- The two GUI import dialogs (§4.3 alternative, §4.4 alternative) were **not**
  driven here; they are the standard Firefox/Chrome dialogs and do the same
  `cert9.db` / `nssdb` write as `certutil`.

---

## 8. If you sit down at a different computer

Measured on 42 Madrid on 2026-09-03, moving from `c1r17s4` to `c2r19s1`. Two
filesystems are in play and **only one of them follows you**:

| Path | Filesystem | Follows you? | What lives there |
|---|---|---|---|
| `/sgoinfre/students/<login>/born2root` | NFS, shared | **yes** | the repo, the ISOs, `disk_images/<vm>.vdi` — the VM's actual disk |
| `$HOME` | local disk (`xfs`, ~4.7 GB) | **no** | `~/.config/VirtualBox` (which VMs are registered), your Firefox/Chrome profiles **and their CA trust**, `~/.ssh/config`, `~/.cache` |

Three consequences, in the order they bite:

1. **The VirtualBox kernel driver is per machine.** It is loaded by
   `vboxdrv.service` at that machine's own boot, and loading it needs root.
   A workstation where that service failed cannot start any VM, no matter how
   correct the repo is. Check before anything else:

   ```bash
   make check_driver
   ```

   It names the machine, says whether the module is even built for the running
   kernel, and tells you whether you can fix it yourself. `make all` now runs
   this first, so a driverless machine stops in under a second instead of
   downloading an ISO and failing at the VM start.

2. **The VM is registered per machine, but its disk is shared.** On a new
   machine `make all` re-registers the VM around the *same* `.vdi` on
   `/sgoinfre`. That also means **deleting the disk here destroys the VM the
   other machine boots**. `make rm_disk_image`, and therefore `fclean`, `re`
   and `fresh`, now refuse when `disk_images/<vm>/.built-on` names a different
   machine *and* the disk holds a real system (over 100 MB). A freshly created
   ~2 MB disk is not protected, since it holds nothing. Override with
   `FORCE_HOST=1` when you mean it.

3. **Browser trust does not follow you.** `cert9.db` lives in the browser
   profile inside the local `$HOME`, so the authority you trusted in §4.3 and
   §4.4 is simply not present on the new machine, and `certutil` has to be
   re-downloaded because `~/.cache` is local too. Just re-run:

   ```bash
   make host_access
   ```

   The local proxy is the one piece that does come back on its own: its unit is
   `systemd --user` *enabled*, so it starts at login on each machine.

> **📚 What you are learning:** "it worked yesterday" is not a property of a
> project, it is a property of a machine plus a home directory. When something
> that used to work fails after you move seats, ask which of the three layers
> moved with you: the **files** (shared here), the **per-user configuration**
> (local here), and the **kernel** (never shared).
