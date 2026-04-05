#!/usr/bin/env python3
"""delocate-r.py — Bundle system library dependencies into an R installation.

Replaces auditwheel-r with a standalone script using ldd + patchelf.
Discovers non-allowed shared library dependencies, copies them into
lib/R/lib/.libs/ with hash-renamed filenames, rewrites RPATHs and DT_NEEDED
entries so the R installation is self-contained and portable.

Operates in-place on the R installation directory.

Usage: delocate-r.py <r-install-path>
"""

import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# ── Allowed libraries (not bundled) ──────────────────────────────────────────
#
# These are expected to exist on any glibc 2.28+ system. Based on the
# manylinux_2_28 standard (PEP 600), minus X11 libs which we bundle for
# maximum portability.
#
# Notable: libX11, libSM, libICE, libXext, libXrender, libglib-2.0, and
# libgobject-2.0 are in the official manylinux_2_28 allowlist but we
# intentionally exclude them so they get bundled, making R work on minimal
# systems without X11 or GLib packages installed.
ALLOWED_PREFIXES = [
    # glibc core
    "linux-vdso.so",
    "ld-linux-x86-64.so",
    "ld-linux-aarch64.so",
    "libc.so",
    "libm.so",
    "libdl.so",
    "librt.so",
    "libpthread.so",
    "libnsl.so",
    "libutil.so",
    "libresolv.so",
    "libanl.so",
    # Compiler runtime
    "libgcc_s.so",
    "libstdc++.so",
    "libatomic.so",
    # Core system libs
    "libz.so",
    "libexpat.so",
    # GL (keep as system — drivers are system-specific)
    "libGL.so",
    # R internal (loaded via LD_LIBRARY_PATH from ldpaths, not RPATH)
    "libR.so",
    "libRblas.so",
    "libRlapack.so",
]


def is_allowed(soname: str) -> bool:
    """Check if a soname is on the allowlist (prefix match)."""
    return any(soname.startswith(prefix) for prefix in ALLOWED_PREFIXES)


def is_elf(path: Path) -> bool:
    """Check if a file is an ELF binary."""
    try:
        result = subprocess.run(
            ["file", "--mime-type", "--brief", str(path)],
            capture_output=True, text=True, check=True,
        )
        mime = result.stdout.strip()
        return mime in ("application/x-executable", "application/x-pie-executable",
                        "application/x-sharedlib")
    except subprocess.CalledProcessError:
        return False


def patchelf(*args: str) -> str:
    """Run patchelf and return stdout. Raises on failure."""
    result = subprocess.run(
        ["patchelf", *args],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"patchelf {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def patchelf_try(*args: str) -> str | None:
    """Run patchelf, returning stdout or None on failure."""
    result = subprocess.run(
        ["patchelf", *args],
        capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def ldd(path: Path, extra_lib_path: str = "") -> list[tuple[str, str]]:
    """Run ldd and return list of (soname, resolved_path) pairs."""
    env = os.environ.copy()
    if extra_lib_path:
        env["LD_LIBRARY_PATH"] = extra_lib_path + ":" + env.get("LD_LIBRARY_PATH", "")

    result = subprocess.run(
        ["ldd", str(path)],
        capture_output=True, text=True, env=env,
    )
    if result.returncode != 0:
        return []

    # Parse ldd output lines like: "\tlibfoo.so.1 => /usr/lib64/libfoo.so.1 (0x...)"
    pattern = re.compile(r"^\t(\S+)\s+=>\s+(\S+)\s+\(0x")
    pairs = []
    for line in result.stdout.splitlines():
        m = pattern.match(line)
        if m:
            soname, resolved = m.group(1), m.group(2)
            if resolved != "not":
                pairs.append((soname, resolved))
    return pairs


def file_hash(path: str, n: int = 8) -> str:
    """First n hex chars of SHA256 of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()[:n]


def hash_rename(filename: str, shorthash: str) -> str:
    """Hash-rename a library filename: libfoo.so.1.2.3 -> libfoo-<hash>.so.1.2.3"""
    base, _, ext = filename.partition(".")
    return f"{base}-{shorthash}.{ext}"


def relpath_from(target: Path, base: Path) -> str:
    """Compute $ORIGIN-style relative path from base dir to target dir."""
    return os.path.relpath(target, base)


def discover_elf_files(r_path: Path) -> list[Path]:
    """Find all ELF files in the R installation."""
    candidates = []
    for p in r_path.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix in (".so",) or ".so." in p.name or p.name == "R":
            candidates.append(p)

    return [p for p in candidates if is_elf(p)]


def discover_external_deps(
    elf_files: list[Path],
    r_path: Path,
) -> tuple[dict[str, str], dict[Path, list[str]]]:
    """Analyze ELF files and find external (non-allowed) dependencies.

    Returns:
        external_libs: {soname: system_path} for libs to bundle
        elf_needs: {elf_path: [sonames...]} for ELF files that need patching
    """
    r_lib_path = str(r_path / "lib" / "R" / "lib")
    libs_dir = str(r_path / "lib" / "R" / "lib" / ".libs")
    extra_path = r_lib_path + ":" + libs_dir
    external_libs: dict[str, str] = {}
    elf_needs: dict[Path, list[str]] = {}

    for elf in elf_files:
        needs = []
        for soname, resolved in ldd(elf, extra_lib_path=extra_path):
            # Skip libs already inside R installation
            if resolved.startswith(str(r_path) + "/"):
                continue
            # Skip allowed system libs
            if is_allowed(soname):
                continue
            external_libs[soname] = resolved
            needs.append(soname)

        if needs:
            elf_needs[elf] = needs

    return external_libs, elf_needs


def graft_libraries(
    external_libs: dict[str, str],
    dest_dir: Path,
) -> tuple[dict[str, str], dict[str, Path]]:
    """Copy and hash-rename external libraries into dest_dir.

    Returns:
        soname_map: {old_soname: new_soname}
        soname_path: {old_soname: dest_path}
    """
    dest_dir.mkdir(parents=True, exist_ok=True)
    soname_map: dict[str, str] = {}
    soname_path: dict[str, Path] = {}

    for soname, src_path in external_libs.items():
        shorthash = file_hash(src_path)
        # Use the actual filename (e.g., libICE.so.6.3.0) rather than the
        # soname (libICE.so.6) for the grafted filename, matching auditwheel-r.
        src_name = os.path.basename(src_path)
        new_soname = hash_rename(src_name, shorthash)
        dest_path = dest_dir / new_soname

        if not dest_path.exists():
            shutil.copy2(src_path, dest_path)
            dest_path.chmod(0o755)

            patchelf("--set-soname", new_soname, str(dest_path))

            # Set RPATH to $ORIGIN so grafted libs can find sibling grafted libs
            # (e.g., libreadline needs libtinfo in the same directory)
            patchelf("--set-rpath", "$ORIGIN", str(dest_path))

            print(f"    {soname} -> {new_soname}")

        soname_map[soname] = new_soname
        soname_path[soname] = dest_path

    return soname_map, soname_path


def fix_inter_library_refs(
    soname_map: dict[str, str],
    soname_path: dict[str, Path],
) -> None:
    """Update DT_NEEDED entries between grafted libraries."""
    for soname, dest_path in soname_path.items():
        needed_list = patchelf_try("--print-needed", str(dest_path))
        if needed_list is None:
            continue
        for needed in needed_list.splitlines():
            if needed in soname_map:
                patchelf("--replace-needed", needed, soname_map[needed], str(dest_path))


def patch_elf_binaries(
    elf_needs: dict[Path, list[str]],
    soname_map: dict[str, str],
    dest_dir: Path,
    r_path: Path,
) -> None:
    """Patch R's ELF binaries: replace DT_NEEDED and set RPATHs."""
    for elf, needs in elf_needs.items():
        # Replace DT_NEEDED entries with hash-renamed sonames
        for soname in needs:
            new_soname = soname_map.get(soname)
            if not new_soname:
                continue
            patchelf_try("--replace-needed", soname, new_soname, str(elf))

        # Compute RPATH to lib/R/lib/.libs/ relative to this binary
        elf_dir = elf.parent
        rel = relpath_from(dest_dir, elf_dir)
        new_rpath = f"$ORIGIN/{rel}"

        # Preserve existing in-package RPATHs, add new one
        old_rpath = patchelf_try("--print-rpath", str(elf)) or ""
        rpath_entries = []
        for entry in old_rpath.split(":"):
            if not entry:
                continue
            # Resolve $ORIGIN to check if it's within-package
            resolved = entry.replace("$ORIGIN", str(elf_dir))
            try:
                resolved = str(Path(resolved).resolve())
            except (OSError, ValueError):
                continue
            if resolved.startswith(str(r_path) + "/"):
                rpath_entries.append(entry)

        rpath_entries.append(new_rpath)

        # Deduplicate while preserving order
        seen: set[str] = set()
        unique = []
        for e in rpath_entries:
            if e not in seen:
                seen.add(e)
                unique.append(e)

        combined = ":".join(unique)

        result = subprocess.run(
            ["patchelf", "--set-rpath", combined, str(elf)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            # Expected for non-PIE executables (e.g., lib/R/bin/exec/R)
            print(f"    WARNING: cannot set RPATH on {elf} (non-PIE binary?), skipping")


def verify_repair(
    soname_map: dict[str, str],
    soname_path: dict[str, Path],
    elf_needs: dict[Path, list[str]],
    dest_dir: Path,
    r_path: Path,
) -> None:
    """Verify all grafted libs have correct RPATH, SONAME, and resolve deps."""
    errors = []

    for soname, dest_path in soname_path.items():
        new_soname = soname_map[soname]

        # Check RPATH contains $ORIGIN
        rpath = patchelf_try("--print-rpath", str(dest_path)) or ""
        if "$ORIGIN" not in rpath:
            errors.append(f"{new_soname} missing $ORIGIN in RPATH (got: '{rpath}')")

        # Check SONAME was rewritten
        actual = patchelf_try("--print-soname", str(dest_path)) or ""
        if actual != new_soname:
            errors.append(f"{new_soname} has wrong SONAME '{actual}'")

        # Check all DT_NEEDED entries resolve
        needed_list = patchelf_try("--print-needed", str(dest_path))
        if needed_list:
            for needed in needed_list.splitlines():
                if is_allowed(needed):
                    continue
                if not (dest_dir / needed).exists():
                    errors.append(f"{new_soname} needs '{needed}' but not found in lib/R/lib/.libs/")

    # Verify patched ELF binaries can resolve all bundled deps
    r_lib_path = str(r_path / "lib" / "R" / "lib")
    for elf in elf_needs:
        # Check raw ldd output for "not found"
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = r_lib_path + ":" + env.get("LD_LIBRARY_PATH", "")
        result = subprocess.run(
            ["ldd", str(elf)], capture_output=True, text=True, env=env,
        )
        for line in result.stdout.splitlines():
            if "not found" in line:
                lib = line.strip().split()[0]
                errors.append(f"{elf.name} cannot resolve '{lib}'")

    if errors:
        for e in errors:
            print(f"    FAIL: {e}", file=sys.stderr)
        print("  ERROR: Verification failed.", file=sys.stderr)
        sys.exit(1)

    print("  Verification passed.")


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: delocate-r.py <r-install-path>", file=sys.stderr)
        sys.exit(1)

    r_path = Path(sys.argv[1]).resolve()
    if not r_path.is_dir():
        print(f"ERROR: R installation not found at {r_path}", file=sys.stderr)
        sys.exit(1)

    libs_sdir = "lib/R/lib/.libs"
    dest_dir = r_path / libs_sdir

    print(f"delocate-r: repairing {r_path} (in-place)")

    # Phase 1: Discover ELF files
    print("  Discovering ELF files...")
    elf_files = discover_elf_files(r_path)
    print(f"  Found {len(elf_files)} ELF files")

    # Phase 2-3: Discover and graft in a fixpoint loop.
    # Grafted libs may themselves have non-allowed deps (e.g., bundled libpango
    # depends on libgobject-2.0). Keep iterating until no new libs are found.
    all_soname_map: dict[str, str] = {}
    all_soname_path: dict[str, Path] = {}
    all_elf_needs: dict[Path, list[str]] = {}
    scan_files = list(elf_files)
    iteration = 0

    while True:
        iteration += 1
        print(f"  Analyzing dependencies (pass {iteration})...")
        external_libs, elf_needs = discover_external_deps(scan_files, r_path)

        # Filter out libs we've already grafted
        new_libs = {s: p for s, p in external_libs.items() if s not in all_soname_map}

        if not new_libs:
            if iteration == 1:
                print("  No external libraries to bundle.")
                return
            break

        print(f"  New libraries to bundle: {len(new_libs)}")
        for soname, path in sorted(new_libs.items()):
            print(f"    {soname} -> {path}")

        print(f"  Bundling libraries into {libs_sdir}/")
        soname_map, soname_path = graft_libraries(new_libs, dest_dir)

        all_soname_map.update(soname_map)
        all_soname_path.update(soname_path)
        all_elf_needs.update(elf_needs)

        # Next iteration: scan the newly grafted libs for their deps
        scan_files = [path for path in soname_path.values()]

    total = len(all_soname_map)
    print(f"  Total libraries to bundle: {total}")

    # Phase 4: Fix inter-library references
    print("  Fixing inter-library references...")
    fix_inter_library_refs(all_soname_map, all_soname_path)

    # Phase 5: Patch ELF binaries
    print("  Patching ELF binaries...")
    patch_elf_binaries(all_elf_needs, all_soname_map, dest_dir, r_path)

    # Phase 6: Verify repair
    print("  Verifying repair...")
    verify_repair(all_soname_map, all_soname_path, all_elf_needs, dest_dir, r_path)

    print(f"delocate-r: done. Bundled {total} libraries into {libs_sdir}/")


if __name__ == "__main__":
    main()
