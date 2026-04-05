#!/usr/bin/env python3
"""auditwheel-r-repair.py — Bundle system library dependencies using auditwheel-r.

Thin wrapper around auditwheel-r that customizes the manylinux_2_28 policy
to also bundle X11 and GLib libraries (which are on the standard allowlist
but not available on minimal container images).

Operates on the R installation directory and writes the repaired output
to a "wheelhouse" directory (auditwheel-r's default behavior).

Usage: auditwheel-r-repair.py <r-install-path>
"""

import logging
import os
import sys

from auditwheel.architecture import Architecture
from auditwheel.libc import Libc
from auditwheel.patcher import Patchelf

from auditwheel_r.r_abi import analyze_r_abi, r_wheel_policies
from auditwheel_r.repair_r import repair_r

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

# Libraries to remove from the manylinux_2_28 whitelist so they get bundled.
# These are on the official PEP 600 allowlist but not available on minimal
# container images (e.g., ubuntu:noble without X11 or GLib packages).
BUNDLE_EXTRA = {
    "libX11.so.6",
    "libXext.so.6",
    "libXrender.so.1",
    "libICE.so.6",
    "libSM.so.6",
    "libglib-2.0.so.0",
    "libgobject-2.0.so.0",
    "libgthread-2.0.so.0",
}


def custom_policies():
    """Return auditwheel-r policies with X11/GLib removed from the whitelist."""
    policies = r_wheel_policies(libc=Libc.detect(), arch=Architecture.detect())

    updated = []
    for policy in policies._policies:
        new_whitelist = policy.whitelist - BUNDLE_EXTRA
        updated_policy = policy.__class__(
            **{**policy.__dict__, "whitelist": new_whitelist}
        )
        updated.append(updated_policy)
    policies._policies = updated

    return policies


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <r-install-path>", file=sys.stderr)
        sys.exit(1)

    r_path = os.path.abspath(sys.argv[1])
    if not os.path.isdir(r_path):
        print(f"Error: {r_path} is not a directory", file=sys.stderr)
        sys.exit(1)

    out_dir = os.path.abspath("wheelhouse")
    os.makedirs(out_dir, exist_ok=True)

    policies = custom_policies()
    exclude = frozenset()

    logger.info("Analyzing R installation: %s", r_path)
    wheel_abi = analyze_r_abi(policies, r_path, exclude, True)

    # Use the lowest manylinux policy (manylinux_2_28)
    plat = policies.lowest.name
    requested_policy = policies.get_policy_by_name(plat)
    abis = [requested_policy.name, *requested_policy.aliases]

    patcher = Patchelf()

    logger.info("Repairing with policy: %s", plat)
    out_path = repair_r(
        wheel_abi,
        r_path,
        abis=abis,
        lib_sdir=".libs",
        out_dir=out_dir,
        update_tags=False,
        patcher=patcher,
        exclude=exclude,
        strip=False,
    )

    if out_path is not None:
        logger.info("Repaired output: %s", out_path)

        # Count bundled libs
        libs_dir = None
        for root, dirs, files in os.walk(out_path):
            if os.path.basename(root) == ".libs":
                libs_dir = root
                break
        if libs_dir:
            libs = os.listdir(libs_dir)
            logger.info("Bundled %d libraries into %s", len(libs), libs_dir)
            for lib in sorted(libs):
                logger.info("  %s", lib)
    else:
        logger.info("No external dependencies found (pure R package)")


if __name__ == "__main__":
    main()
