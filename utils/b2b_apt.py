#!/usr/bin/env python3
"""[packages] apt in born2root.toml, resolved against Debian's own index.

A package name is a promise made twenty minutes before anything can check it:
a typo, a virtual name with three providers, or a package whose dependencies
do not fit / would otherwise fail first boot, 25 minutes into `make all`. So
the host reads the mirror's Packages index before the ISO is downloaded and
answers three questions, each with a refusal that names the fix:

  * does every name exist? (else: close matches from the index)
  * which real package does a virtual name mean? (one provider: that one;
    several: refused, listing them -- apt would stop and ask)
  * how much disk does it cost? The dependency closure over Depends and
    Pre-Depends, minus what the guest has anyway (Priority required,
    important and standard, Essential, the preseed's pkgsel/include and every
    package b2b-setup.sh installs), summed from Installed-Size -- which is in
    KiB. That lands on /. The .debs are downloaded to /var/cache/apt first, so
    their Size is charged to /var. Recommends are not installed
    (first boot passes --no-install-recommends), so they are not counted.

The model is deliberately simple -- versions and :any qualifiers are ignored,
the first satisfiable alternative wins -- and the fit check keeps 20 %
headroom over it anyway.

The index is cached in ${XDG_CACHE_HOME:-~/.cache}/born2root/apt/<codename>/,
outside the repository (utils/space_budget.sh measures the repository against
the quota), refreshed after 24 hours. An unreachable mirror reuses a stale
cache with a warning; with no cache at all it is an error. The last answer is
kept beside it so feature_profile.sh and the picker can price the same list
without the network.

  b2b_apt.py resolve PKG...   stdout: "package NAME" per install target, then
                              "root_mb N", "var_mb N", "closure N"; exit 1
                              naming every problem
  b2b_apt.py cached PKG...    the root_mb/var_mb lines of the last resolve of
                              exactly this list, or nothing (never the network)

Env: B2B_APT_MIRROR (deb.debian.org), B2B_APT_INDEX=file[:file...] (use these
Packages files and never the network -- the tests), B2B_APT_CACHE (the cache
directory), B2B_ROOT_OVERRIDE (repository root, for scraping the base set).
"""

from __future__ import annotations

import difflib
import lzma
import os
import re
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("B2B_ROOT_OVERRIDE") or os.path.dirname(HERE)
COMPONENTS = ("main", "contrib", "non-free", "non-free-firmware")
MAX_AGE = 24 * 3600
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]+$")


class AptError(Exception):
    pass


def warn(message):
    sys.stderr.write("b2b_apt: %s\n" % message)


def cache_root():
    base = os.environ.get("B2B_APT_CACHE")
    if base:
        return base
    xdg = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(xdg, "born2root", "apt")


# ── The index ───────────────────────────────────────────────────────────────
def fetch(url, timeout=30):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return response.read()


def codename(mirror, cache):
    """stable's codename, from the mirror, else from the newest cache."""
    try:
        release = fetch("http://%s/debian/dists/stable/Release" % mirror).decode("utf-8", "replace")
        match = re.search(r"^Codename:\s*(\S+)", release, re.M)
        if match:
            return match.group(1)
    except (urllib.error.URLError, OSError) as exc:
        cached = sorted(
            (d for d in os.listdir(cache) if os.path.isdir(os.path.join(cache, d))),
            key=lambda d: os.path.getmtime(os.path.join(cache, d)),
        ) if os.path.isdir(cache) else []
        if cached:
            warn("%s is unreachable (%s); using the cached %s index" % (mirror, exc, cached[-1]))
            return cached[-1]
        raise AptError(
            "cannot reach http://%s/debian to check the packages, and nothing is "
            "cached yet: %s" % (mirror, exc)
        )
    raise AptError("http://%s/debian/dists/stable/Release names no Codename" % mirror)


def index_files(mirror):
    """Paths of decompressed Packages files, fetched or cached."""
    override = os.environ.get("B2B_APT_INDEX")
    if override:
        return [p for p in override.split(":") if p], "fixture"
    cache = cache_root()
    name = codename(mirror, cache)
    directory = os.path.join(cache, name)
    os.makedirs(directory, exist_ok=True)
    paths = []
    for component in COMPONENTS:
        path = os.path.join(directory, component + "_Packages")
        fresh = os.path.isfile(path) and time.time() - os.path.getmtime(path) < MAX_AGE
        if not fresh:
            url = "http://%s/debian/dists/%s/%s/binary-amd64/Packages.xz" % (mirror, name, component)
            try:
                data = lzma.decompress(fetch(url, timeout=120))
                with open(path + ".tmp", "wb") as fh:
                    fh.write(data)
                os.replace(path + ".tmp", path)
            except (urllib.error.URLError, OSError, lzma.LZMAError) as exc:
                if os.path.isfile(path):
                    warn("could not refresh %s (%s); using the cached copy" % (component, exc))
                elif component == "main":
                    raise AptError("cannot download the %s index from %s: %s" % (component, mirror, exc))
                else:
                    warn("no %s index (%s); names only found there will be unknown" % (component, exc))
                    continue
        paths.append(path)
    return paths, name


def parse(paths):
    """Package name -> fields; virtual name -> providers."""
    packages, provides = {}, {}
    for path in paths:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for stanza in text.split("\n\n"):
            fields, key = {}, None
            for line in stanza.splitlines():
                if line[:1] in (" ", "\t") and key:
                    fields[key] += " " + line.strip()
                elif ":" in line:
                    key, _, value = line.partition(":")
                    fields[key] = value.strip()
            name = fields.get("Package")
            if not name or name in packages:
                continue
            packages[name] = fields
            for provided in split_list(fields.get("Provides", "")):
                provides.setdefault(provided[0], []).append(name)
    return packages, provides


def split_list(value):
    """"a (>= 1), b | c:any" -> [["a"], ["b", "c"]]."""
    groups = []
    for group in value.split(","):
        alternatives = []
        for alt in group.split("|"):
            alt = re.sub(r"\(.*?\)|\[.*?\]|<.*?>", "", alt).strip()
            alt = alt.split(":")[0]
            if alt:
                alternatives.append(alt)
        if alternatives:
            groups.append(alternatives)
    return groups


# ── What the guest has anyway ───────────────────────────────────────────────
def scraped_base():
    """pkgsel/include and every package b2b-setup.sh names after $APT."""
    names = set()
    try:
        with open(os.path.join(ROOT, "preseeds", "preseed.cfg.in"), encoding="utf-8") as fh:
            match = re.search(r"^d-i pkgsel/include string (.*)$", fh.read(), re.M)
        if match:
            names.update(match.group(1).split())
    except OSError:
        pass
    try:
        with open(os.path.join(ROOT, "preseeds", "b2b-setup.sh"), encoding="utf-8") as fh:
            text = fh.read().replace("\\\n", " ")
        for match in re.finditer(r"\$APT\s+([^\n;&|]*)", text):
            names.update(w for w in match.group(1).split() if NAME_RE.match(w))
    except OSError:
        pass
    return names


def closure(start, packages, provides, have=frozenset()):
    """Every real package start pulls in over Depends/Pre-Depends."""
    seen, stack = set(), list(start)
    while stack:
        name = stack.pop()
        if name in seen or name in have:
            continue
        seen.add(name)
        fields = packages.get(name, {})
        deps = split_list(fields.get("Pre-Depends", "")) + split_list(fields.get("Depends", ""))
        for alternatives in deps:
            chosen = None
            for alt in alternatives:
                if alt in have or alt in seen:
                    chosen = alt
                    break
            if chosen is None:
                for alt in alternatives:
                    if alt in packages:
                        chosen = alt
                        break
                    if len(provides.get(alt, [])) >= 1:
                        chosen = provides[alt][0]
                        break
            if chosen and chosen not in seen and chosen not in have:
                stack.append(chosen)
    return seen


def installed_base(packages, provides):
    start = {
        n
        for n, f in packages.items()
        if f.get("Priority") in ("required", "important", "standard") or f.get("Essential") == "yes"
    }
    start.update(n for n in scraped_base() if n in packages)
    return closure(start, packages, provides)


# ── Resolve ─────────────────────────────────────────────────────────────────
def resolve(names, mirror):
    problems, targets = [], []
    for name in names:
        if not NAME_RE.match(name):
            problems.append("packages.apt: '%s' is not a Debian package name" % name)
    if problems:
        raise AptError("\n".join(problems))
    paths, codename_used = index_files(mirror)
    packages, provides = parse(paths)
    for name in names:
        if name in packages:
            targets.append(name)
        elif len(provides.get(name, [])) == 1:
            targets.append(provides[name][0])
        elif provides.get(name):
            problems.append(
                "packages.apt: '%s' is a virtual package with several providers -- "
                "name one: %s" % (name, ", ".join(sorted(provides[name])))
            )
        else:
            close = difflib.get_close_matches(name, list(packages), n=3, cutoff=0.75)
            problems.append(
                "packages.apt: '%s' is not in Debian %s%s"
                % (name, codename_used, " -- did you mean %s?" % ", ".join(close) if close else "")
            )
    if problems:
        raise AptError("\n".join(problems))
    base = installed_base(packages, provides)
    new = closure(targets, packages, provides, have=base)
    installed_kib = sum(int(packages[n].get("Installed-Size", "0") or 0) for n in new)
    download_b = sum(int(packages[n].get("Size", "0") or 0) for n in new)
    root_mb = -(-installed_kib // 1024)
    var_mb = -(-download_b // (1024 * 1024))
    return targets, root_mb, var_mb, len(new)


def record_path():
    return os.path.join(cache_root(), "last-resolve")


def main(argv):
    if len(argv) < 1 or argv[0] not in ("resolve", "cached"):
        sys.stderr.write("usage: b2b_apt.py resolve|cached PKG...\n")
        return 2
    mode, names = argv[0], argv[1:]
    key = " ".join(sorted(names))
    if mode == "cached":
        try:
            with open(record_path(), encoding="utf-8") as fh:
                lines = fh.read().splitlines()
            if lines and lines[0] == key:
                sys.stdout.write("\n".join(lines[1:3]) + "\n")
        except OSError:
            pass
        return 0
    if not names:
        sys.stdout.write("root_mb 0\nvar_mb 0\nclosure 0\n")
        return 0
    mirror = os.environ.get("B2B_APT_MIRROR") or "deb.debian.org"
    try:
        targets, root_mb, var_mb, count = resolve(names, mirror)
    except AptError as exc:
        sys.stderr.write("%s\n" % exc)
        return 1
    for target in targets:
        sys.stdout.write("package %s\n" % target)
    sys.stdout.write("root_mb %d\nvar_mb %d\nclosure %d\n" % (root_mb, var_mb, count))
    # A fixture index is not the mirror: its answer is recorded only when the
    # test also gave a cache directory of its own.
    if not os.environ.get("B2B_APT_INDEX") or os.environ.get("B2B_APT_CACHE"):
        try:
            os.makedirs(cache_root(), exist_ok=True)
            with open(record_path(), "w", encoding="utf-8") as fh:
                fh.write("%s\nroot_mb %d\nvar_mb %d\n" % (key, root_mb, var_mb))
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
