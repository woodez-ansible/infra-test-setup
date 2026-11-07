"""Validate VM spec files (vms/<name>.yml) before anything reaches the hypervisor.

Mirrors the checks in playbooks/vm-build.yml, plus two only a repo-wide check can make:
the file name must equal vm_name, and unknown keys are errors (a typo such as
vm_memroy_mib would otherwise be silently ignored and the default used).

Usage: python3 ci/validate_vm_spec.py [vms/a.yml ...]   (default: every vms/*.yml)
Exit status is non-zero if any spec is invalid.
"""

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DEFAULTS = ROOT / "playbooks" / "vars" / "vm_defaults.yml"
HYPERVISOR_VARS = ROOT / "inventory" / "group_vars" / "hypervisors" / "vars.yml"
SKIP = {"example.yml"}

NAME_RE = re.compile(r"^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$")
MAC_RE = re.compile(r"^52:54:00(:[0-9a-f]{2}){3}$")
RANGES = {"vm_vcpus": (1, 16), "vm_memory_mib": (512, 16384), "vm_disk_gib": (5, 500)}
BOOLS = {"vm_passwordless_sudo", "vm_password_login", "vm_apt_upgrade", "vm_autostart",
         "vm_allow_restart", "vm_allow_replace"}
CHOICES = {"vm_firmware": {"bios", "uefi"}, "vm_cpu_mode": {"host-passthrough", "host-model"}}
STRINGS = {"vm_bridge", "vm_user", "vm_timezone", "vm_description"}
# Settings that are host policy, not per-VM choices
NOT_IN_SPECS = {"vm_host_memory_reserve_mib", "vm_bridge_default"}


def allowed_keys() -> set[str]:
    defaults = yaml.safe_load(DEFAULTS.read_text())
    return ({k for k in defaults if k.startswith("vm_")} - NOT_IN_SPECS) | {"vm_name"}


def releases() -> set[str]:
    return set(yaml.safe_load(HYPERVISOR_VARS.read_text())["ubuntu_images"])


def check(path: Path, keys: set[str], known_releases: set[str]) -> list[str]:
    errors: list[str] = []
    try:
        spec = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        return [f"not valid YAML: {exc}"]
    if not isinstance(spec, dict):
        return ["must be a YAML mapping of vm_* settings"]

    for key in sorted(set(spec) - keys):
        errors.append(f"unknown setting '{key}'")

    name = spec.get("vm_name")
    if not isinstance(name, str) or not NAME_RE.match(name):
        errors.append("vm_name: required; lowercase letters, digits and '-', max 32, starts with a letter")
    elif path.stem != name:
        errors.append(f"file name must match vm_name: rename to vms/{name}.yml")

    for key, (lo, hi) in RANGES.items():
        if key in spec and not (isinstance(spec[key], int) and not isinstance(spec[key], bool)
                                and lo <= spec[key] <= hi):
            errors.append(f"{key}: must be a whole number {lo}-{hi}")
    for key in BOOLS & spec.keys():
        if not isinstance(spec[key], bool):
            errors.append(f"{key}: must be true or false")
    for key, options in CHOICES.items():
        if key in spec and spec[key] not in options:
            errors.append(f"{key}: must be one of {sorted(options)}")
    for key in STRINGS & spec.keys():
        if not isinstance(spec[key], str):
            errors.append(f"{key}: must be a string")

    if "vm_ubuntu_release" in spec and str(spec["vm_ubuntu_release"]) not in known_releases:
        errors.append(f"vm_ubuntu_release: must be one of {sorted(known_releases)} (quote it, e.g. \"26.04\")")
    if "vm_mac" in spec and spec["vm_mac"] != "" and not (isinstance(spec["vm_mac"], str) and MAC_RE.match(spec["vm_mac"])):
        errors.append("vm_mac: must be empty or 52:54:00:xx:xx:xx (lowercase hex)")
    if "vm_extra_disks" in spec:
        disks = spec["vm_extra_disks"]
        if not isinstance(disks, list) or not all(
            isinstance(d, dict) and set(d) == {"size_gib"} and isinstance(d["size_gib"], int) and d["size_gib"] > 0
            for d in disks
        ):
            errors.append("vm_extra_disks: must be a list like [{size_gib: 20}]")
    for key in ("vm_packages", "vm_ssh_authorized_keys"):
        if key in spec and not (isinstance(spec[key], list) and all(isinstance(x, str) for x in spec[key])):
            errors.append(f"{key}: must be a list of strings")
    if spec.get("vm_passwordless_sudo") is False and not spec.get("vm_password_login", False):
        errors.append("vm_passwordless_sudo: false needs vm_password_login: true, or sudo is unusable")
    return errors


def main(argv: list[str]) -> int:
    paths = [Path(a) for a in argv] or sorted((ROOT / "vms").glob("*.yml"))
    paths = [p for p in paths if p.name not in SKIP]
    keys, known_releases = allowed_keys(), releases()
    failed = 0
    for path in paths:
        errors = check(path, keys, known_releases)
        resolved = path.resolve()
        rel = resolved.relative_to(ROOT) if resolved.is_relative_to(ROOT) else path
        if errors:
            failed += 1
            print(f"FAIL {rel}")
            for e in errors:
                print(f"     - {e}")
        else:
            print(f"ok   {rel}")
    print(f"\n{len(paths) - failed}/{len(paths)} specs valid")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
