# Plan: Portable manylinux_2_28 R Build

## TL;DR

Add a new `manylinux-2-28` platform to r-builds (reusing the centos-8 Docker image)
that builds R and then runs a post-build portability step: auditwheel-r + patchelf
bundle system library dependencies into the R installation and rewrite RPATHs,
producing portable R artifacts conforming to the manylinux_2_28 standard.

A portable **tar.gz** is produced for direct extraction to any path on glibc 2.28+ systems.

## Installation

### Quick start

```bash
R_VERSION=4.4.2

# Download (or copy from build output)
# tar.gz is at: builder/integration/tmp/r/manylinux-2-28/R-${R_VERSION}-manylinux-2-28.tar.gz

# Extract
mkdir -p /opt/R
tar xzf R-${R_VERSION}-manylinux-2-28.tar.gz -C /opt/R

# Add to PATH
export PATH=/opt/R/${R_VERSION}/bin:$PATH

# Verify
R --version
```

### System dependencies

The manylinux build bundles most library dependencies (~65 shared libraries),
but some system packages are still required. These fall into three categories:

#### 1. Runtime: SSL/TLS certificates (required for HTTPS)

R auto-detects the CA certificate bundle via `CURL_CA_BUNDLE` (set in
`etc/ldpaths`), but the certificate files themselves must be installed.

| Distro | Package | Cert path |
|---|---|---|
| Ubuntu/Debian | `ca-certificates` | `/etc/ssl/certs/ca-certificates.crt` |
| RHEL/Fedora/Rocky | `ca-certificates` | `/etc/pki/tls/certs/ca-bundle.crt` |
| openSUSE/SLES | `ca-certificates` | `/etc/ssl/ca-bundle.pem` |

#### 2. Optional: build tools for `R CMD INSTALL` (for source packages)

Only needed if you install R packages from source that contain C/C++/Fortran
code. R's `Makeconf` links against `-lpcre2-8 -llzma -lbz2 -lz -licuuc -licui18n`,
so the corresponding `-dev`/`-devel` packages must also be installed.

**Ubuntu/Debian:**
```bash
apt-get install -y \
  build-essential gfortran \
  libpcre2-dev liblzma-dev libbz2-dev zlib1g-dev libicu-dev
```

**RHEL/Fedora/Rocky:**
```bash
dnf install -y \
  gcc gcc-c++ gcc-gfortran make \
  pcre2-devel xz-devel bzip2-devel zlib-devel libicu-devel
```

**openSUSE/SLES:**
```bash
zypper install -y \
  gcc gcc-c++ gcc-fortran make \
  pcre2-devel xz-devel libbz2-devel zlib-devel libicu-devel
```

### What's bundled (not needed on the system)

The tarball bundles all of the following, no system packages required:

- OpenBLAS (as libRblas.so), LAPACK (as libRlapack.so)
- OpenSSL / libcurl / libssh2
- readline, ncurses
- libtiff, libjpeg, libpng, freetype, fontconfig, harfbuzz
- X11 libs (libX11, libSM, libICE, libXt, libXext, libXrender, libXmu)
- cairo, pango, pixman, fontconfig
- GLib, GObject
- Tcl/Tk (shared libs + scripts)
- ICU data/runtime libraries

### Relocatability

The tarball can be extracted to any path. R auto-detects its location at
startup. The standard install path is `/opt/R/<version>/`, but any path works:

```bash
tar xzf R-4.4.2-manylinux-2-28.tar.gz -C /usr/local
/usr/local/4.4.2/bin/R --version  # works
```

## Background

### What is manylinux_2_28?

A portability standard (from Python's PEP 600) that defines a minimum set of system
libraries guaranteed to be available on any Linux distro with glibc >= 2.28 (RHEL 8+,
Ubuntu 20.04+, Debian 11+, etc.). Binaries targeting this standard bundle all other
dependencies and use RPATH to find them at runtime.

### Why?

Current r-builds R binaries link against system libraries at their build-time paths.
They only work on the specific distro they were built for. A manylinux_2_28-portable
R binary works across all glibc 2.28+ distros from a single build.

### Prior art

- Posit's rspm-builder-images use `manylinux_2_28` Docker images (based on Rocky
  Linux 8) with auditwheel-r to produce portable R binary packages.
- A POC was done confirming the approach works for R itself, with specific issues
  identified and now addressed in this plan.

## POC Root Cause Analysis

Three issues were found in the original POC:

1. **Segfault when running R from a different path**: The `bin/R` shell script has
   `R_HOME_DIR` hardcoded to the build-time prefix (e.g., `/opt/R/4.4.2/lib64/R`).
   When moved, it tries to source a nonexistent `ldpaths` file, so `LD_LIBRARY_PATH`
   is never set, and the exec binary can't find `libR.so`.

2. **libSM.so.6 / libICE.so.6 missing on Ubuntu**: These are in the manylinux_2_28
   allowlist (expected on the target system). auditwheel-r correctly didn't bundle
   them. On minimal Ubuntu without X11 packages, `R_X11.so` fails to load — but this
   is non-fatal.

3. **System libs in lsof output**: Was observed on the build machine (which has all
   system libs). After the `bin/R` script fix, bundled libs loaded correctly from
   `libs/.libs/`.

## Design Decisions

### New platform: `manylinux-2-28`

Following the existing r-builds pattern (and the rspm-builder-images convention),
`manylinux-2-28` is a new platform that **reuses the centos-8 Docker image** as a
base but adds portability tooling (patchelf, auditwheel-r) and a portability
post-processing step. This gives us:

- `Dockerfile.manylinux-2-28` — extends centos-8 with patchelf + auditwheel-r
- `package.manylinux-2-28` — runs portability post-processing (delocate-r.py)
- Standard Makefile/compose targets: `build-r-manylinux-2-28`, `test-r-manylinux-2-28`, etc.

### X11 support: Keep it (Option B)

R is built `--with-x` (same as centos-8). The X11 libraries (`libSM.so.6`,
`libICE.so.6`, `libX11.so.6`, `libXt.so.6`) are **in the manylinux_2_28 allowlist**
and are NOT bundled. This means:

- On systems with X11 libs installed (most desktop/server systems): full X11 graphics
  support works.
- On minimal/container systems without X11: `R_X11.so` won't load, but R still works
  (Cairo, png, pdf graphics are unaffected). R already handles this gracefully with a
  warning.
- If X11-free builds are ever needed, a `--without-x` configure option can be added
  as a future variant.

### BLAS handling

The standard centos-8 build swaps `libRblas.so` to a symlink pointing at system
OpenBLAS (for runtime BLAS swapping). For portable builds, we **bundle OpenBLAS
directly** via auditwheel-r. Users lose runtime BLAS swapping but gain cross-distro
portability. The `libRblas.so.keep` (original reference BLAS) is removed before repair
so auditwheel-r resolves the OpenBLAS dependency cleanly.

### Patch scripts for R_HOME portability

The `bin/R` shell script fix must work across R 3.0 through 4.5+. Rather than
maintaining per-version `.patch` files, use a **post-install sed script** (in
`package.manylinux-2-28`) that modifies the installed `bin/R` script after
`make install`. The `R_HOME_DIR=` assignment in `R.sh.in` has been structurally stable
since R 2.x, so a single sed replacement works across all supported versions.

## Implementation

### Phase 1: Docker image (`Dockerfile.manylinux-2-28`)

Create `Dockerfile.manylinux-2-28` that extends the centos-8 image and installs:

- OpenBLAS (`openblas-threads`) — needed at package time so auditwheel-r can bundle it
- patchelf 0.17.2 (from GitHub releases — avoid 0.18.0 per known issues, same version
  as rspm-builder-images)
- Python 3.12 (`dnf install python3.12 python3.12-pip`)
- auditwheel-r (installed from a pre-built wheel copied into the image; the wheel is
  built from a local checkout of `rstudio/auditwheel-r` with the `Path` bug fix)

### Phase 2: Portability script (`package.manylinux-2-28`)

Runs inside Docker after `build.sh` compiles and installs R:

1. **BLAS setup**: Remove the existing `libRblas.so` and copy system OpenBLAS
   (`libopenblasp.so.0`) in its place, so auditwheel-r can trace and bundle
   a real BLAS library.

2. **Run auditwheel-r repair**:
   ```
   auditwheel-r repair /opt/R/${R_VERSION}/ --no-update-tags --no-strip
   ```
   - `--no-update-tags`: Skip R package DESCRIPTION/rds metadata (not applicable to R itself)
   - `--no-strip`: Preserve symbols for now
   - Bundles ~20 external libs into `libs/.libs/` with hashed filenames
   - Rewrites RPATHs on all ELF binaries to `$ORIGIN/<relative-path-to-libs/.libs>`
   - Output to `wheelhouse/`

3. **Replace R installation**: `rm -rf /opt/R/${R_VERSION} && mv wheelhouse /opt/R/${R_VERSION}`

4. **Fix BLAS/LAPACK SONAMEs**: Use `patchelf --set-soname` to ensure libRblas.so and
   libRlapack.so have correct SONAMEs matching their filenames, so compiled R packages
   record the right dependency names.

5. **Bundle Tcl/Tk scripts + SSL CA detection**: Copy Tcl/Tk library directories and
   set `TCL_LIBRARY`/`TK_LIBRARY` in `etc/ldpaths`. Also add `CURL_CA_BUNDLE`
   auto-detection to `etc/ldpaths` for cross-distro HTTPS support.

6. **Make `bin/R` relocatable**: sed-replace the hardcoded `R_HOME_DIR=...` line
   with self-detecting logic that derives R_HOME from the script's own filesystem
   location using `readlink -f`, making it fully relocatable.

7. **Verify library resolution**: Print RPATH and bundled lib info (informational).

8. **Clean up artifacts**: Remove top-level `DESCRIPTION` file if created by auditwheel-r.

The tar.gz is created by `archive_r` in `build.sh`. No DEB/RPM packages are produced
   because distro-specific package dependencies would defeat the purpose of a
   universal build.

### Phase 3: Integration

- Add docker-compose service for `manylinux-2-28` in `builder/docker-compose.yml`.
- Add `manylinux-2-28` to `PLATFORMS` in `Makefile`.
- Add test service in `test/docker-compose.yml` using a different base image
  (e.g., Ubuntu 20.04) to validate cross-distro portability.

### Phase 4: Testing

- Test on build platform (CentOS 8/Rocky 8): R starts, `sessionInfo()`, `ldd` shows bundled libs.
- Test on different distro (Ubuntu 20.04): R starts, package installation works, `capabilities()`.
- Verify with `ldd`/`readelf`/`lsof` that only manylinux_2_28-allowed libs come from system paths.
- Relocatability test: move to a different path, verify R starts.

## New Files

- `builder/Dockerfile.manylinux-2-28` — Docker image extending centos-8 with portability tools
- `builder/package.manylinux-2-28` — Post-build portability script

## Verification Checklist

1. `auditwheel-r show /opt/R/<version>/` — manylinux_2_28 compliant
2. `ldd lib/R/lib/libR.so` — bundled deps resolve to `libs/.libs/` paths
3. `ldd lib/R/modules/R_X11.so` — allowed X11 libs show as system deps (expected)
4. `readelf -d lib/R/bin/exec/R` — may have limited RPATH (non-PIE binary; relies on
   `LD_LIBRARY_PATH` from `etc/ldpaths` rather than RPATH)
5. On Ubuntu 20.04: R starts, `capabilities()` shows TRUE for jpeg/png/tiff/tcltk/cairo/ICU/libcurl
6. Relocatability: `mv /opt/R/<ver> /tmp/R-test && /tmp/R-test/bin/R -e 'cat("works\n")'`
7. Tarball install on clean Ubuntu/Rocky/openSUSE: extract, R works

## Future Enhancements (v2)

### Makeconf relocatability

`lib/R/etc/Makeconf` contains hardcoded absolute paths set at configure time (`prefix`,
`exec_prefix`, `libdir`, etc.). These paths are used by `R CMD INSTALL` when compiling
packages. At the canonical install path `/opt/R/<version>/`, this works fine. But for
fully relocatable R (install at arbitrary paths), Makeconf needs these paths made
relative to `R_HOME` or dynamically resolved. This is the main blocker for true
relocatability and should be addressed in v2.

Approach options:
- Post-install sed to replace absolute prefix paths with `$(R_HOME)/..` relative equivalents
- Runtime-generated Makeconf (like R does for `R_HOME` in the shell script)
- Upstream R changes (unlikely to be accepted near-term)

### ARM64 support

The centos-8 Docker image supports ARM64. The manylinux-2-28 platform should work on
ARM64 with minimal changes (patchelf and auditwheel-r support it).

### Other base distros

Could add manylinux_2_31 (Debian 11 / Ubuntu 20.04 glibc) or manylinux_2_34 (RHEL 9
glibc) variants if needed.

### X11-free variant

If minimal/container deployments need guaranteed X11-free R, add a
`manylinux-2-28-nox11` variant built with `--without-x`.

### Bundle X11 libraries

Currently, X11 libs (`libX11.so.6`, `libSM.so.6`, `libICE.so.6`, `libXt.so.6`,
`libXext.so.6`, `libXrender.so.1`) are on the manylinux_2_28 allowlist and NOT
bundled. On minimal containers without X11 packages, `R_X11.so` fails to load (with a
non-fatal warning). Bundling these would make R fully self-contained.

**Symbol conflict risk:** Low. auditwheel-r hash-renames bundled libs (e.g.,
`libX11-a1b2c3d4.so.6`), so the dynamic linker treats them as different libraries from
any system-installed libX11. Both can coexist in the same process without symbol
conflicts. python-build-standalone had this issue with statically-linked libX11 (fixed
by hiding symbols), but hash-renamed shared libs avoid it entirely.

**Options:**

1. **Patch auditwheel-r's allowlist** (~10 lines). In `r_abi.py`, subtract X11 libs
   from the allowlist in `r_wheel_policies()`. Rebuild the wheel. Everything else works
   as-is — auditwheel-r will discover, copy, hash-rename, and RPATH-fix the X11 libs
   automatically. Pros: minimal change. Cons: still depends on auditwheel-r and its
   Python 3.12 + pyelftools dependency chain.

2. **Replace auditwheel-r with a shell script** using `ldd` + `patchelf`. A ~150-line
   bash script can replicate what auditwheel-r does:
   - Walk all ELF files (find + file command)
   - Run `ldd` on each, filter against a hardcoded allowlist
   - Copy non-allowed libs to `libs/.libs/` with SHA256-hash-renamed filenames
   - `patchelf --set-soname` on each copied lib
   - `patchelf --replace-needed` on every ELF that references the old soname
   - `patchelf --set-rpath` to add `$ORIGIN`-relative path to `libs/.libs/`
   - Fix inter-library DT_NEEDED references (grafted libs referencing each other)

   Pros: no Python dependency, full control over the allowlist (just a bash array),
   no need to maintain an auditwheel-r fork. Cons: we own the maintenance of edge
   cases that auditwheel-r handles (though for a single R installation rather than
   arbitrary R packages, the edge cases are limited).

3. **Hybrid approach**: keep auditwheel-r for the main repair, then use patchelf in a
   post-step to manually bundle X11 libs. This is the least clean option.

**What auditwheel-r actually does (full analysis):**

The repair pipeline has these steps, all of which are straightforward patchelf/ldd
operations:

1. Copy the input directory to a temp dir
2. Walk all files, identify ELF binaries (check magic bytes via pyelftools)
3. For each ELF, run upstream auditwheel's `ldd()` (a pure-Python ldd reimplementation
   that parses DT_NEEDED, resolves via RPATH/RUNPATH/LD_LIBRARY_PATH/ldconfig)
4. Compare each needed lib against the policy allowlist. Non-allowed = "external"
5. For each external lib:
   a. Compute SHA256 hash of the source file, take first 8 chars
   b. Copy to `libs/.libs/` as `libfoo-<hash>.so.N`
   c. `patchelf --set-soname <new-name>` on the copy
   d. If the copy has any RPATH/RUNPATH, set to `$ORIGIN`
6. For each ELF that had external deps:
   a. `patchelf --replace-needed <old-soname> <new-soname>` for each
   b. `patchelf --set-rpath` with `$ORIGIN`-relative path to `libs/.libs/`, preserving
      existing within-package RPATHs
7. Fix inter-library references: grafted libs may DT_NEED each other, update those
   from old sonames to new hash-renamed sonames
8. Optionally: strip symbols, update DESCRIPTION/Meta platform tags
9. Copy result to output directory

**Edge cases handled by auditwheel-r that a shell script must also handle:**
- Libraries that can't be found (src_path is None): auditwheel-r raises an error for
  libRblas/libRlapack, warns+skips for internal package libs. For R itself, all libs
  should be findable via LD_LIBRARY_PATH.
- RPATH token resolution ($ORIGIN, $LIB, $PLATFORM): the ldd implementation handles
  these. System `ldd` handles them natively.
- Non-ELF files (R scripts, data files): skipped by checking ELF magic bytes. `file`
  command or checking for `.so` suffix works.
- Duplicate libs: copylib() is idempotent (skips if dest already exists).
- Preserving in-package RPATHs: the RPATH setter keeps existing entries pointing within
  the package tree.

**Recommendation:** Option 2 (shell script) is cleanest for this use case. We're
repairing a single R installation (not arbitrary R packages), so the scope is well
defined. The shell script eliminates the Python 3.12 dependency, the auditwheel-r
wheel build, the pyelftools dependency, and the `Path` vs `str` bug we had to fix.

---

## Implementation Notes & Retrospective

### What was built

A new `manylinux-2-28` platform producing three portable R 4.4.2 distribution formats
from a single build on Rocky 8 (glibc 2.28):

- **tar.gz** (~106MB) — direct extraction, tested on Ubuntu Noble, Rocky 8, Rocky 10, openSUSE 15.6

All standard tests pass: R starts, sessionInfo works,
capabilities (jpeg/png/tiff/tcltk/cairo/ICU/libcurl all TRUE), package compilation
with C/C++/Fortran + BLAS/LAPACK linking, HTTPS downloads, and relocatability (move R
to an arbitrary path, it still works).

No DEB/RPM packages are produced — distro-specific dependencies would defeat the
purpose of a universal build.

### Files created/modified

New files:
- `builder/Dockerfile.manylinux-2-28` — extends centos-8 with patchelf 0.17.2,
  Python 3.12, auditwheel-r
- `builder/package.manylinux-2-28` — post-build portability + packaging script
- `test/test-manylinux.sh` — cross-distro test on Ubuntu 20.04

Modified files:
- `Makefile` — added `manylinux-2-28` to PLATFORMS
- `builder/docker-compose.yml` — added manylinux-2-28 build service
- `test/docker-compose.yml` — added manylinux-2-28 test service (ubuntu:focal)

External fix:
- `~/auditwheel-r/src/auditwheel_r/rtools.py` — fixed `Path` vs `str` bug in
  `InRPackageDirCtx.iter_files()` (directory mode returned strings but
  `elf_file_filter` expected Path objects with `.suffix`).

### Post-build phases (package.manylinux-2-28)

Phases match the actual code in `package.manylinux-2-28`:

1. **BLAS setup**: remove existing `libRblas.so`, copy system OpenBLAS
   (`libopenblasp.so.0`) as `lib/R/lib/libRblas.so`
2. **auditwheel-r repair**: bundle non-allowed system libs, rewrite RPATHs.
   `LD_LIBRARY_PATH` includes R's lib dir so auditwheel-r can find libRblas.so.
3. **Replace R installation** with repaired output from wheelhouse
3b. **Fix BLAS/LAPACK SONAMEs**: `patchelf --set-soname` on libRblas.so and
    libRlapack.so so compiled packages record the correct dependency names
3c. **Bundle Tcl/Tk scripts + SSL CA detection**: copy `/usr/share/tcl8.6` and
    `/usr/share/tk8.6` into `lib/R/share/`, then append to `etc/ldpaths`:
    `TCL_LIBRARY`/`TK_LIBRARY` env vars and `CURL_CA_BUNDLE` auto-detection
    (probes Debian, RHEL, SUSE cert paths)
4. **Make bin/R relocatable**: sed-replace hardcoded `R_HOME_DIR` with `readlink -f`
   self-detection
5. **Verify library resolution**: print RPATH info (informational only)
6. **Clean up**: remove DESCRIPTION artifact created by auditwheel-r
7. **Done**: tar.gz created by `archive_r` in `build.sh`

### Issues encountered and how they were resolved

#### 1. auditwheel-r `str` vs `Path` bug
**Problem**: auditwheel-r's directory repair mode (`InRPackageDirCtx.iter_files()`)
yielded plain strings, but downstream `elf_file_filter()` called `.suffix` on them,
which is a `Path` attribute. Crashed with `AttributeError`.
**Fix**: Wrapped yields in `rtools.py` with `Path()`. Rebuilt the wheel.

#### 2. auditwheel-r couldn't find libRblas.so
**Problem**: During repair, auditwheel-r uses `ldd` to trace dependencies but couldn't
resolve `libRblas.so` because it's not in standard library paths.
**Fix**: Export `LD_LIBRARY_PATH="${R_LIB_DIR}"` before running `auditwheel-r repair`.

#### 3. patchelf `--add-rpath` crashes on non-PIE executables
**Problem**: R's `lib/R/bin/exec/R` is a non-PIE EXEC type binary (not PIE/DYN).
`patchelf --add-rpath` tries to expand the binary but can't handle EXEC type, and
crashes. `--set-rpath` works but only if the new value fits in existing RPATH space.
**Fix**: Removed RPATH additions entirely for the exec binary. R's standard mechanism
is `etc/ldpaths` (sourced by `bin/R` shell script before exec), which sets
`LD_LIBRARY_PATH` to find `libR.so`. This already works for the portable case since
`etc/ldpaths` uses `${R_HOME}` (relative, not hardcoded).

#### 4. OpenBLAS not installed in Docker image
**Problem**: The centos-8 base image doesn't install OpenBLAS at build time — the
centos-8 platform swaps in OpenBLAS at RPM install time. The manylinux-2-28 build
needs OpenBLAS present at package time so auditwheel-r can bundle it.
**Fix**: Added `openblas-threads` to the manylinux-2-28 Dockerfile.

#### 5. BLAS SONAME mismatch breaks package compilation on target
**Problem**: `lib/R/lib/libRblas.so` (copied from system OpenBLAS) retained its
original SONAME `libopenblasp.so.0`. When users compile R packages that link via
`-lRblas` (from Makeconf's BLAS_LIBS), the linker records `libopenblasp.so.0` as the
NEEDED entry. On the target system, `libopenblasp.so.0` doesn't exist, and the
compiled package fails to load.
**Fix**: `patchelf --set-soname libRblas.so` (and same for libRlapack.so) so packages
record `libRblas.so` as their dependency. This is always found via `LD_LIBRARY_PATH`.

#### 6. Tcl/Tk `init.tcl` not found on target
**Problem**: The bundled `libtcl8.6.so` has the CentOS 8 path to Tcl scripts
(`/usr/share/tcl8.6`) compiled in. On Ubuntu, Tcl scripts live somewhere else or
aren't installed. Even with `tcl` package installed, the built-in search paths inside
libtcl didn't find `init.tcl`.
**Fix**: Bundle the Tcl/Tk script directories (~4.3MB total) into
`lib/R/share/tcl8.6` and `lib/R/share/tk8.6`, then set `TCL_LIBRARY` and `TK_LIBRARY`
environment variables in `etc/ldpaths`.

#### 7. SSL certificate bundle path differs across distros
**Problem**: The bundled `libcurl` was compiled on CentOS 8 and looks for CA
certificates at `/etc/pki/tls/certs/ca-bundle.crt`. On Ubuntu, certs are at
`/etc/ssl/certs/ca-certificates.crt`. HTTPS downloads fail with "Problem with the SSL
CA cert".
**Fix**: Added auto-detection logic in `etc/ldpaths` that probes common CA bundle
paths (Debian/Ubuntu, RHEL/CentOS, SUSE) and exports `CURL_CA_BUNDLE` if not already
set.

#### 8. SSL fails on minimal containers without `ca-certificates`
**Problem**: On Ubuntu Noble (24.04) minimal containers, `install.packages()` fails
with SSL cert errors. Investigation showed `/etc/ssl/` doesn't even exist — the
`ca-certificates` package is not installed.
**Resolution**: Not a code bug. The `CURL_CA_BUNDLE` detection in `etc/ldpaths` works
correctly but has nothing to find when no CA certs are installed on the system. The DEB
package declares `ca-certificates` as a dependency (auto-installed). The tarball
requires the user to install `ca-certificates` manually. This is inherent to any
portable binary that relies on system trust stores.

#### 9. Missing `less` pager
**Problem**: R's `help()` function requires a pager (defaults to `less`). On minimal
containers, `less` is not installed and `help()` fails silently.
**Fix**: Added `less` to the test script's dependency list. The DEB/RPM packages don't
declare `less` as a dependency (it's optional), but users should be aware that help
display requires a pager.

#### 10. `lib/R/bin/R` not patched — `R CMD INSTALL` fails when relocated
**Problem**: R installs two copies of the `R` shell script: `bin/R` (at the prefix
level) and `lib/R/bin/R` (inside R_HOME). Only `bin/R` was patched with the
`readlink -f` self-detection logic. When `R CMD INSTALL` runs (e.g., during
`install.packages()`), it spawns a subprocess calling `lib/R/bin/R` directly. That
script still had `R_HOME_DIR=/opt/R/4.4.2/lib/R` hardcoded, so at a relocated path
it fails with: `. /opt/R/4.4.2/lib/R/etc/ldpaths: No such file`.
**Fix**: Patch both scripts, with different formulas since they're at different depths:
- `bin/R` (at `<prefix>/bin/R`): `R_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")/lib/R"`
- `lib/R/bin/R` (at `<R_HOME>/bin/R`): `R_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"` (no `/lib/R` suffix — two levels up is already R_HOME)
Same treatment for `Rscript`. Symlinks are skipped (only regular files are patched).

### Surprising things

- **`etc/ldpaths` is the key integration point**. It's sourced by `bin/R` before
  exec'ing the real binary, and it's the natural place to set environment variables for
  portability (LD_LIBRARY_PATH, TCL_LIBRARY, TK_LIBRARY, CURL_CA_BUNDLE). R already
  designed this for relocatability — we just needed to extend it.

- **auditwheel-r handles R's complex library layout well**. Despite R having libs in
  `lib/R/lib/`, modules in `lib/R/modules/`, and package `.so` files in
  `lib/R/library/*/libs/`, auditwheel-r correctly traced and bundled all dependencies
  into a single `libs/.libs/` directory with `$ORIGIN`-relative RPATHs.

- **The SONAME issue was subtle**: the linker records the SONAME (not the filename) in
  NEEDED entries. When you copy `libopenblasp.so.0` to `libRblas.so`, the SONAME is
  still `libopenblasp.so.0`, so any package compiled against `-lRblas` actually records
  a dependency on `libopenblasp.so.0`. This only manifests at load time on a different
  system.

- **Non-PIE exec binary is unusual**: modern Linux binaries are typically PIE (Position
  Independent Executable), but R's `lib/R/bin/exec/R` is a traditional EXEC type. This
  breaks `patchelf --add-rpath` but doesn't matter in practice because `bin/R` (the
  shell script wrapper) sets up the environment before exec'ing the binary.

- **R's `bin/R` is a shell script, not a binary**. The real binary is at
  `lib/R/bin/exec/R`. This two-layer design (shell wrapper → exec binary) is what makes
  relocatability possible — the shell script can compute paths dynamically before
  handing off to the binary.

- **R installs TWO copies of the `R` shell script**: `bin/R` (at prefix level) and
  `lib/R/bin/R` (inside R_HOME). They are separate files, not symlinks. Both have
  `R_HOME_DIR` hardcoded. `bin/R` is what users invoke; `lib/R/bin/R` is what R's
  internal tools (`R CMD INSTALL`, etc.) invoke via `R_HOME/bin/R`. Both must be
  patched for relocatability, but with different path formulas because they sit at
  different depths in the directory tree.

- **Portable binaries can't bundle the system trust store**. Unlike shared libraries
  (which are self-contained ELF files that can be copied), SSL CA certificates are a
  system-level concern managed by `ca-certificates` (Debian) or `ca-trust` (RHEL).
  The portable R can detect _where_ certificates are on a given distro, but it can't
  bundle them. On minimal containers that lack `ca-certificates` entirely (e.g.,
  Ubuntu Noble), HTTPS will fail regardless of runtime detection logic.

### Known limitations

1. **Makeconf has hardcoded paths**: `lib/R/etc/Makeconf` contains absolute paths from
   configure time (e.g., `-I/opt/R/4.4.2/lib/R/include`). Package compilation works
   because R sets these values at runtime, but some Makeconf variables may break at
   non-standard install paths. This is a v2 enhancement.

2. **X11 requires system packages**: `libX11.so.6`, `libXt.so.6`, etc. are
   manylinux_2_28 allowed (not bundled). On minimal containers without X11 libs,
   `capabilities("X11")` returns FALSE and `R_X11.so` won't load. R handles this
   gracefully — all other graphics backends (cairo, png, pdf, svg) work.

3. **No runtime BLAS swapping**: Unlike the standard centos-8 build where
   `libRblas.so` is a symlink to system BLAS (allowing swaps to MKL, etc.), the
   portable build bundles OpenBLAS directly. Users cannot swap BLAS without rebuilding.

4. **Tcl/Tk hardcoded to 8.6**: The bundled Tcl/Tk scripts assume version 8.6.
   If the build system's Tcl version changes, the phase needs updating.

5. **`libxml` capability is FALSE**: R reports `libxml = FALSE` in `capabilities()`.
   This is because the test checks for `libxml2` headers at compile time via
   `xml2-config`, which is a compile-time concern, not a runtime portability issue.
   R's internal XML support is unaffected.

6. **Target system needs basic runtime libs**: While the builds are portable, the
   target system still needs: glibc >= 2.28, a C/C++/Fortran compiler (for package
   compilation), `ca-certificates` (for HTTPS — the SSL cert detection in `ldpaths`
   requires cert files to exist on disk), and manylinux_2_28 allowed libs (X11,
   pango, cairo, glib for full capabilities). The DEB/RPM packages declare these as
   dependencies so they are installed automatically; the tarball requires them to be
   installed manually (see [Installation](#installation) above). On minimal containers
   (e.g., Ubuntu Noble), `ca-certificates` is notably absent by default.

### Testing commands

```bash
# Build the Docker image
docker compose -f builder/docker-compose.yml build manylinux-2-28

# Build R (takes ~10 min)
R_VERSION=4.4.2 docker compose -f builder/docker-compose.yml run --rm manylinux-2-28

# Run e2e tests on all 4 distros
R_VERSION=4.4.2 docker compose -f test/docker-compose.yml run --rm manylinux-2-28
R_VERSION=4.4.2 docker compose -f test/docker-compose.yml run --rm manylinux-2-28-centos-8
R_VERSION=4.4.2 docker compose -f test/docker-compose.yml run --rm manylinux-2-28-rhel-10
R_VERSION=4.4.2 docker compose -f test/docker-compose.yml run --rm manylinux-2-28-opensuse-156

# Run unit tests for delocate-r.py
cd builder && python3 -m pytest test_delocate_r.py -v
```
