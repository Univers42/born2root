#!/usr/bin/env python3
"""Open a file, sent from the headless VM, in the host's GUI.

The VM is a server install with no desktop, so `xdg-open en.subject.pdf` inside
it has nothing to draw on. The file has to reach a machine that does have a
screen. This is the receiving half of that: a small service on the host that
accepts a file over loopback and hands it to `xdg-open`.

The VM reaches it through the SSH session that is already open. `ssh b2b`
carries a RemoteForward (added by orchestrate.sh), so a port on the *guest*
tunnels back to this service on the *host*. Nothing new is exposed: no port on
the network, no second SSH server, no shared folder, no Guest Additions.

    guest:7654  --[ the ssh b2b connection ]-->  host:7654  -->  xdg-open

Protocol, deliberately tiny so the guest side is a few lines of bash:

    OPEN <filename>\\n
    <raw bytes until the sender closes the connection>

Safety: the file is written to a scratch directory and handed to xdg-open,
which opens it in the registered *viewer*. It is never made executable and never
run. The filename is reduced to a bare basename, so a sender cannot write
outside that directory. The listener is bound to loopback only, and reachable
solely through an SSH session the host itself initiated.
"""

import argparse
import os
import re
import shutil
import socket
import socketserver
import subprocess
import sys

MAX_BYTES = 128 * 1024 * 1024  # a PDF or a log, not a disk image
SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]")


class Config:
    outdir = ""
    opener = "xdg-open"


def safe_basename(raw):
    """Reduce anything the sender claims to a harmless file name."""
    name = os.path.basename(raw.strip().replace("\\", "/"))
    name = SAFE_NAME.sub("_", name).lstrip(".") or "file"
    return name[:120]


class Handler(socketserver.StreamRequestHandler):
    timeout = 300

    def handle(self):
        header = self.rfile.readline(4096)
        if not header:
            return
        try:
            verb, _, raw_name = header.decode("utf-8", "replace").strip().partition(" ")
        except Exception:
            return
        if verb.upper() != "OPEN":
            self.reply("ERR expected: OPEN <filename>")
            return

        name = safe_basename(raw_name)
        dest = os.path.join(Config.outdir, name)

        written = 0
        try:
            with open(dest, "wb") as fh:
                while True:
                    chunk = self.rfile.read1(65536) if hasattr(self.rfile, "read1") \
                        else self.rfile.read(65536)
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > MAX_BYTES:
                        self.reply("ERR file too large")
                        fh.close()
                        os.unlink(dest)
                        return
                    fh.write(chunk)
        except OSError as exc:
            self.reply("ERR could not write: %s" % exc)
            return

        if written == 0:
            os.unlink(dest)
            self.reply("ERR empty file")
            return

        # Never executable: this is something to look at, not to run.
        os.chmod(dest, 0o600)
        try:
            subprocess.Popen(
                [Config.opener, dest],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as exc:
            self.reply("ERR could not launch %s: %s" % (Config.opener, exc))
            return
        self.reply("OK opened %s (%d bytes)" % (name, written))
        print("opened %s (%d bytes)" % (dest, written), flush=True)

    def reply(self, message):
        try:
            self.wfile.write((message + "\n").encode("utf-8"))
            self.wfile.flush()
        except OSError:
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=7654)
    ap.add_argument("--opener", default="xdg-open")
    ap.add_argument(
        "--outdir",
        default=os.path.join(
            os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "inception-open"
        ),
        help="where received files are staged",
    )
    args = ap.parse_args()

    if not shutil.which(args.opener):
        sys.exit("no %s on this host — nothing could display the file" % args.opener)

    Config.outdir = args.outdir
    Config.opener = args.opener
    os.makedirs(Config.outdir, mode=0o700, exist_ok=True)

    server = Server(("127.0.0.1", args.port), Handler)
    print(
        "open-from-vm agent on 127.0.0.1:%d  (staging in %s, opener %s)"
        % (args.port, Config.outdir, Config.opener),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
