#!/usr/bin/env python3
"""Tiny local proxy that gives the host browsers the bare Inception URL.

Why this exists
---------------
The subject's domain must answer at ``https://<login>.42.fr`` with no port. On a
42 campus machine that is impossible by the obvious routes:

* the host cannot resolve the name (no root, so no ``/etc/hosts`` entry), and
* ``net.ipv4.ip_unprivileged_port_start`` is 1024, so *nothing* running as this
  user -- VirtualBox's NAT included -- may bind host port 443. The VM's HTTPS is
  therefore only reachable on a high port such as 8443.

Firefox's ``network.dns.localDomains`` pref solves the first half: it maps the
name to 127.0.0.1 inside the browser. It cannot touch the port, so Firefox then
asks for 127.0.0.1:443 and gets "connection refused".

A proxy fixes the second half, because a proxied request carries the *intended*
host and port in the request itself: the browser hands over ``CONNECT
<login>.42.fr:443`` and this process decides where that actually goes. The URL
bar, the SNI name and the ``Host`` header all keep saying the real domain and
port 443, so WordPress and the TLS certificate both see exactly what they expect
-- only the TCP destination changes.

This is deliberately not the ``ssh -D`` SOCKS tunnel that doc/SSH_VSCODE_FIX.md
records going stale after ~15 minutes idle. There is no tunnel here and no
long-lived multiplexed channel: every request opens a fresh TCP connection to
the VirtualBox NAT forward, the same path curl uses.

The generated PAC file sends *only* the Inception domain here; everything else
stays DIRECT, and it lists ``DIRECT`` as a fallback so that if this process is
not running the browser degrades to a normal connection instead of failing.
"""

import argparse
import select
import socket
import socketserver
import sys
import threading

BUFSIZE = 65536
CONNECT_TIMEOUT = 10


class Config:
    domain = ""
    portmap = {}
    listen_port = 8118
    pac_path = "/inception.pac"


def relay(a, b):
    """Shuttle bytes between two sockets until either side closes."""
    socks = [a, b]
    try:
        while True:
            readable, _, errored = select.select(socks, [], socks, 60)
            if errored:
                break
            if not readable:
                continue
            for src in readable:
                dst = b if src is a else a
                try:
                    data = src.recv(BUFSIZE)
                except OSError:
                    return
                if not data:
                    return
                try:
                    dst.sendall(data)
                except OSError:
                    return
    finally:
        for s in socks:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass


def target_for(host, port):
    """Where a request for host:port should really go, or None if not ours."""
    if host != Config.domain:
        return None
    upstream = Config.portmap.get(port)
    if upstream is None:
        return None
    return ("127.0.0.1", upstream)


class Handler(socketserver.StreamRequestHandler):
    timeout = 120

    def handle(self):
        try:
            request_line = self.rfile.readline(65536)
        except OSError:
            return
        if not request_line:
            return
        try:
            parts = request_line.decode("latin-1").split()
        except UnicodeDecodeError:
            return
        if len(parts) < 3:
            return
        method, target, version = parts[0], parts[1], parts[2]

        if method.upper() == "CONNECT":
            self.do_connect(target)
        else:
            self.do_plain(method, target, version)

    # ── https:// -> CONNECT <domain>:443 ────────────────────────────────────
    def do_connect(self, target):
        host, _, port_s = target.rpartition(":")
        try:
            port = int(port_s)
        except ValueError:
            self.fail(400, "bad CONNECT target")
            return
        upstream = target_for(host, port)
        if upstream is None:
            self.fail(403, "not an Inception host")
            return

        # Drain the rest of the request headers before switching to tunnel mode.
        while True:
            line = self.rfile.readline(65536)
            if not line or line in (b"\r\n", b"\n"):
                break

        try:
            remote = socket.create_connection(upstream, CONNECT_TIMEOUT)
        except OSError as exc:
            self.fail(502, "cannot reach %s:%s (%s)" % (upstream[0], upstream[1], exc))
            return

        try:
            self.wfile.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            self.wfile.flush()
        except OSError:
            remote.close()
            return
        relay(self.connection, remote)

    # ── http:// -> absolute-URI request ─────────────────────────────────────
    def do_plain(self, method, target, version):
        # Chrome refuses a file:// PAC URL coming from the desktop proxy
        # settings, so the proxy serves its own PAC over http instead. This is
        # an origin-form request (a plain GET /path) rather than the absolute
        # URI a proxied request carries, which is how the two are told apart.
        if target == Config.pac_path:
            self.serve_pac()
            return
        if not target.lower().startswith("http://"):
            self.fail(400, "expected an absolute URI")
            return
        rest = target[len("http://"):]
        authority, slash, path = rest.partition("/")
        path = "/" + path if slash else "/"
        if ":" in authority:
            host, _, port_s = authority.rpartition(":")
            try:
                port = int(port_s)
            except ValueError:
                self.fail(400, "bad port")
                return
        else:
            host, port = authority, 80

        upstream = target_for(host, port)
        if upstream is None:
            self.fail(403, "not an Inception host")
            return

        headers = []
        while True:
            line = self.rfile.readline(65536)
            if not line or line in (b"\r\n", b"\n"):
                break
            headers.append(line)

        try:
            remote = socket.create_connection(upstream, CONNECT_TIMEOUT)
        except OSError as exc:
            self.fail(502, "cannot reach %s:%s (%s)" % (upstream[0], upstream[1], exc))
            return

        # Rewrite only the request line to origin-form. Every header, Host
        # included, is passed through untouched so the server still sees the
        # real domain and port.
        out = ["%s %s %s\r\n" % (method, path, version)]
        try:
            remote.sendall(out[0].encode("latin-1") + b"".join(headers) + b"\r\n")
        except OSError:
            remote.close()
            return
        relay(self.connection, remote)

    def serve_pac(self):
        body = (
            "function FindProxyForURL(url, host) {\n"
            '    if (host === "%s" || dnsDomainIs(host, ".%s"))\n'
            '        return "PROXY 127.0.0.1:%d; DIRECT";\n'
            '    return "DIRECT";\n'
            "}\n" % (Config.domain, Config.domain, Config.listen_port)
        ).encode("utf-8")
        try:
            self.wfile.write(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: application/x-ns-proxy-autoconfig\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                b"Connection: close\r\n\r\n" + body
            )
            self.wfile.flush()
        except OSError:
            pass

    def fail(self, code, message):
        try:
            body = message.encode("utf-8")
            self.wfile.write(
                b"HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
                % (code, body, len(body), body)
            )
            self.wfile.flush()
        except OSError:
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8118, help="port to listen on")
    ap.add_argument("--domain", required=True, help="the only host this proxy serves")
    ap.add_argument(
        "--map",
        action="append",
        default=[],
        metavar="ASKED:ACTUAL",
        help="port the browser asks for : port on 127.0.0.1 to use instead",
    )
    args = ap.parse_args()

    Config.domain = args.domain
    Config.listen_port = args.port
    for entry in args.map:
        asked, _, actual = entry.partition(":")
        try:
            Config.portmap[int(asked)] = int(actual)
        except ValueError:
            sys.exit("bad --map entry: %r" % entry)
    if not Config.portmap:
        sys.exit("at least one --map is required")

    # Loopback only: this must never be reachable from outside the machine.
    server = Server(("127.0.0.1", args.port), Handler)
    mapping = ", ".join(
        "%s:%d -> 127.0.0.1:%d" % (Config.domain, a, b)
        for a, b in sorted(Config.portmap.items())
    )
    print("inception-proxy on 127.0.0.1:%d  (%s)" % (args.port, mapping), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
