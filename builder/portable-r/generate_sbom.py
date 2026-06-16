#!/usr/bin/env python3
"""Generate a CycloneDX 1.5 SBOM for a portable R installation.

Reads the delocate manifest (written by delocate_r.py) to map bundled libraries
back to their source system packages (RPM or APK), and produces a CycloneDX
SBOM at lib/R/sbom.cdx.json.

Uses only Python stdlib -- no external SBOM tools needed.

Usage: generate_sbom.py <r-install-path> <r-version> <os-identifier>
"""
from __future__ import annotations

import json
import os
import platform
import re
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path


def detect_pkg_manager() -> str:
    """Detect whether to use rpm or apk."""
    for cmd in ("rpm", "apk"):
        if subprocess.run(
            ["which", cmd], capture_output=True
        ).returncode == 0:
            return cmd
    return "unknown"


def query_rpm(sys_path: str) -> tuple[str, str, str] | None:
    """Query RPM for package name, version, and arch owning a file."""
    result = subprocess.run(
        ["rpm", "-qf", "--qf", "%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}", sys_path],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    parts = result.stdout.split("\t")
    if len(parts) != 3:
        return None
    return parts[0], parts[1], parts[2]


def query_apk(sys_path: str) -> tuple[str, str] | None:
    """Query APK for package name and version owning a file."""
    result = subprocess.run(
        ["apk", "info", "--who-owns", sys_path],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or "is owned by" not in result.stdout:
        return None
    # Output: "/usr/lib/libfoo.so.1 is owned by foo-1.2.3-r0"
    pkg_full = result.stdout.strip().split("is owned by ")[-1]
    # Split "foo-1.2.3-r0" into name and version.
    # APK names can contain hyphens; version starts at last hyphen before a digit.
    m = re.match(r"^(.+?)-(\d[^-]*(?:-r\d+)?)$", pkg_full)
    if m:
        return m.group(1), m.group(2)
    return pkg_full, "unknown"


def detect_base_image() -> str:
    """Detect the base image description."""
    for path in ("/etc/redhat-release", "/etc/alpine-release"):
        try:
            content = open(path).read().strip()
            if path == "/etc/alpine-release":
                return f"Alpine {content}"
            return content
        except FileNotFoundError:
            continue
    return "unknown"


def purl_for_rpm(name: str, version: str, arch: str) -> str:
    """Generate a package URL for an RPM package."""
    # Detect distro from /etc/os-release
    distro = "rocky"
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("ID="):
                    distro = line.strip().split("=")[1].strip('"')
                    break
    except FileNotFoundError:
        pass
    return f"pkg:rpm/{distro}/{name}@{version}?arch={arch}"


def purl_for_apk(name: str, version: str) -> str:
    """Generate a package URL for an APK package."""
    arch = platform.machine()
    return f"pkg:apk/alpine/{name}@{version}?arch={arch}"


def main() -> None:
    if len(sys.argv) != 4:
        print(
            "Usage: generate_sbom.py <r-install-path> <r-version> <os-identifier>",
            file=sys.stderr,
        )
        sys.exit(1)

    r_path = Path(sys.argv[1]).resolve()
    r_version = sys.argv[2]
    os_id = sys.argv[3]

    manifest_path = r_path / "lib/R/lib/.libs/delocate-manifest.json"
    sbom_path = r_path / "lib/R/sbom.cdx.json"

    if not manifest_path.exists():
        print(f"ERROR: delocate manifest not found at {manifest_path}", file=sys.stderr)
        sys.exit(1)

    with open(manifest_path) as f:
        manifest = json.load(f)

    pkg_mgr = detect_pkg_manager()
    base_image = detect_base_image()

    # Group bundled files by source package (deduplicate)
    components: dict[str, dict] = {}
    for bundled_name, sys_path in manifest.items():
        if sys_path == "unknown" or not os.path.isfile(sys_path):
            continue
        if pkg_mgr == "rpm":
            info = query_rpm(sys_path)
            if info is None:
                continue
            pkg_name, pkg_version, pkg_arch = info
            if pkg_name not in components:
                components[pkg_name] = {
                    "version": pkg_version,
                    "purl": purl_for_rpm(pkg_name, pkg_version, pkg_arch),
                    "files": [],
                }
            components[pkg_name]["files"].append(bundled_name)
        elif pkg_mgr == "apk":
            info = query_apk(sys_path)
            if info is None:
                continue
            pkg_name, pkg_version = info
            if pkg_name not in components:
                components[pkg_name] = {
                    "version": pkg_version,
                    "purl": purl_for_apk(pkg_name, pkg_version),
                    "files": [],
                }
            components[pkg_name]["files"].append(bundled_name)

    # Build CycloneDX 1.5 SBOM
    sbom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "component": {
                "type": "application",
                "name": "Posit R",
                "version": r_version,
                "description": f"Portable R build ({os_id})",
            },
            "properties": [
                {"name": "posit:os-identifier", "value": os_id},
                {"name": "posit:base-image", "value": base_image},
            ],
        },
        "components": [],
    }

    for pkg_name, info in sorted(components.items()):
        sbom["components"].append({
            "type": "library",
            "name": pkg_name,
            "version": info["version"],
            "purl": info["purl"],
            "properties": [
                {
                    "name": "posit:bundled-files",
                    "value": ", ".join(sorted(info["files"])),
                },
            ],
        })

    with open(sbom_path, "w") as f:
        json.dump(sbom, f, indent=2)
        f.write("\n")

    print(f"  Wrote {sbom_path} ({len(sbom['components'])} components)")


if __name__ == "__main__":
    main()
