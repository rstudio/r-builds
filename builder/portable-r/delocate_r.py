#!/usr/bin/env python3
"""delocate_r.py -- Bundle system library dependencies into an R installation.

Replaces auditwheel-r with a standalone script using ldd + patchelf.
Discovers non-allowed shared library dependencies, copies them into
lib/R/lib/.libs/ with hash-renamed filenames, rewrites RPATHs and DT_NEEDED
entries so the R installation is self-contained and portable.

Operates in-place on the R installation directory.

Usage: delocate_r.py [--policy manylinux|musllinux] <r-install-path>
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

# ── Allowed libraries (not bundled) ──────────────────────────────────────────
#
# Per-policy allowlists determine which libraries are expected on the target
# system and should NOT be bundled. Based on the auditwheel policy definitions:
#
#   manylinux: https://github.com/pypa/auditwheel/blob/main/src/auditwheel/policy/manylinux-policy.json
#   musllinux: https://github.com/pypa/auditwheel/blob/main/src/auditwheel/policy/musllinux-policy.json
#
# We intentionally use a narrower allowlist than the official policies:
# X11 libs (libX11, libSM, libICE, etc.) and GLib (libgobject-2.0, etc.) are
# in the manylinux allowlist but we bundle them for portability on minimal
# systems. The musllinux policy only allows libc.so and libz.so.1.

# Libs shared by all policies: linker pseudo-libs, R internals, GL drivers
_COMMON_PREFIXES = [
    # GL (keep as system -- drivers are system-specific)
    "libGL.so",
    # R internal (loaded via LD_LIBRARY_PATH from ldpaths, not RPATH)
    "libR.so",
    "libRblas.so",
    "libRlapack.so",
]

# manylinux (glibc) policy: official lib_whitelist includes libgcc_s, libstdc++,
# libatomic, X11, GLib, and more. We allow the subset that is truly universal
# on glibc systems and bundle the rest (X11, GLib) for portability.
MANYLINUX_PREFIXES = [
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
    "libmvec.so",
    # Compiler runtime (always present on glibc systems)
    "libgcc_s.so",
    "libstdc++.so",
    "libatomic.so",
    # Core system libs
    "libz.so",
    "libexpat.so",
] + _COMMON_PREFIXES

# musllinux (musl) policy: only libc.so and libz.so are on the official
# whitelist. Everything else (including libgcc_s, libstdc++) must be bundled
# since they are not part of the musl base system.
MUSLLINUX_PREFIXES = [
    # musl linker pseudo-libs
    "linux-vdso.so",
    # musl core (consolidates libc, libm, libdl, librt, libpthread into one)
    "libc.musl-",
    # Core system libs
    "libz.so",
] + _COMMON_PREFIXES

POLICIES = {
    "manylinux": MANYLINUX_PREFIXES,
    "musllinux": MUSLLINUX_PREFIXES,
}

# Module-level state set by main() before any processing
_allowed_prefixes: list[str] = []


def is_allowed(soname: str) -> bool:
    """Check if a soname is on the allowlist (prefix match)."""
    return any(soname.startswith(prefix) for prefix in _allowed_prefixes)


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


# ── ELF constants ────────────────────────────────────────────────────────────
_PT_LOAD = 1
_PT_DYNAMIC = 2
_DT_NULL = 0
_DT_STRTAB = 5


def fix_patchelf_strtab(path: Path) -> None:
    """Fix patchelf's VAddr/offset mismatch for .dynstr in its LOAD segment.

    patchelf 0.18.0 can produce an ELF where the .dynstr section's virtual
    address is inconsistent with the LOAD segment that maps it. Within a
    LOAD segment (offset P, VAddr V), a section at file offset P+X must
    have VAddr V+X. When patchelf places .dynstr at VAddr V+Y where Y!=X,
    the musl dynamic linker reads from the wrong file location, causing
    "Error loading shared library" with corrupted library names.

    This function detects the mismatch and patches DT_STRTAB in .dynamic
    (and the .dynstr section header) to use the correct virtual address.
    """
    with open(path, "r+b") as f:
        # Read ELF header (64 bytes for ELF64)
        ident = f.read(16)
        if ident[:4] != b"\x7fELF" or ident[4] != 2:  # Must be ELF64
            return

        f.seek(0)
        ehdr = f.read(64)
        e_phoff = struct.unpack_from("<Q", ehdr, 32)[0]
        e_shoff = struct.unpack_from("<Q", ehdr, 40)[0]
        e_phentsize = struct.unpack_from("<H", ehdr, 54)[0]
        e_phnum = struct.unpack_from("<H", ehdr, 56)[0]
        e_shentsize = struct.unpack_from("<H", ehdr, 58)[0]
        e_shnum = struct.unpack_from("<H", ehdr, 60)[0]
        e_shstrndx = struct.unpack_from("<H", ehdr, 62)[0]

        # Read program headers
        phdrs = []
        for i in range(e_phnum):
            pos = e_phoff + i * e_phentsize
            f.seek(pos)
            data = f.read(e_phentsize)
            phdrs.append({
                "type": struct.unpack_from("<I", data, 0)[0],
                "offset": struct.unpack_from("<Q", data, 8)[0],
                "vaddr": struct.unpack_from("<Q", data, 16)[0],
                "filesz": struct.unpack_from("<Q", data, 32)[0],
                "memsz": struct.unpack_from("<Q", data, 40)[0],
            })

        # Find PT_DYNAMIC and read DT_STRTAB
        dyn_phdr = next((p for p in phdrs if p["type"] == _PT_DYNAMIC), None)
        if dyn_phdr is None:
            return

        f.seek(dyn_phdr["offset"])
        dyn_data = f.read(dyn_phdr["filesz"])

        strtab_vaddr = None
        strtab_dyn_fpos = None  # file position of DT_STRTAB's d_val field
        for i in range(0, len(dyn_data), 16):
            d_tag = struct.unpack_from("<q", dyn_data, i)[0]
            if d_tag == _DT_NULL:
                break
            if d_tag == _DT_STRTAB:
                strtab_vaddr = struct.unpack_from("<Q", dyn_data, i + 8)[0]
                strtab_dyn_fpos = dyn_phdr["offset"] + i + 8
                break

        if strtab_vaddr is None:
            return

        # Find the LOAD segment containing the strtab VAddr
        load = next(
            (p for p in phdrs
             if p["type"] == _PT_LOAD
             and p["vaddr"] <= strtab_vaddr < p["vaddr"] + p["memsz"]),
            None,
        )
        if load is None:
            return

        # Where the runtime linker thinks strtab data is in the file
        runtime_offset = load["offset"] + (strtab_vaddr - load["vaddr"])

        # Find actual .dynstr file offset from section headers
        f.seek(e_shoff + e_shstrndx * e_shentsize + 24)
        shstrtab_off = struct.unpack("<Q", f.read(8))[0]
        f.seek(e_shoff + e_shstrndx * e_shentsize + 32)
        shstrtab_sz = struct.unpack("<Q", f.read(8))[0]
        f.seek(shstrtab_off)
        shstrtab = f.read(shstrtab_sz)

        dynstr_offset = None
        dynstr_shdr_pos = None
        for i in range(e_shnum):
            pos = e_shoff + i * e_shentsize
            f.seek(pos)
            shdr = f.read(e_shentsize)
            name_off = struct.unpack_from("<I", shdr, 0)[0]
            end = shstrtab.find(b"\x00", name_off)
            name = shstrtab[name_off:end].decode("ascii", errors="replace")
            if name == ".dynstr":
                dynstr_offset = struct.unpack_from("<Q", shdr, 24)[0]
                dynstr_shdr_pos = pos
                break

        if dynstr_offset is None:
            return

        if runtime_offset == dynstr_offset:
            return  # No mismatch

        # Calculate the correct VAddr
        correct_vaddr = load["vaddr"] + (dynstr_offset - load["offset"])

        print(f"    Fixing patchelf strtab mismatch in {path.name}: "
              f"VAddr 0x{strtab_vaddr:x} -> 0x{correct_vaddr:x}")

        # Patch DT_STRTAB d_val in .dynamic
        f.seek(strtab_dyn_fpos)
        f.write(struct.pack("<Q", correct_vaddr))

        # Patch .dynstr section header sh_addr for consistency
        f.seek(dynstr_shdr_pos + 16)
        f.write(struct.pack("<Q", correct_vaddr))


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
    global _allowed_prefixes

    # Parse arguments: [--policy manylinux|musllinux] <r-install-path>
    args = sys.argv[1:]
    policy_name = "manylinux"  # default
    if "--policy" in args:
        idx = args.index("--policy")
        if idx + 1 >= len(args):
            print("ERROR: --policy requires a value (manylinux or musllinux)", file=sys.stderr)
            sys.exit(1)
        policy_name = args[idx + 1]
        args = args[:idx] + args[idx + 2:]

    if policy_name not in POLICIES:
        print(f"ERROR: unknown policy '{policy_name}'. Use: {', '.join(POLICIES)}", file=sys.stderr)
        sys.exit(1)

    _allowed_prefixes = POLICIES[policy_name]

    if len(args) != 1:
        print("Usage: delocate_r.py [--policy manylinux|musllinux] <r-install-path>", file=sys.stderr)
        sys.exit(1)

    r_path = Path(args[0]).resolve()
    if not r_path.is_dir():
        print(f"ERROR: R installation not found at {r_path}", file=sys.stderr)
        sys.exit(1)

    libs_sdir = "lib/R/lib/.libs"
    dest_dir = r_path / libs_sdir

    print(f"delocate_r: repairing {r_path} (in-place, policy={policy_name})")

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
    all_external_libs: dict[str, str] = {}
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
        all_external_libs.update(new_libs)

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

    # Phase 5b: Fix patchelf strtab misalignment (patchelf 0.18.0 bug)
    # Must run after all patchelf writes are done, before verification.
    patched_files = set(all_soname_path.values()) | set(all_elf_needs.keys())
    for elf in patched_files:
        fix_patchelf_strtab(elf)

    # Phase 6: Verify repair
    print("  Verifying repair...")
    verify_repair(all_soname_map, all_soname_path, all_elf_needs, dest_dir, r_path)

    # Phase 7: Write delocate manifest
    # Maps each bundled (hash-renamed) filename to its original system path.
    # Used by generate_sbom.py to trace libraries back to source packages.
    manifest: dict[str, str] = {}
    for soname, dest_path in all_soname_path.items():
        new_soname = all_soname_map[soname]
        # external_libs had {soname: src_path} across iterations; the src_path
        # was resolved before grafting. Recover it from dest_path metadata:
        # we know the original path from the accumulated external_libs.
        manifest[new_soname] = all_external_libs.get(soname, "unknown")
    manifest_path = dest_dir / "delocate-manifest.json"
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"  Wrote {manifest_path} ({len(manifest)} entries)")

    print(f"delocate_r: done. Bundled {total} libraries into {libs_sdir}/")


if __name__ == "__main__":
    main()
