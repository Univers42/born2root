#!/usr/bin/env python3
"""ts_share_policy.py POLICY.hujson -- the tailnet policy with VM sharing on.

Replaces the allow-all grant Tailscale ships ({"src": ["*"], "dst": ["*"],
"ip": ["*"]}) with the two that sharing needs, editing the text so every
comment in the file survives:

  autogroup:member -> *                your own devices, as before
  autogroup:shared -> tag:b2b tcp:4242 an invited colleague, the VM's sshd only

Tagged machines (the VMs) are then left with no grant as a source, so a VM
cannot open anything on the tailnet -- the path to the host the host's wall
(vm_wall.sh) cannot see, because DERP relays it.

Exit 0 with the new policy on stdout, 3 when it already has the shared grant
and no allow-all (nothing to do), 2 when it has neither: a policy someone
wrote by hand is not rewritten here.
Caveat: the allow-all grant is found by a regex over its usual spelling; one
split across comments or with extra keys counts as hand-written (exit 2).
"""
import re
import sys

ALLOW_ALL = re.compile(
    r'(?://\s*Allow all connections\.\s*//\s*Comment this section out[^\n]*\n\s*)?'
    r'\{\s*"src"\s*:\s*\["\*"\]\s*,\s*"dst"\s*:\s*\["\*"\]\s*,'
    r'\s*"ip"\s*:\s*\["\*"\]\s*,?\s*\}\s*,?')
SHARED = re.compile(
    r'"src"\s*:\s*\["autogroup:shared"\]\s*,\s*"dst"\s*:\s*\["tag:b2b"\]')
NEW = '''{
\t\t\t"src": ["autogroup:member"],
\t\t\t"dst": ["*"],
\t\t\t"ip":  ["*"],
\t\t},
\t\t// make share_invite: an invited colleague reaches the VM's sshd and
\t\t// nothing else; tagged machines (the VMs) start no connection at all.
\t\t{
\t\t\t"src": ["autogroup:shared"],
\t\t\t"dst": ["tag:b2b"],
\t\t\t"ip":  ["tcp:4242"],
\t\t},'''


def share_policy(text):
    """(code, text): 0 and the edited policy, 3 already done, 2 refused."""
    has_all = ALLOW_ALL.search(text)
    if SHARED.search(text):
        return (3, text) if not has_all else (2, text)
    if not has_all:
        return 2, text
    return 0, ALLOW_ALL.sub(lambda _m: NEW, text, count=1)


def main():
    code, text = share_policy(open(sys.argv[1], encoding="utf-8").read())
    if code == 2:
        print("the tailnet policy has no allow-all grant to replace; add this "
              "grant by hand:\n" + NEW.split("},", 1)[1], file=sys.stderr)
    elif code == 0:
        sys.stdout.write(text)
    sys.exit(code)


if __name__ == "__main__":
    main()
