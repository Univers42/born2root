#!/usr/bin/env python3
"""A host path from a profile: $USER/$HOME expanded, a list resolved.

One tracked profile has to build the same VM on the seat that built it
(/mnt/storage) and on a 42 seat that has no /mnt/storage, only /goinfre and a
quota'd home. So a host path in the profile -- [vm] path, [dc] backup_dest,
[dc] secrets_file -- may be a list, tried in order, and may say $USER or $HOME
instead of naming anybody. Both expansions live here and only here; the shell
asks through b2b_host_path (utils/b2b_config.sh).

  host_path.py VALUE...   the resolved path on stdout ("" when given nothing)

Only $USER, ${USER}, $HOME and ${HOME} are expanded -- not the whole
environment, so a stray $VAR in a profile stays visible instead of turning
into "" on one machine and something else on another.
"""

from __future__ import annotations

import os
import pwd
import re
import sys

_PLACEHOLDER = re.compile(r"\$(?:\{(USER|HOME)\}|(USER|HOME)(?![A-Za-z0-9_]))")


def _host_user():
    """The login of the calling uid, as `id -un` prints it."""
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        return os.environ.get("USER", "")


def _host_home():
    home = os.environ.get("HOME")
    if home:
        return home
    try:
        return pwd.getpwuid(os.getuid()).pw_dir
    except KeyError:
        return ""


def expand(value):
    """VALUE with $USER/${USER} and $HOME/${HOME} replaced; nothing else."""
    if "$" not in value:
        return value
    names = {"USER": _host_user, "HOME": _host_home}
    return _PLACEHOLDER.sub(lambda m: names[m.group(1) or m.group(2)](), value)


def _usable_dir(path):
    return os.path.isdir(path) and os.access(path, os.W_OK | os.X_OK)


def _creatable(path):
    """True when the nearest existing ancestor is a directory we may write."""
    parent = os.path.dirname(path.rstrip("/")) or "/"
    while not os.path.lexists(parent):
        up = os.path.dirname(parent)
        if up == parent:
            return False
        parent = up
    return _usable_dir(parent)


# Ponytail: "usable" is decided once, from existence and permission bits, at
# the moment of the call. A directory that exists but fills up mid-build is
# still chosen; a /goinfre that the seat wipes overnight is chosen today and
# gone tomorrow (the Makefile's disk_images/.vm_path.<vm> stamp then points at
# a path that no longer exists); a read-only bind mount whose bits say
# writable is chosen and fails at the first write. ACLs and quotas are not
# consulted. When it picks wrong, set VM_PATH= / BACKUP_DEST= for the run, or
# reorder the list.
def resolve(values):
    """The first entry that exists and is writable; else the first one that
    can be created; else the first entry, so the error that follows names
    the path the profile asked for first. A single path is itself."""
    paths = [expand(v) for v in values if v]
    if len(paths) <= 1:
        return paths[0] if paths else ""
    for path in paths:
        if _usable_dir(path):
            return path
    for path in paths:
        if _creatable(path):
            return path
    return paths[0]


def main(argv):
    sys.stdout.write(resolve(argv))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
