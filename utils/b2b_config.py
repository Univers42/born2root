#!/usr/bin/env python3
"""born2root.toml, read here and nowhere else.

The VM's identity, accounts, packages, policies and disk used to be typed by
hand into ~40 places: the preseed, both guest scripts, eight provisioners,
seven host scripts. A flat `KEY=value` file pulled that into one place but no
further: the extra accounts were a single string with no room for a key, a
group or an editor setup, packages could not be added, and the policies stayed
hardcoded. This reads the structured file, and every consumer asks it.

Two contracts the callers depend on, both learned the hard way:

  * `get KEY` never fails and never writes to stderr. The Makefile calls it at
    parse time for every target, `make help` included, and it must answer even
    when the file is invalid -- which is why nothing in `get`'s path validates.
  * a value is never interpreted. Passwords and crypt hashes reach the preseed
    through an index/substr splice (see render), so $ & \\ / in a value stay
    themselves, and the template's own $(list-devices ...) is never touched.

Precedence, the same everywhere: VM_PASS in the environment beats
system.luks_passphrase -- for the preseed AND for the host's unlock, so the
two cannot disagree.

Usage (utils/b2b_config.sh is the shell face of this and keeps the old
function names):

  b2b_config.py get KEY          one resolved value; always exit 0, silent.
                                 KEY is a legacy B2B_* name or a dotted path
                                 (vm.name, users.bob.sudo)
  b2b_config.py --check          validate; exit 1 naming every problem
  b2b_config.py --parses         exit 1 if the TOML itself is unreadable, so a
                                 typo cannot let `make destroy` fall back to a
                                 literal VM name
  b2b_config.py --show           resolved values, for humans
  b2b_config.py --dump           resolved values as JSON (tests, debugging)
  b2b_config.py --volumes        "name mount floor share cap" lines
  b2b_config.py --guest          /etc/b2b/build.conf body (no password)
  b2b_config.py --users          "name:fullname:groups" per account
  b2b_config.py --shadow         "name:$6$..." per extra account, "name:!"
                                 when it has no password
  b2b_config.py --ssh-keys       "name key..." lines, paths already read
  b2b_config.py --render FILE     FILE with every @B2B_KEY@ filled in

Env: B2B_CONFIG (born2root.toml at the repo root; the tests point it at
fixtures), VM_PASS, B2B_TOML_VENDORED=1 (force the vendored parser).
"""

from __future__ import annotations

import base64
import binascii
import difflib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CONFIG = os.environ.get("B2B_CONFIG") or os.path.join(ROOT, "born2root.toml")


def toml_module():
    """tomllib (Python >= 3.11), else the vendored tomli it grew out of.

    42's Ubuntu 22.04 ships Python 3.10, which has no tomllib; utils/vendor
    holds the same parser (tomli 2.4.1, MIT). B2B_TOML_VENDORED=1 forces the
    vendored path so the tests cover it on a newer Python too.
    """
    if not os.environ.get("B2B_TOML_VENDORED"):
        try:
            import tomllib

            return tomllib
        except ImportError:
            pass
    if os.path.join(HERE, "vendor") not in sys.path:
        sys.path.insert(0, os.path.join(HERE, "vendor"))
    import tomli

    return tomli


# ── Defaults ────────────────────────────────────────────────────────────────
# Every key the file may hold, with the value that applies when it is absent.
# None means "no default, the file must say": only the secrets, so a build can
# never quietly use a password nobody chose.
VOLUME_KEYS = ("name", "mount", "floor_mb", "share", "cap_mb")
DEFAULT_VOLUMES = [
    {"name": "root", "mount": "/", "floor_mb": 2816, "share": 25, "cap_mb": 30720},
    {"name": "home", "mount": "/home", "floor_mb": 512, "share": 18, "cap_mb": 102400},
    {"name": "opt", "mount": "/opt", "floor_mb": 256, "share": 5, "cap_mb": 20480},
    {"name": "srv", "mount": "/srv", "floor_mb": 256, "share": 0, "cap_mb": 10240},
    {"name": "tmp", "mount": "/tmp", "floor_mb": 256, "share": 3, "cap_mb": 10240},
    {"name": "var-log", "mount": "/var/log", "floor_mb": 384, "share": 3, "cap_mb": 20480},
    {"name": "var", "mount": "/var", "floor_mb": 2048, "share": "rest"},
]

DEFAULTS = {
    "vm": {
        "name": "debian",
        "backend": "auto",
        "disk_gb": 15,
        "ram_mb": "auto",
        "cpus": "auto",
        "profile": "auto",
        "ai_mode": "off",
    },
    "system": {
        "hostname": "",
        "locale": "en_US.UTF-8",
        "keymap": "es",
        "timezone": "Europe/Madrid",
        "mirror": "deb.debian.org",
        "root_password": None,
        "luks_passphrase": None,
    },
    # Models served from THIS host to opencode in the guest, by llama.cpp
    # (setup/host/llm_host.sh). $USER in models_dir is the host login, so the
    # tracked file names no one.
    "ai": {
        "host_models": False,
        "models": ["unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q3_K_XL"],
        "models_dir": "/sgoinfre/students/$USER/llm",
        "budget_gb": 15,
        "llama_cpp": "b10970",
        "gpu": "auto",
        "context": 32768,
        "bind": "127.0.0.1:8012",
        "expose": False,
    },
    "packages": {"apt": []},
    "network": {"forwards": []},
    # [dc]: what the datacenter profile hands the platform provisioner.
    # cors_origins: browser origins Kong must answer preflights for, beside
    # grobase's own defaults (a test lab or a teammate's frontend on another
    # port). Origins only -- scheme://host[:port] -- because the value lands
    # in build.conf (sourced) and in kong.yml (YAML list item).
    # package: grobase's service tier. "auto" derives it from the dc-* features
    # (pro for dc-full); "max" adds analytics and functions, which no feature
    # asks for, so it can only be chosen here.
    "dc": {"cors_origins": [], "package": "auto"},
    "disk": {"swap_mb": "auto", "volumes": DEFAULT_VOLUMES},
    "policy": {
        "password": {
            "max_days": 30,
            "min_days": 2,
            "warn_days": 7,
            "min_length": 10,
            "min_upper": 1,
            "min_lower": 1,
            "min_digit": 1,
            "max_repeat": 3,
            "min_changed": 7,
        },
        "sudo": {
            "tries": 3,
            "badpass_message": "Wrong password. Access denied!",
            "log_dir": "/var/log/sudo",
        },
        "ssh": {"password_login": True},
        "monitoring": {"interval_min": 10},
    },
}
# The first account is the one d-i creates: sudo and the editor setup are not
# optional for it (make verify_guest and make nvim both target it).
USER_DEFAULTS = {
    "password": None,
    "fullname": "",
    "sudo": False,
    "groups": [],
    "ssh_keys": [],
    "nvim": False,
}
FORWARD_KEYS = ("name", "guest", "host")

# What the subject fixes. A stricter value is welcome, a weaker one is not:
# (key, "min"|"max", bound, what the rule is).
PASSWORD_FLOORS = (
    ("max_days", "max", 30, "the subject wants a password to expire every 30 days at most"),
    ("min_days", "min", 2, "the subject wants at least 2 days between changes"),
    ("warn_days", "min", 7, "the subject wants 7 days of warning at least"),
    ("min_length", "min", 10, "the subject wants 10 characters at least"),
    ("min_upper", "min", 1, "the subject wants an uppercase letter"),
    ("min_lower", "min", 1, "the subject wants a lowercase letter"),
    ("min_digit", "min", 1, "the subject wants a digit"),
    ("max_repeat", "max", 3, "the subject allows 3 identical characters in a row at most"),
    ("min_changed", "min", 7, "the subject wants 7 characters not in the old password"),
)
MONITOR_INTERVALS = (1, 2, 3, 4, 5, 6, 10)


# ── Reading ─────────────────────────────────────────────────────────────────
class ConfigError(Exception):
    """The file cannot be read at all: missing, or not TOML."""


def read_raw(path=None):
    """The file as nested dicts. Raises ConfigError with the TOML line."""
    path = path or CONFIG
    if not os.path.isfile(path):
        raise ConfigError(
            "%s is missing. Restore it: git checkout born2root.toml" % path
        )
    tomllib = toml_module()
    try:
        with open(path, "rb") as fh:
            return tomllib.load(fh)
    except OSError as exc:
        raise ConfigError("%s cannot be read: %s" % (path, exc))
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(
            "%s is not valid TOML: %s\n"
            "  (strings need quotes, lists look like [ \"a\", \"b\" ], "
            "comments start with #)" % (path, exc)
        )


def _merge(defaults, given, section, errors):
    """defaults overlaid with given, refusing a key nobody knows."""
    out = dict(defaults)
    for key, value in (given or {}).items():
        if key not in defaults:
            errors.append((_where(section, key), _unknown(key, defaults)))
            continue
        out[key] = value
    return out


def _where(section, key):
    return "%s.%s" % (section, key) if section else key


def _unknown(key, known):
    near = difflib.get_close_matches(key, list(known), n=1)
    hint = " (did you mean %s?)" % near[0] if near else ""
    return "unknown key%s. Known here: %s" % (hint, ", ".join(sorted(known)))


class Config:
    """The resolved file: defaults applied, nothing validated yet.

    Resolving never fails on a value, so `get` can answer from a file that
    --check would refuse. validate() is what judges it.
    """

    def __init__(self, raw, path=None):
        self.path = path or CONFIG
        self.errors = []  # (path, message) -- from resolving: unknown keys
        self.warnings = []
        known = set(DEFAULTS) | {"users", "features"}
        for key in raw:
            if key not in known:
                self.errors.append((key, _unknown(key, known)))
        self.vm = _merge(DEFAULTS["vm"], raw.get("vm"), "vm", self.errors)
        self.system = _merge(
            DEFAULTS["system"], raw.get("system"), "system", self.errors
        )
        self.ai = _merge(DEFAULTS["ai"], raw.get("ai"), "ai", self.errors)
        self.packages = _merge(
            DEFAULTS["packages"], raw.get("packages"), "packages", self.errors
        )
        self.network = _merge(
            DEFAULTS["network"], raw.get("network"), "network", self.errors
        )
        self.dc = _merge(DEFAULTS["dc"], raw.get("dc"), "dc", self.errors)
        self.disk = _merge(DEFAULTS["disk"], raw.get("disk"), "disk", self.errors)
        self.policy = {}
        given_policy = raw.get("policy") or {}
        if not isinstance(given_policy, dict):
            self.errors.append(("policy", "policy is a section: [policy.password]"))
            given_policy = {}
        for name, defaults in DEFAULTS["policy"].items():
            self.policy[name] = _merge(
                defaults, given_policy.get(name), "policy." + name, self.errors
            )
        for name in given_policy:
            if name not in DEFAULTS["policy"]:
                self.errors.append(
                    ("policy." + name, _unknown(name, DEFAULTS["policy"]))
                )
        self.features = dict(raw.get("features") or {})
        self.users = self._users(raw.get("users"))

    def _users(self, given):
        """[users.<name>] tables, in file order, each with its defaults."""
        users = []
        if given is None:
            return users
        if isinstance(given, list):
            self.errors.append(
                (
                    "users",
                    'write one section per account, [users.bob], not [[users]]',
                )
            )
            return users
        if not isinstance(given, dict):
            self.errors.append(("users", "write one section per account: [users.bob]"))
            return users
        for name, fields in given.items():
            if not isinstance(fields, dict):
                self.errors.append(
                    ("users." + name, "write the account as a section: [users.%s]" % name)
                )
                continue
            if "shell" in fields:
                self.errors.append(
                    (
                        "users.%s.shell" % name,
                        "hellish is the login shell of every account in every "
                        "build; it cannot be set per account",
                    )
                )
                fields = {k: v for k, v in fields.items() if k != "shell"}
            user = _merge(USER_DEFAULTS, fields, "users." + name, self.errors)
            user["name"] = name
            user["given"] = set(fields)
            users.append(user)
        return users

    # ── Derived values ──────────────────────────────────────────────────────
    @property
    def login(self):
        return self.users[0]["name"] if self.users else ""

    @property
    def hostname(self):
        return self.system.get("hostname") or "%s42" % self.login

    @property
    def fullname(self):
        first = self.users[0] if self.users else {}
        return first.get("fullname") or self.login

    def fullname_of(self, user):
        """GECOS for any account: the login when nothing was given.

        Never empty: an empty `passwd/user-fullname` makes d-i ask the question
        on a screen nobody watches, and `useradd -c ''` loses the field.
        """
        return user.get("fullname") or user["name"]

    @property
    def luks_passphrase(self):
        """VM_PASS first: the ISO and the unlock must agree."""
        env = os.environ.get("VM_PASS")
        if env:
            return env
        return self.system.get("luks_passphrase") or ""

    @property
    def user_password(self):
        return (self.users[0].get("password") if self.users else "") or ""

    def is_first(self, user):
        return bool(self.users) and user is self.users[0]

    def nvim_users(self):
        return [u["name"] for u in self.users if u is self.users[0] or u.get("nvim")]

    def groups_of(self, user):
        """Every group but the primary one: user42 always, sudo when asked."""
        groups = ["user42"]
        if user.get("sudo") or self.is_first(user):
            groups.append("sudo")
        for group in user.get("groups") or []:
            if isinstance(group, str) and group not in groups:
                groups.append(group)
        return groups

    def volumes(self):
        """The table, / first and the `rest` volume last: emission order."""
        vols = [v for v in self.disk.get("volumes") or [] if isinstance(v, dict)]
        root = [v for v in vols if v.get("mount") == "/"]
        rest = [v for v in vols if str(v.get("share")) == "rest" and v not in root]
        others = [v for v in vols if v not in root and v not in rest]
        return root + others + rest

    def forwards(self):
        return [f for f in self.network.get("forwards") or [] if isinstance(f, dict)]

    def locale_language(self):
        return (self.system.get("locale") or "").split("_")[0]

    def locale_country(self):
        locale = self.system.get("locale") or ""
        return locale.split("_")[-1].split(".")[0] if "_" in locale else ""

    def feature_tokens(self):
        """[features] as the +name/-name string FEATURES has always taken."""
        out = []
        for name, value in self.features.items():
            if value is True:
                out.append("+%s" % name)
            elif value is False:
                out.append("-%s" % name)
        return " ".join(out)


def load(path=None):
    return Config(read_raw(path), path)


# ── The feature manifest, read where it lives ───────────────────────────────
# generate/feature_profile.sh owns the list; feature_select.sh already scrapes
# the same literal rather than keeping a second copy, and so does this.
def manifest():
    """{name: tier} and the rows that are space reservations, not installs."""
    rows, not_installed = {}, set()
    path = os.path.join(ROOT, "generate", "feature_profile.sh")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return rows, not_installed
    block = re.search(r"MANIFEST='\n(.*?)'\n", text, re.S)
    if block:
        for line in block.group(1).splitlines():
            fields = line.split()
            if len(fields) == 7:
                rows[fields[0]] = fields[1]
    spaces = re.search(r"NOT_INSTALLED='([^']*)'", text)
    if spaces:
        not_installed = set(spaces.group(1).split())
    return rows, not_installed


def bundles():
    """The bundle names feature_profile.sh expands (dc-minimal ...): legal in
    [features] like a row, priced as their members."""
    path = os.path.join(ROOT, "generate", "feature_profile.sh")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return set()
    block = re.search(r"BUNDLES='\n(.*?)'\n", text, re.S)
    if not block:
        return set()
    return {line.split()[0] for line in block.group(1).splitlines() if len(line.split()) >= 2}


# Ports already forwarded or opened, read from the scripts that own them, so
# this is not a fourth copy of a list that drifts.
def builtin_ports():
    guest = {4242}
    qemu = os.path.join(ROOT, "setup", "host", "qemu_vm.sh")
    first_boot = os.path.join(ROOT, "preseeds", "first-boot-setup.sh")
    try:
        with open(qemu, "r", encoding="utf-8", errors="replace") as fh:
            spec = re.search(r'PORTS_SPEC="\$\{PORTS_SPEC:-([^"]*)\}"', fh.read())
        if spec:
            for token in spec.group(1).split():
                parts = token.split(":")
                if len(parts) == 3 and parts[2].isdigit():
                    guest.add(int(parts[2]))
    except OSError:
        pass
    try:
        with open(first_boot, "r", encoding="utf-8", errors="replace") as fh:
            opened = re.search(r"for p in ((?:\d+ ?)+)", fh.read())
        if opened:
            guest.update(int(p) for p in opened.group(1).split())
    except OSError:
        pass
    # VirtualBox's rule set is its own list, in the orchestrator's argument
    # order (name guest host); a guest port only it forwards is still taken.
    orchestrate = os.path.join(ROOT, "generate", "orchestrate.sh")
    try:
        with open(orchestrate, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for m in re.finditer(r"^\s*ensure_vm_nat_forward [a-z0-9-]+ (\d+) ", text, re.M):
            guest.add(int(m.group(1)))
        # Inception's FTP passive range is a loop, not a line per port.
        passive = re.search(r"for _p in ((?:\d+ ?)+); do\s+ensure_vm_nat_forward", text)
        if passive:
            guest.update(int(p) for p in passive.group(1).split())
    except OSError:
        pass
    return guest


def builtin_forward_names():
    """Every rule name the three forward lists already use.

    VirtualBox refuses a second NAT rule with an existing name, and QEMU's
    ports.env is keyed by it, so a config forward called "vault" would either
    fail the VM's creation or overwrite a built-in port's record.
    """
    names = set()
    sources = (
        ("setup/host/qemu_vm.sh", r'PORTS_SPEC="\$\{PORTS_SPEC:-([^"]*)\}"', True),
        ("setup/install/vms/install_vm_debian.sh", r"^add_natpf ([a-z0-9-]+) ", False),
        ("generate/orchestrate.sh", r"^\s*ensure_vm_nat_forward ([a-z0-9-]+) ", False),
    )
    for rel, pattern, is_spec in sources:
        try:
            with open(os.path.join(ROOT, rel), "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        if is_spec:
            spec = re.search(pattern, text)
            if spec:
                names.update(t.split(":")[0] for t in spec.group(1).split())
        else:
            names.update(m.group(1) for m in re.finditer(pattern, text, re.M))
    return names


# ── Validation ──────────────────────────────────────────────────────────────
LOGIN_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
GROUP_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
MIRROR_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")
LOCALE_RE = re.compile(r"^[a-z]{2,3}_[A-Z]{2}(\.[A-Za-z0-9-]+)?$")
KEYMAP_RE = re.compile(r"^[a-z][a-z0-9-]*$")
TZ_RE = re.compile(r"^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$")
VOLNAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")
MOUNT_RE = re.compile(r"^(/[a-z0-9_.-]+)+$")
VMNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
# A Hugging Face GGUF repository and a quantization, as llama.cpp's -hf spells it.
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*:[A-Za-z0-9._-]+$")
RELEASE_RE = re.compile(r"^b[0-9]+$")
BIND_RE = re.compile(r"^([A-Za-z0-9.-]+|\[[0-9a-fA-F:]+\]):([0-9]{1,5})$")
PKG_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]+$")
FWNAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")
PASSPHRASE_RE = re.compile(r"^[A-Za-z0-9._,/=+!@#$%&*?:;-]{8,}$")
KEY_TYPES = (
    "ssh-ed25519",
    "ssh-rsa",
    "ssh-dss",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com",
    "sk-ecdsa-sha2-nistp256@openssh.com",
)


class Validator:
    def __init__(self, config):
        self.c = config
        self.errors = list(config.errors)
        self.warnings = list(config.warnings)

    def err(self, where, message):
        self.errors.append((where, message))

    def warn(self, message):
        self.warnings.append(message)

    def _int(self, where, value, low=None, high=None, what="a whole number"):
        if isinstance(value, bool) or not isinstance(value, int):
            self.err(where, "%r is not %s (no quotes around it)" % (value, what))
            return None
        if low is not None and value < low:
            self.err(where, "%d is below %d" % (value, low))
            return None
        if high is not None and value > high:
            self.err(where, "%d is above %d" % (value, high))
            return None
        return value

    def _str(self, where, value):
        if not isinstance(value, str):
            self.err(where, "%r is not text (it needs quotes)" % (value,))
            return None
        if "\n" in value:
            self.err(where, "a value cannot contain a line break")
            return None
        return value

    def _list(self, where, value):
        if not isinstance(value, list):
            self.err(where, "%r is not a list (it looks like [ \"a\", \"b\" ])" % (value,))
            return None
        return value

    def _bool(self, where, value):
        if not isinstance(value, bool):
            self.err(where, "%r is not true or false" % (value,))
            return None
        return value

    # ── sections ────────────────────────────────────────────────────────────
    def vm(self):
        vm = self.c.vm
        if self._str("vm.name", vm["name"]) and not VMNAME_RE.match(vm["name"]):
            self.err("vm.name", "letters, digits, _ . and - only")
        if vm["backend"] not in ("auto", "virtualbox", "qemu"):
            self.err("vm.backend", "auto, virtualbox or qemu")
        self._int("vm.disk_gb", vm["disk_gb"], low=8, what="a whole number of GB")
        if vm["ram_mb"] != "auto":
            self._int("vm.ram_mb", vm["ram_mb"], low=512, what='"auto" or MB')
        if vm["cpus"] != "auto":
            self._int("vm.cpus", vm["cpus"], low=1, what='"auto" or a core count')
        if vm["profile"] not in ("auto", "minimal", "standard", "full"):
            self.err("vm.profile", "auto, minimal, standard or full")
        if vm["ai_mode"] not in ("off", "client", "local"):
            self.err("vm.ai_mode", "off, client or local")

    def ai(self):
        """[ai]: judged here, before `make all` downloads or starts anything."""
        ai = self.c.ai
        self._bool("ai.host_models", ai["host_models"])
        self._bool("ai.expose", ai["expose"])
        models = self._list("ai.models", ai["models"])
        if models is not None:
            if not models:
                self.err(
                    "ai.models",
                    'name at least one, e.g. ["unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q3_K_XL"]',
                )
            for model in models:
                if not isinstance(model, str) or not MODEL_RE.match(model):
                    self.err(
                        "ai.models",
                        "%r is not owner/repo:QUANT, a Hugging Face GGUF repository "
                        "and a quantization" % (model,),
                    )
        self._int("ai.budget_gb", ai["budget_gb"], low=1, high=1000, what="a whole number of GB")
        if self._str("ai.llama_cpp", ai["llama_cpp"]) and not RELEASE_RE.match(ai["llama_cpp"]):
            self.err("ai.llama_cpp", "a llama.cpp release tag, e.g. b10970")
        if ai["gpu"] not in ("auto", "vulkan", "cpu"):
            self.err("ai.gpu", "auto, vulkan or cpu")
        self._int("ai.context", ai["context"], low=4096, high=262144, what="a number of tokens")
        where = ai["models_dir"]
        if self._str("ai.models_dir", where):
            if where.startswith("~") or where.startswith("$HOME"):
                self.err(
                    "ai.models_dir",
                    "not in your home: /home is a small quota a model fills; "
                    "use /sgoinfre/students/$USER/llm",
                )
            elif not where.startswith("/"):
                self.err("ai.models_dir", "an absolute path, e.g. /sgoinfre/students/$USER/llm")
            elif "/disk_images/" in where + "/":
                self.err("ai.models_dir", "not inside a disk_images directory, which make fclean empties")
        bind = ai["bind"]
        if self._str("ai.bind", bind):
            match = BIND_RE.match(bind)
            if not match or not 1 <= int(match.group(2)) <= 65535:
                self.err("ai.bind", "host:port, e.g. 127.0.0.1:8012")
            elif (
                not re.match(r"^(127\.|localhost$|\[::1\]$)", match.group(1))
                and ai["expose"] is not True
            ):
                self.err(
                    "ai.bind",
                    "%s puts the model server on the network; the VM needs "
                    "only 127.0.0.1 (set ai.expose = true if you mean it)" % bind,
                )

    def system(self):
        sys_ = self.c.system
        host = self._str("system.hostname", sys_["hostname"])
        if host is not None and host and not HOST_RE.match(host):
            self.err(
                "system.hostname",
                "lowercase letters, digits and - (63 at most)",
            )
        elif host is not None and host and host != "%s42" % self.c.login:
            self.warn(
                "system.hostname=%s -- the subject wants %s42 (leave it empty "
                "for that)" % (host, self.c.login)
            )
        for key in ("root_password", "luks_passphrase"):
            value = sys_[key]
            if value is None:
                self.err(
                    "system." + key,
                    "is missing, and it has no default: add a line for it",
                )
                continue
            if self._str("system." + key, value) is None:
                continue
            if not value:
                self.err("system." + key, "is empty")
        passphrase = self.c.luks_passphrase
        if passphrase and not PASSPHRASE_RE.match(passphrase):
            source = "VM_PASS" if os.environ.get("VM_PASS") else "system.luks_passphrase"
            self.err(
                source,
                "8 characters or more, from letters, digits and "
                "- _ . , / = + ! @ # $ % & * ? : ; -- this machine types it "
                "into the guest key by key",
            )
        locale = self._str("system.locale", sys_["locale"])
        if locale and not LOCALE_RE.match(locale):
            self.err("system.locale", "something like en_US.UTF-8")
        keymap = self._str("system.keymap", sys_["keymap"])
        if keymap and not KEYMAP_RE.match(keymap):
            self.err("system.keymap", "a d-i keymap name such as es, us, fr, de")
        tz = self._str("system.timezone", sys_["timezone"])
        if tz:
            zoneinfo = "/usr/share/zoneinfo"
            if os.path.isdir(zoneinfo):
                if not os.path.isfile(os.path.join(zoneinfo, tz)):
                    self.err(
                        "system.timezone",
                        "not in %s (Area/City, e.g. Europe/Madrid)" % zoneinfo,
                    )
            elif not TZ_RE.match(tz):
                self.err("system.timezone", "Area/City, e.g. Europe/Madrid")
        mirror = self._str("system.mirror", sys_["mirror"])
        if mirror and not MIRROR_RE.match(mirror):
            self.err("system.mirror", "a host name only, such as deb.debian.org")

    def users(self):
        if not self.c.users:
            self.err(
                "users",
                "no account: add [users.<your 42 login>] with a password. The "
                "first one is the account the installer creates",
            )
            return
        seen = set()
        for user in self.c.users:
            name = user["name"]
            where = "users." + name
            if name == "root" or not LOGIN_RE.match(name):
                self.err(
                    where,
                    "a login is lowercase letters, digits, _ and - (32 at "
                    "most), and not root",
                )
            if name in seen:
                self.err(where, "this account is listed twice")
            seen.add(name)
            first = self.c.is_first(user)
            password = user["password"]
            if password is None:
                if first:
                    self.err(
                        where + ".password",
                        "your own account needs a password: the installer "
                        "sets it, and `ssh b2b` and sudo use it",
                    )
                else:
                    self.err(
                        where + ".password",
                        'is missing. Use "" for an account that is locked '
                        "until `sudo passwd %s`" % name,
                    )
            elif self._str(where + ".password", password) is not None:
                if first and not password:
                    self.err(
                        where + ".password",
                        "cannot be empty for your own account: the installer "
                        "needs it, and so do `ssh b2b` and sudo",
                    )
            fullname = self._str(where + ".fullname", user["fullname"])
            if fullname and (":" in fullname or "," in fullname):
                self.err(
                    where + ".fullname",
                    "no : or , (useradd reads them as field separators)",
                )
            sudo = self._bool(where + ".sudo", user["sudo"])
            if sudo is False and first:
                self.err(
                    where + ".sudo",
                    "your own account is in sudo in every build: the subject "
                    "asks for it, and the host provisions the VM through it",
                )
            if sudo and password == "":
                self.warn(
                    "%s has sudo but no password, so it cannot use it until "
                    "you run `sudo passwd %s` in the guest" % (name, name)
                )
            nvim = self._bool(where + ".nvim", user["nvim"])
            # The login always gets the editor -- unless the build has none:
            # nvim is core, and a server profile turns it off for everyone
            # with features.nvim = false. Then the account flag is moot.
            if nvim is False and first and self.c.features.get("nvim") is not False:
                self.err(
                    where + ".nvim",
                    "your own account always gets the editor setup while the "
                    "build has one; to build without an editor at all, set "
                    "nvim = false under [features]",
                )
            groups = self._list(where + ".groups", user["groups"])
            for i, group in enumerate(groups or []):
                at = "%s.groups[%d]" % (where, i)
                if self._str(at, group) is None:
                    continue
                if group == "sudo":
                    self.err(at, "write sudo = true instead")
                elif group == "user42":
                    self.err(at, "every account is in user42 already")
                elif group == "root":
                    self.err(at, "the root group is not handed out")
                elif not GROUP_RE.match(group):
                    self.err(at, "a group name is lowercase letters, digits, _ and -")
            keys = self._list(where + ".ssh_keys", user["ssh_keys"])
            for i, key in enumerate(keys or []):
                self.ssh_key("%s.ssh_keys[%d]" % (where, i), key)

    def ssh_key(self, where, value):
        if self._str(where, value) is None:
            return
        value = value.strip()
        if not value:
            self.err(where, "is empty")
            return
        if value.split()[0] not in KEY_TYPES:
            path = os.path.expanduser(value)
            if not os.path.isabs(path) and not value.startswith(("~", ".")):
                self.err(
                    where,
                    "neither a public key (it starts with %s) nor a path to "
                    "a .pub file on this machine"
                    % ", ".join(KEY_TYPES[:3]),
                )
                return
            if not os.path.isfile(path):
                self.err(where, "no such file on this machine: %s" % path)
                return
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    value = fh.readline().strip()
            except OSError as exc:
                self.err(where, "cannot be read: %s" % exc)
                return
            if not value or value.split()[0] not in KEY_TYPES:
                self.err(where, "%s does not hold a public key" % path)
                return
        fields = value.split()
        if len(fields) < 2:
            self.err(where, "a public key is '<type> <base64> [comment]'")
            return
        kind, blob = fields[0], fields[1]
        try:
            raw = base64.b64decode(blob, validate=True)
        except (binascii.Error, ValueError):
            self.err(where, "the key itself is not valid base64")
            return
        # An OpenSSH blob starts with its own algorithm name, length-prefixed.
        # Checking it catches a key pasted with a line break in the middle,
        # which authorized_keys would silently ignore.
        if len(raw) < 4:
            self.err(where, "the key is truncated")
            return
        length = int.from_bytes(raw[:4], "big")
        # The algorithm name has to be there AND be followed by key material:
        # "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5" decodes to exactly the name, which
        # is what a key wrapped over two lines looks like after the first line.
        if (
            len(raw) <= 4 + length
            or raw[4 : 4 + length].decode("ascii", "replace") != kind
        ):
            self.err(
                where,
                "says %s but the key itself does not -- it looks truncated or "
                "wrapped over two lines" % kind,
            )

    def features(self):
        rows, not_installed = manifest()
        known_bundles = bundles()
        for name, value in self.c.features.items():
            where = "features." + name
            if value == "auto":
                continue
            if not isinstance(value, bool):
                self.err(where, '"auto", true or false')
                continue
            if name in known_bundles:
                continue
            if name in ("hellish", "hellish-upstream"):
                self.err(
                    where,
                    "hellish is the shell of every account in every build, "
                    "not a feature: there is nothing to switch",
                )
            elif name in not_installed:
                self.err(
                    where,
                    "is space the disk check reserves for what you will put "
                    "there yourself, not something the build installs",
                )
            elif name.startswith("ai-"):
                self.err(where, "set vm.ai_mode to client or local instead")
            elif name not in rows:
                self.err(where, _unknown(name, rows) if rows else "unknown feature")
            elif rows[name] == "base" and value is False:
                self.err(
                    where,
                    "is part of the base every build needs (the subject, the "
                    "scripts or `make verify_guest` rely on it)",
                )

    def packages(self):
        apt = self._list("packages.apt", self.c.packages["apt"])
        seen = set()
        for i, name in enumerate(apt or []):
            where = "packages.apt[%d]" % i
            if self._str(where, name) is None:
                continue
            if not PKG_RE.match(name):
                self.err(
                    where,
                    "'%s' is not a Debian package name (lowercase letters, "
                    "digits and + - .)" % name,
                )
            elif name in seen:
                self.err(where, "'%s' is listed twice" % name)
            seen.add(name)

    def policy(self):
        pw = self.c.policy["password"]
        for key, kind, bound, why in PASSWORD_FLOORS:
            value = self._int("policy.password." + key, pw[key], low=0)
            if value is None:
                continue
            if kind == "min" and value < bound:
                self.err("policy.password." + key, "%s (you set %d)" % (why, value))
            if kind == "max" and value > bound:
                self.err("policy.password." + key, "%s (you set %d)" % (why, value))
        if pw["min_days"] and pw["max_days"] and pw["min_days"] >= pw["max_days"]:
            self.err(
                "policy.password.min_days",
                "cannot be at or above max_days (%d): nobody could ever change "
                "their password" % pw["max_days"],
            )
        sudo = self.c.policy["sudo"]
        self._int("policy.sudo.tries", sudo["tries"], low=1, high=3)
        message = self._str("policy.sudo.badpass_message", sudo["badpass_message"])
        if message is not None:
            if not message:
                self.err("policy.sudo.badpass_message", "is empty")
            bad = [ch for ch in "'\"\\`$" if ch in message]
            if bad:
                self.err(
                    "policy.sudo.badpass_message",
                    "cannot contain %s: it goes into /etc/sudoers.d, where "
                    "those would be read as syntax" % " ".join(bad),
                )
        log_dir = self._str("policy.sudo.log_dir", sudo["log_dir"])
        if log_dir is not None and not MOUNT_RE.match(log_dir):
            self.err(
                "policy.sudo.log_dir",
                "an absolute path of lowercase letters, digits, _ . and -",
            )
        self._bool("policy.ssh.password_login", self.c.policy["ssh"]["password_login"])
        if self.c.policy["ssh"]["password_login"] is False and not self._has_key():
            self.err(
                "policy.ssh.password_login",
                "false with no key for %s would lock you out: add one to "
                "users.%s.ssh_keys, or create ~/.ssh/id_ed25519 on this "
                "machine" % (self.c.login, self.c.login),
            )
        interval = self.c.policy["monitoring"]["interval_min"]
        if self._int("policy.monitoring.interval_min", interval, low=1, high=60):
            if interval not in MONITOR_INTERVALS:
                self.err(
                    "policy.monitoring.interval_min",
                    "cron repeats on %s minutes"
                    % ", ".join(str(i) for i in MONITOR_INTERVALS),
                )
            elif interval != 10:
                self.warn(
                    "policy.monitoring.interval_min=%d -- the evaluation "
                    "expects every 10 minutes" % interval
                )

    def _has_key(self):
        """Would the first account have any way in without a password?"""
        if self.c.users and self.c.users[0].get("ssh_keys"):
            return True
        return any(
            os.path.isfile(os.path.expanduser("~/.ssh/%s.pub" % name))
            for name in ("id_ed25519", "id_rsa")
        )

    DC_PACKAGES = ("auto", "basic", "essential", "pro", "max")
    ORIGIN_RE = re.compile(r"^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$")

    def dc(self):
        """[dc] cors_origins: bare origins, no path, no slash, no wildcard.

        The list is sourced by the guest (build.conf) and pasted into
        kong.yml one item per line, so anything but scheme://host[:port]
        is refused here rather than breaking Kong's declarative config at
        first boot.
        """
        origins = self._list("dc.cors_origins", self.c.dc["cors_origins"])
        seen = set()
        for i, origin in enumerate(origins or []):
            where = "dc.cors_origins[%d]" % i
            if not isinstance(origin, str) or not self.ORIGIN_RE.match(origin):
                self.err(
                    where,
                    "%r is not an origin (it looks like http://localhost:5173, "
                    "no path and no trailing slash)" % (origin,),
                )
                continue
            if origin in seen:
                self.err(where, "%s is listed twice" % origin)
            seen.add(origin)
        package = self.c.dc.get("package")
        if package not in self.DC_PACKAGES:
            self.err(
                "dc.package",
                "%r is not a grobase tier (one of: %s)" % (package, ", ".join(self.DC_PACKAGES)),
            )

    def network(self):
        forwards = self._list("network.forwards", self.c.network["forwards"])
        builtin = builtin_ports()
        builtin_names = builtin_forward_names()
        names, guests, hosts = set(), set(), set()
        for i, forward in enumerate(forwards or []):
            where = "network.forwards[%d]" % i
            if not isinstance(forward, dict):
                self.err(
                    where,
                    'looks like { name = "grafana", guest = 3100, host = 3100 }',
                )
                continue
            for key in forward:
                if key not in FORWARD_KEYS:
                    self.err("%s.%s" % (where, key), _unknown(key, dict.fromkeys(FORWARD_KEYS)))
            name = forward.get("name")
            if self._str(where + ".name", name) is None:
                pass
            elif not FWNAME_RE.match(name):
                self.err(where + ".name", "lowercase letters, digits and - only")
            elif name in names:
                self.err(where + ".name", "'%s' is used twice" % name)
            elif name in builtin_names:
                self.err(
                    where + ".name",
                    "'%s' is a forward the VM already has; pick another name" % name,
                )
            else:
                names.add(name)
            guest = self._int(where + ".guest", forward.get("guest"), low=1, high=65535)
            if guest is not None:
                if guest in builtin:
                    self.err(
                        where + ".guest",
                        "%d is forwarded by the build already (SSH, the web "
                        "stack or Inception)" % guest,
                    )
                elif guest in guests:
                    self.err(where + ".guest", "%d is forwarded twice" % guest)
                guests.add(guest)
            host = self._int(where + ".host", forward.get("host"), low=1024, high=65535)
            if host is not None and host in hosts:
                self.err(where + ".host", "%d is used twice on this machine" % host)
            if host is not None:
                hosts.add(host)

    def disk(self):
        swap = self.c.disk["swap_mb"]
        if swap != "auto":
            self._int("disk.swap_mb", swap, low=256, what='"auto" or MB')
        volumes = self._list("disk.volumes", self.c.disk["volumes"])
        if volumes is None:
            return
        if not volumes:
            self.err("disk.volumes", "the disk needs at least a / volume")
            return
        names, mounts, roots, rests, share_sum = set(), set(), 0, 0, 0
        for i, vol in enumerate(volumes):
            where = "disk.volumes[%d]" % i
            if not isinstance(vol, dict):
                self.err(
                    where,
                    'looks like { name = "home", mount = "/home", '
                    "floor_mb = 512, share = 18 }",
                )
                continue
            # The volume's own name is the address a reader recognises, so it
            # replaces the index before anything in the row is reported --
            # including an unknown key.
            name = vol.get("name")
            if isinstance(name, str) and name:
                where = "disk.volumes.%s" % name
            for key in vol:
                if key not in VOLUME_KEYS:
                    self.err(
                        "%s.%s" % (where, key), _unknown(key, dict.fromkeys(VOLUME_KEYS))
                    )
            if self._str(where + ".name", name) is None:
                pass
            elif not VOLNAME_RE.match(name) or name == "swap":
                self.err(
                    where + ".name",
                    "lowercase letters, digits and -, and not 'swap' (the "
                    "swap volume is disk.swap_mb)",
                )
            elif name in names:
                self.err(where + ".name", "'%s' is used twice" % name)
            names.add(name)
            mount = vol.get("mount")
            if self._str(where + ".mount", mount) is None:
                pass
            elif mount != "/" and not MOUNT_RE.match(mount):
                self.err(
                    where + ".mount",
                    "an absolute path of lowercase letters, digits, _ . and -",
                )
            elif mount == "/boot":
                self.err(
                    where + ".mount",
                    "/boot is a partition of its own outside LVM, not a volume",
                )
            else:
                if mount == "/":
                    roots += 1
                if mount in mounts:
                    self.err(where + ".mount", "'%s' is used twice" % mount)
                mounts.add(mount)
            floor = self._int(
                where + ".floor_mb", vol.get("floor_mb"), low=128, what="MB"
            )
            share = vol.get("share")
            if share == "rest":
                rests += 1
            else:
                value = self._int(where + ".share", share, low=0, high=100)
                if value is not None:
                    share_sum += value
            if "cap_mb" in vol:
                cap = self._int(where + ".cap_mb", vol["cap_mb"], low=1, what="MB")
                if cap is not None and floor is not None and cap < floor:
                    self.err(
                        where + ".cap_mb",
                        "%d is below the floor (%d): the volume could never "
                        "be created" % (cap, floor),
                    )
        if roots != 1:
            self.err(
                "disk.volumes",
                "exactly one volume is mounted on / (found %d)" % roots,
            )
        if rests != 1:
            self.err(
                "disk.volumes",
                'exactly one volume takes the remainder (share = "rest"); '
                "found %d" % rests,
            )
        if share_sum > 100:
            self.err("disk.volumes", "the shares add up to %d %%, more than 100" % share_sum)

    def run(self):
        self.vm()
        self.ai()
        self.system()
        self.users()
        self.features()
        self.packages()
        self.policy()
        self.network()
        self.dc()
        self.disk()
        return self.errors, self.warnings


# ── Output ──────────────────────────────────────────────────────────────────
def sh_hash(password):
    """SHA-512 crypt, what /etc/shadow and passwd/*-crypted take.

    openssl rather than Python's crypt: crypt is deprecated since 3.11 and
    gone in 3.13, and it is the one dependency this repo already checks for.
    Through stdin, so no password lands on a command line.
    """
    try:
        out = subprocess.run(
            ["openssl", "passwd", "-6", "-stdin"],
            input=password + "\n",
            capture_output=True,
            text=True,
            check=True,
        )
    except FileNotFoundError:
        raise ConfigError(
            "openssl is needed to hash the passwords (make deps installs it)"
        )
    except subprocess.CalledProcessError as exc:
        raise ConfigError("openssl could not hash a password: %s" % exc.stderr.strip())
    return out.stdout.strip()


LEGACY = {
    "B2B_LOGIN": lambda c: c.login,
    "B2B_HOSTNAME": lambda c: c.hostname,
    "B2B_FULLNAME": lambda c: c.fullname,
    "B2B_USER_PASSWORD": lambda c: c.user_password,
    "B2B_ROOT_PASSWORD": lambda c: c.system.get("root_password") or "",
    "B2B_LUKS_PASSPHRASE": lambda c: c.luks_passphrase,
    "B2B_LOCALE": lambda c: c.system.get("locale") or "",
    "B2B_LOCALE_LANGUAGE": lambda c: c.locale_language(),
    "B2B_LOCALE_COUNTRY": lambda c: c.locale_country(),
    "B2B_KEYMAP": lambda c: c.system.get("keymap") or "",
    "B2B_TIMEZONE": lambda c: c.system.get("timezone") or "",
    "B2B_MIRROR": lambda c: c.system.get("mirror") or "",
    "B2B_SWAP_MB": lambda c: c.disk.get("swap_mb"),
    "B2B_SIZE_GB": lambda c: c.vm.get("disk_gb"),
    "B2B_VM_RAM_MB": lambda c: "" if c.vm.get("ram_mb") == "auto" else c.vm.get("ram_mb"),
    "B2B_VM_CPUS": lambda c: "" if c.vm.get("cpus") == "auto" else c.vm.get("cpus"),
    "B2B_VM_NAME": lambda c: c.vm.get("name") or "",
    "B2B_BACKEND": lambda c: c.vm.get("backend") or "",
    "B2B_PROFILE": lambda c: c.vm.get("profile") or "",
    "B2B_AI_MODE": lambda c: c.vm.get("ai_mode") or "",
    "B2B_FEATURES": lambda c: c.feature_tokens(),
    "B2B_USERS": lambda c: " ".join(u["name"] for u in c.users),
    "B2B_NVIM_USERS": lambda c: " ".join(c.nvim_users()),
    "B2B_APT_PACKAGES": lambda c: " ".join(
        p for p in c.packages.get("apt") or [] if isinstance(p, str)
    ),
    # name:groups per extra account, the form the guest has always parsed.
    "B2B_EXTRA_USERS": lambda c: " ".join(
        "%s:%s" % (u["name"], ",".join(c.groups_of(u))) for u in c.users[1:]
    ),
    # name:host:guest, exactly what qemu_vm.sh's PORTS_SPEC takes.
    "B2B_FORWARDS": lambda c: " ".join(
        "%s:%s:%s" % (f.get("name"), f.get("host"), f.get("guest")) for f in c.forwards()
    ),
    "B2B_FORWARD_PORTS": lambda c: " ".join(str(f.get("guest")) for f in c.forwards()),
    "B2B_DC_CORS_ORIGINS": lambda c: " ".join(
        o for o in c.dc.get("cors_origins") or [] if isinstance(o, str)
    ),
    "B2B_DC_PACKAGE": lambda c: c.dc.get("package"),
    "B2B_PASS_MAX_DAYS": lambda c: c.policy["password"]["max_days"],
    "B2B_PASS_MIN_DAYS": lambda c: c.policy["password"]["min_days"],
    "B2B_PASS_WARN_AGE": lambda c: c.policy["password"]["warn_days"],
    "B2B_PASS_MIN_LENGTH": lambda c: c.policy["password"]["min_length"],
    "B2B_PASS_MIN_UPPER": lambda c: c.policy["password"]["min_upper"],
    "B2B_PASS_MIN_LOWER": lambda c: c.policy["password"]["min_lower"],
    "B2B_PASS_MIN_DIGIT": lambda c: c.policy["password"]["min_digit"],
    "B2B_PASS_MAX_REPEAT": lambda c: c.policy["password"]["max_repeat"],
    "B2B_PASS_MIN_CHANGED": lambda c: c.policy["password"]["min_changed"],
    "B2B_PW_MIN_LENGTH": lambda c: c.policy["password"]["min_length"],
    "B2B_PW_MIN_UPPER": lambda c: c.policy["password"]["min_upper"],
    "B2B_PW_MIN_LOWER": lambda c: c.policy["password"]["min_lower"],
    "B2B_PW_MIN_DIGIT": lambda c: c.policy["password"]["min_digit"],
    "B2B_PW_MAX_REPEAT": lambda c: c.policy["password"]["max_repeat"],
    "B2B_PW_MIN_CHANGED": lambda c: c.policy["password"]["min_changed"],
    "B2B_SUDO_TRIES": lambda c: c.policy["sudo"]["tries"],
    "B2B_SUDO_BADPASS": lambda c: c.policy["sudo"]["badpass_message"],
    "B2B_SUDO_LOG_DIR": lambda c: c.policy["sudo"]["log_dir"],
    "B2B_SSH_PASSWORD_LOGIN": lambda c: "yes"
    if c.policy["ssh"]["password_login"]
    else "no",
    "B2B_MONITOR_INTERVAL": lambda c: c.policy["monitoring"]["interval_min"],
}


def get(config, key):
    """One resolved value, or "" -- never an error, never a word on stderr."""
    if key in LEGACY:
        value = LEGACY[key](config)
    else:
        value = _dotted(config, key)
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, list):
        return " ".join(str(v) for v in value)
    return str(value)


def _dotted(config, path):
    """vm.name, users.bob.sudo, policy.sudo.tries."""
    parts = path.split(".")
    if not parts:
        return None
    head = parts[0]
    if head == "users":
        if len(parts) < 3:
            return None
        for user in config.users:
            if user["name"] == parts[1]:
                return user.get(parts[2])
        return None
    node = {
        "vm": config.vm,
        "system": config.system,
        "packages": config.packages,
        "network": config.network,
        "disk": config.disk,
        "policy": config.policy,
        "features": config.features,
        "ai": config.ai,
    }.get(head)
    for part in parts[1:]:
        if not isinstance(node, dict):
            return None
        node = node.get(part)
    return node


def volumes_view(config):
    out = []
    for vol in config.volumes():
        cap = vol.get("cap_mb")
        out.append(
            "%s %s %s %s %s"
            % (
                vol.get("name"),
                vol.get("mount"),
                vol.get("floor_mb"),
                vol.get("share"),
                "-" if cap in (None, "") else cap,
            )
        )
    return "\n".join(out)


def guest_view(config):
    """/etc/b2b/build.conf: what the guest may know. No password, ever.

    Scalars bare and lists in double quotes, the shape the guest has always
    read: b2b-setup.sh sources this file, and the sshd watchdog re-reads it
    with sed and `tr -d '"'`. Nothing here needs escaping -- every value is a
    login, a host name, a mount or a group, each already refused by --check
    unless it matches a narrow pattern. Anything that could hold arbitrary
    text (a full name, a sudo message) travels as its own file instead.
    """
    lines = [
        "# /etc/b2b/build.conf -- what this VM was built with, from",
        "# born2root.toml on the host (utils/b2b_config.py --guest).",
        "# No password is recorded here.",
    ]
    keys = (
        "B2B_LOGIN",
        "B2B_HOSTNAME",
        "B2B_MIRROR",
        "B2B_TIMEZONE",
        "B2B_LOCALE",
        "B2B_KEYMAP",
        "B2B_USERS",
        "B2B_EXTRA_USERS",
        "B2B_NVIM_USERS",
        "B2B_VOLUMES",
        # [policy.*]: numbers, yes/no, an absolute path, and a sudo message
        # --check keeps free of ' " \ ` $ and newlines, so double quotes hold it.
        "B2B_PASS_MAX_DAYS",
        "B2B_PASS_MIN_DAYS",
        "B2B_PASS_WARN_AGE",
        "B2B_PASS_MIN_LENGTH",
        "B2B_PASS_MIN_UPPER",
        "B2B_PASS_MIN_LOWER",
        "B2B_PASS_MIN_DIGIT",
        "B2B_PASS_MAX_REPEAT",
        "B2B_PASS_MIN_CHANGED",
        "B2B_SUDO_TRIES",
        "B2B_SUDO_BADPASS",
        "B2B_SUDO_LOG_DIR",
        "B2B_SSH_PASSWORD_LOGIN",
        "B2B_MONITOR_INTERVAL",
        # [network] forwards: the guest ports UFW opens.
        "B2B_FORWARD_PORTS",
        # [dc] cors_origins: what install_grobase.sh adds to kong.yml.
        "B2B_DC_CORS_ORIGINS",
        # [dc] package: the grobase tier install_grobase.sh starts.
        "B2B_DC_PACKAGE",
    )
    for key in keys:
        if key == "B2B_VOLUMES":
            value = " ".join(
                "%s:%s" % (v.get("name"), v.get("mount")) for v in config.volumes()
            )
        else:
            value = get(config, key)
        if key in (
            "B2B_USERS",
            "B2B_EXTRA_USERS",
            "B2B_NVIM_USERS",
            "B2B_VOLUMES",
            "B2B_SUDO_BADPASS",
            "B2B_FORWARD_PORTS",
            "B2B_DC_CORS_ORIGINS",
        ):
            lines.append('%s="%s"' % (key, value))
        else:
            lines.append("%s=%s" % (key, value))
    return "\n".join(lines)


def users_view(config):
    """name:fullname:groups per account, one record per line.

    Its own file rather than a build.conf variable because a full name is free
    text -- "Bob O'Hara" would end a shell string and the sshd watchdog
    re-reads build.conf with sed, so a quote there could break the loop that
    puts a changed login shell back. A `:` in a name is refused by --check,
    which is what makes the three fields readable with IFS=: alone.
    """
    out = []
    for user in config.users:
        out.append(
            "%s:%s:%s"
            % (
                user["name"],
                config.fullname_of(user),
                ",".join(config.groups_of(user)),
            )
        )
    return "\n".join(out)


def shadow_view(config):
    """name:hash per extra account; name:! when it has no password.

    An empty password is a locked account, not an account anybody can log
    into: `!` is what Debian's own passwordless useradd writes.
    """
    out = []
    for user in config.users[1:]:
        password = user.get("password") or ""
        out.append("%s:%s" % (user["name"], sh_hash(password) if password else "!"))
    return "\n".join(out)


def ssh_keys_view(config):
    """name key... per configured key, paths already read on this machine."""
    out = []
    for user in config.users:
        for entry in user.get("ssh_keys") or []:
            if not isinstance(entry, str):
                continue
            key = entry.strip()
            if key.split()[:1] and key.split()[0] not in KEY_TYPES:
                path = os.path.expanduser(key)
                try:
                    with open(path, "r", encoding="utf-8", errors="replace") as fh:
                        key = fh.readline().strip()
                except OSError as exc:
                    raise ConfigError("users.%s.ssh_keys: %s" % (user["name"], exc))
            out.append("%s %s" % (user["name"], key))
    return "\n".join(out)


PLACEHOLDER_RE = re.compile(r"@B2B_[A-Z0-9_]+@")


def render(config, template):
    """The template with every @B2B_KEY@ replaced.

    A single left-to-right pass through re.sub with a function: the value is
    never rescanned and never read as a backreference, so a crypt hash full of
    $ and / lands verbatim. A placeholder nothing answers, or one whose value
    is empty, is an error -- the alternative is d-i stopping to ask a question
    on a screen nobody watches.
    """
    try:
        with open(template, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise ConfigError("template not found: %s" % exc)
    values = dict(LEGACY)
    table = {
        "@B2B_ROOT_PASSWORD_HASH@": sh_hash(config.system.get("root_password") or ""),
        "@B2B_USER_PASSWORD_HASH@": sh_hash(config.user_password),
    }
    for key in values:
        table["@%s@" % key] = get(config, key)
    missing, empty = [], []

    def replace(match):
        token = match.group(0)
        if token not in table:
            missing.append(token)
            return token
        value = table[token]
        if value == "":
            empty.append(token)
        return value

    out = PLACEHOLDER_RE.sub(replace, text)
    if missing:
        raise ConfigError(
            "%s: nothing in born2root.toml answers %s"
            % (template, ", ".join(sorted(set(missing))))
        )
    if empty:
        raise ConfigError(
            "%s: %s would be empty, and an empty answer makes the installer "
            "stop and ask" % (template, ", ".join(sorted(set(empty))))
        )
    return out


def show(config):
    out = ["", "  %s" % config.path, ""]

    def row(label, value):
        out.append("    %-24s %s" % (label, value))

    row("vm.name", config.vm["name"])
    row("vm.backend", config.vm["backend"])
    row("vm.disk_gb", config.vm["disk_gb"])
    row("vm.ram_mb", config.vm["ram_mb"])
    row("vm.cpus", config.vm["cpus"])
    row("vm.profile", config.vm["profile"])
    row("vm.ai_mode", config.vm["ai_mode"])
    out.append("")
    for key in ("host_models", "models", "models_dir", "budget_gb", "gpu", "context", "bind"):
        value = config.ai[key]
        if isinstance(value, list):
            value = " ".join(str(v) for v in value)
        row("ai." + key, value)
    out.append("")
    hostname = config.hostname
    if not config.system["hostname"]:
        hostname += "   (from the first account)"
    row("system.hostname", hostname)
    for key in ("locale", "keymap", "timezone", "mirror"):
        row("system." + key, config.system[key])
    row("system.root_password", config.system["root_password"])
    passphrase = config.luks_passphrase
    if os.environ.get("VM_PASS"):
        passphrase += "   (VM_PASS, overriding the file)"
    row("system.luks_passphrase", passphrase)
    out.append("")
    out.append(
        "    %-12s %-10s %-5s %-5s %-20s %s"
        % ("account", "password", "sudo", "nvim", "groups", "keys")
    )
    for user in config.users:
        password = user.get("password")
        state = "set" if password else ("locked" if password == "" else "missing")
        out.append(
            "    %-12s %-10s %-5s %-5s %-20s %s"
            % (
                user["name"] + ("*" if config.is_first(user) else ""),
                state,
                "yes" if user.get("sudo") or config.is_first(user) else "no",
                "yes" if user.get("nvim") or config.is_first(user) else "no",
                ",".join(config.groups_of(user)),
                len(user.get("ssh_keys") or []),
            )
        )
    out.append("    * the account the installer creates: ssh b2b, %s.42.fr" % config.login)
    out.append("")
    row("packages.apt", " ".join(config.packages["apt"] or []) or "(none)")
    row("features", config.feature_tokens() or "(all auto: the profile decides)")
    row(
        "network.forwards",
        " ".join(
            "%s %s->%s" % (f.get("name"), f.get("host"), f.get("guest"))
            for f in config.forwards()
        )
        or "(none beyond the built-in ones)",
    )
    out.append("")
    for name in DEFAULTS["policy"]:
        values = config.policy[name]
        row(
            "policy." + name,
            " ".join(
                "%s=%s" % (k, "true" if v is True else "false" if v is False else v)
                for k, v in values.items()
            ),
        )
    out.append("")
    row("disk.swap_mb", config.disk["swap_mb"])
    out.append("")
    out.append("    %-9s %-10s %6s %5s %7s" % ("volume", "mount", "floor", "share", "cap"))
    for line in volumes_view(config).splitlines():
        fields = line.split()
        out.append("    %-9s %-10s %6s %5s %7s" % tuple(fields))
    out.append("")
    return "\n".join(out)


def dump(config):
    return json.dumps(
        {
            "path": config.path,
            "login": config.login,
            "hostname": config.hostname,
            "vm": config.vm,
            "ai": config.ai,
            "system": config.system,
            "users": [
                {k: v for k, v in u.items() if k != "given"} for u in config.users
            ],
            "packages": config.packages,
            "features": config.features,
            "policy": config.policy,
            "network": config.network,
            "disk": config.disk,
            "derived": {
                "nvim_users": config.nvim_users(),
                "features": config.feature_tokens(),
                "extra_users": get(config, "B2B_EXTRA_USERS"),
                "forwards": get(config, "B2B_FORWARDS"),
            },
        },
        indent=2,
        sort_keys=True,
    )


def check(config):
    errors, warnings = Validator(config).run()
    for warning in warnings:
        sys.stderr.write("warning: %s\n" % warning)
    if errors:
        for where, message in errors:
            sys.stderr.write("%s: %s: %s\n" % (config.path, where, message))
        sys.stderr.write(
            "%d problem(s) in %s -- fix them, then: make config\n"
            % (len(errors), os.path.basename(config.path))
        )
        return 1
    sys.stdout.write("✓ %s is valid\n" % config.path)
    return 0


# ── Writing [ai] ────────────────────────────────────────────────────────────
# The one place anything writes born2root.toml: setup/host/llm_select.sh, the
# model picker. A tracked file people annotate cannot be regenerated from a
# parse -- tomllib drops every comment -- so one `key = value` line of the [ai]
# table is replaced in place (added when missing, and the table with it), the
# key's alignment kept, everything else byte for byte. The result is parsed
# and validated BEFORE it replaces the file, so a bad choice never lands.
def _toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list) and all(isinstance(v, str) for v in value):
        return "[" + ", ".join(json.dumps(v, ensure_ascii=False) for v in value) + "]"
    raise ConfigError("cannot write %r to born2root.toml" % (value,))


def set_ai(path, key, value):
    if key not in DEFAULTS["ai"]:
        raise ConfigError("ai.%s: %s" % (key, _unknown(key, DEFAULTS["ai"])))
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.strip() == "[ai]"), None)
    if start is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines += ["\n", "[ai]\n"]
        start = len(lines) - 1
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith("[")),
        len(lines),
    )
    rendered = _toml_value(value)
    pattern = re.compile(r"^(\s*%s\s*=\s*)" % re.escape(key))
    for i in range(start + 1, end):
        match = pattern.match(lines[i])
        if match:
            lines[i] = match.group(1) + rendered + "\n"
            break
    else:
        at = end
        while at > start + 1 and not lines[at - 1].strip():
            at -= 1
        lines.insert(at, "%s = %s\n" % (key, rendered))
    text = "".join(lines)
    try:
        raw = toml_module().loads(text)
    except Exception as exc:
        raise ConfigError("ai.%s: the result would not parse: %s" % (key, exc))
    errors, _ = Validator(Config(raw, path)).run()
    ours = [e for e in errors if e[0] == "ai." + key or e[0] == "ai"]
    if ours:
        raise ConfigError("; ".join("%s: %s" % e for e in ours))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, path)


USAGE = """usage: b2b_config.py get KEY | --check | --parses | --show | --dump
       | --volumes | --guest | --users | --shadow | --ssh-keys | --render FILE
       | --set-ai KEY JSON
       (env: B2B_CONFIG=path/to/born2root.toml, VM_PASS)
"""


def main(argv):
    if not argv:
        sys.stderr.write(USAGE)
        return 2
    mode = argv[0]
    # `get` answers from whatever can be read and stays silent whatever
    # happens: the Makefile calls it at parse time for every target.
    if mode == "get":
        try:
            config = load()
        except Exception:
            return 0
        try:
            sys.stdout.write(get(config, argv[1] if len(argv) > 1 else ""))
        except Exception:
            pass
        return 0
    try:
        if mode == "--parses":
            read_raw()
            return 0
        if mode == "--set-ai":
            if len(argv) < 3:
                sys.stderr.write(USAGE)
                return 2
            try:
                value = json.loads(argv[2])
            except ValueError:
                raise ConfigError("--set-ai %s: %r is not JSON" % (argv[1], argv[2]))
            set_ai(CONFIG, argv[1], value)
            return 0
        config = load()
        if mode == "--check":
            return check(config)
        if mode == "--show":
            sys.stdout.write(show(config) + "\n")
            return 0
        if mode == "--dump":
            sys.stdout.write(dump(config) + "\n")
            return 0
        if mode == "--volumes":
            errors, _ = Validator(config).run()
            table = [e for e in errors if e[0].startswith("disk.")]
            if table:
                for where, message in table:
                    sys.stderr.write("%s: %s: %s\n" % (config.path, where, message))
                return 1
            sys.stdout.write(volumes_view(config) + "\n")
            return 0
        if mode == "--guest":
            sys.stdout.write(guest_view(config) + "\n")
            return 0
        if mode == "--users":
            sys.stdout.write(users_view(config) + "\n")
            return 0
        if mode == "--shadow":
            out = shadow_view(config)
            sys.stdout.write(out + "\n" if out else "")
            return 0
        if mode == "--ssh-keys":
            out = ssh_keys_view(config)
            sys.stdout.write(out + "\n" if out else "")
            return 0
        if mode == "--render":
            if len(argv) < 2:
                sys.stderr.write(USAGE)
                return 2
            sys.stdout.write(render(config, argv[1]))
            return 0
    except ConfigError as exc:
        sys.stderr.write("b2b_config: %s\n" % exc)
        return 1
    sys.stderr.write(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
