# Plan: Portable manylinux_2_28 R Build

## TL;DR

Add a new `manylinux_2_28` platform to r-builds (reusing the centos-8 Docker image)
that builds R and then runs a post-build portability step: `delocate-r.py` + patchelf
bundle system library dependencies into the R installation and rewrite RPATHs,
producing portable R artifacts conforming to the manylinux_2_28 standard.

A portable **tar.gz** is produced for direct extraction to any path on glibc 2.28+ systems.

## Installation

### Quick start

```bash
R_VERSION=4.4.2

# Download (or copy from build output)
# tar.gz is at: builder/integration/tmp/r/manylinux_2_28/R-${R_VERSION}-manylinux_2_28.tar.gz

# Extract
mkdir -p /opt/R
tar xzf R-${R_VERSION}-manylinux_2_28.tar.gz -C /opt/R

# Add to PATH
export PATH=/opt/R/${R_VERSION}/bin:$PATH

# Verify
R --version
```

### System dependencies

The manylinux build bundles most library dependencies (~65 shared libraries),
but some system packages are still required. These fall into three categories:

#### 1. Runtime: SSL/TLS certificates and font configuration (required)

R auto-detects the CA certificate bundle via `CURL_CA_BUNDLE` (set in
`etc/ldpaths`), but the certificate files themselves must be installed.
The bundled fontconfig library needs system font configuration files
(`/etc/fonts/fonts.conf`) for text rendering in plots.

| Distro | Package | Notes |
|---|---|---|
| Ubuntu/Debian | `ca-certificates fontconfig` | SSL certs + font config |
| RHEL/Fedora/Rocky | `ca-certificates fontconfig` | SSL certs + font config |
| openSUSE/SLES | `ca-certificates fontconfig` | SSL certs + font config |

#### 2. Optional: build tools for `R CMD INSTALL` (for source packages)

Only needed if you install R packages from source that contain C/C++/Fortran
code. R's `Makeconf` links against `-lpcre2-8 -llzma -lbz2 -lz -licuuc -licui18n`
(R 4.x) or `-lpcre -llzma -lbz2 -lz -licuuc -licui18n` (R 3.x),
so the corresponding `-dev`/`-devel` packages must also be installed.

**Ubuntu/Debian:**
```bash
apt-get install -y \
  build-essential gfortran \
  libpcre2-dev liblzma-dev libbz2-dev zlib1g-dev libicu-dev
  # For R 3.x, also install: libpcre3-dev
```

**RHEL/Fedora/Rocky:**
```bash
dnf install -y \
  gcc gcc-c++ gcc-gfortran make \
  pcre2-devel xz-devel bzip2-devel zlib-devel libicu-devel
  # For R 3.x, also install: pcre-devel
```

**openSUSE/SLES:**
```bash
zypper install -y \
  gcc gcc-c++ gcc-fortran make \
  pcre2-devel xz-devel libbz2-devel zlib-devel libicu-devel
  # For R 3.x, also install: pcre-devel
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
tar xzf R-4.4.2-manylinux_2_28.tar.gz -C /usr/local
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

2. **libSM.so.6 / libICE.so.6 missing on Ubuntu**: These were originally in the
   manylinux_2_28 allowlist (not bundled). Now resolved: delocate-r.py uses a
   narrower allowlist that bundles X11, cairo, pango, GLib, and all other non-glibc
   dependencies (~65 libraries total).

3. **System libs in lsof output**: Was observed on the build machine (which has all
   system libs). After the `bin/R` script fix, bundled libs loaded correctly from
   `lib/R/lib/.libs/`.

## Design Decisions

### New platform: `manylinux_2_28`

Following the existing r-builds pattern (and the rspm-builder-images convention),
`manylinux_2_28` is a new platform that **reuses the centos-8 Docker image** as a
base but adds portability tooling (patchelf, delocate-r.py) and a portability
post-processing step. This gives us:

- `Dockerfile.manylinux_2_28` -- extends centos-8 with patchelf
- `package.manylinux_2_28` -- runs portability post-processing (delocate-r.py)
- Standard Makefile/compose targets: `build-r-manylinux_2_28`, `test-r-manylinux_2_28`, etc.

### X11 support: bundled

R is built `--with-x` (same as centos-8). X11 libraries (`libX11.so.6`, `libSM.so.6`,
`libICE.so.6`, `libXt.so.6`, `libXext.so.6`, `libXrender.so.1`, `libXmu.so.6`) are
**bundled** by delocate-r.py despite being on the official manylinux_2_28 allowlist.
This ensures X11 graphics work even on minimal containers without system X11 packages.

### BLAS handling

The standard centos-8 build swaps `libRblas.so` to a symlink pointing at system
OpenBLAS (for runtime BLAS swapping). For portable builds, we **bundle OpenBLAS
directly** as `libRblas.so`. Users lose runtime BLAS swapping but gain cross-distro
portability. The `libRblas.so.keep` (original reference BLAS) is removed before repair
so delocate-r.py resolves the OpenBLAS dependency cleanly.

### Patch scripts for R_HOME portability

The `bin/R` shell script fix must work across R 3.0 through 4.5+. Rather than
maintaining per-version `.patch` files, use a **post-install sed script** (in
`package.manylinux_2_28`) that modifies the installed `bin/R` script after
`make install`. The `R_HOME_DIR=` assignment in `R.sh.in` has been structurally stable
since R 2.x, so a single sed replacement works across all supported versions.

## Implementation

### Phase 1: Docker image (`Dockerfile.manylinux_2_28`)

Create `Dockerfile.manylinux_2_28` that extends the centos-8 image and installs:

- OpenBLAS (`openblas-threads`) -- needed at package time so delocate-r.py can bundle it
- patchelf 0.17.2 (from GitHub releases -- avoid 0.18.0 per known issues, same version
  as rspm-builder-images)

### Phase 2: Portability script (`package.manylinux_2_28`)

Runs inside Docker after `build.sh` compiles and installs R:

1. **BLAS setup**: Remove the existing `libRblas.so` and copy system OpenBLAS
   (`libopenblasp.so.0`) in its place, so delocate-r.py can trace and bundle
   a real BLAS library.

2. **Run delocate-r.py repair**:
   ```
   python3 /delocate-r.py /opt/R/${R_VERSION}/
   ```
   - Bundles ~65 external libs into `lib/R/lib/.libs/` with hash-renamed filenames
   - Rewrites RPATHs on all ELF binaries to `$ORIGIN/<relative-path-to-lib/R/lib/.libs>`
   - Operates in-place (no wheelhouse copy step)

3. **Fix BLAS/LAPACK SONAMEs**: Use `patchelf --set-soname` to ensure libRblas.so and
   libRlapack.so have correct SONAMEs matching their filenames, so compiled R packages
   record the right dependency names.

5. **Bundle Tcl/Tk scripts + SSL CA detection**: Copy Tcl/Tk library directories and
   set `TCL_LIBRARY`/`TK_LIBRARY` in `etc/ldpaths`. Also add `CURL_CA_BUNDLE`
   auto-detection to `etc/ldpaths` for cross-distro HTTPS support.

6. **Make `bin/R` relocatable**: sed-replace the hardcoded `R_HOME_DIR=...` line
   with self-detecting logic that derives R_HOME from the script's own filesystem
   location using `readlink -f`, making it fully relocatable.

7. **Verify library resolution**: Print RPATH and bundled lib info (informational).

The tar.gz is created by `archive_r` in `build.sh`. No DEB/RPM packages are produced
   because distro-specific package dependencies would defeat the purpose of a
   universal build.

### Phase 3: Integration

- Add docker-compose service for `manylinux_2_28` in `builder/docker-compose.yml`.
- Add `manylinux_2_28` to `PLATFORMS` in `Makefile`.
- Add test service in `test/docker-compose.yml` using a different base image
  (e.g., Ubuntu 20.04) to validate cross-distro portability.

### Phase 4: Testing

- Test on build platform (CentOS 8/Rocky 8): R starts, `sessionInfo()`, `ldd` shows bundled libs.
- Test on different distro (Ubuntu 20.04): R starts, package installation works, `capabilities()`.
- Verify with `ldd`/`readelf`/`lsof` that only manylinux_2_28-allowed libs come from system paths.
- Relocatability test: move to a different path, verify R starts.

## New Files

- `builder/Dockerfile.manylinux_2_28` -- Docker image extending centos-8 with portability tools
- `builder/package.manylinux_2_28` -- Post-build portability script
- `builder/delocate-r.py` -- Library bundling script
- `builder/test_delocate_r.py` -- Unit tests for delocate-r.py (51 tests)

## Verification Checklist

1. `ldd lib/R/lib/libR.so` -- bundled deps resolve to `lib/R/lib/.libs/` paths
2. `readelf -d lib/R/bin/exec/R` -- may have limited RPATH (non-PIE binary; relies on
   `LD_LIBRARY_PATH` from `etc/ldpaths` rather than RPATH)
3. On Ubuntu Noble: R starts, `capabilities()` shows TRUE for jpeg/png/tiff/tcltk/cairo/ICU/libcurl
4. Relocatability: `mv /opt/R/<ver> /tmp/R-test && /tmp/R-test/bin/R -e 'cat("works\n")'`
5. Tarball install on clean Ubuntu/Rocky/openSUSE: extract, R works

## TODO

- [x] Test other R versions -- locally tested R 3.1.3, 3.6.3, 4.0.5, 4.3.3, 4.4.2
      on Ubuntu Noble (all pass). devel is tested by CI on every push.
- [x] Makeconf relocatability -- verified not an issue. Makeconf uses `$(R_HOME)`
      for include/lib paths, which R resolves at runtime. Tested R CMD INSTALL at
      `/usr/local/custom-R/` (non-standard path) successfully.
- [x] ARM64 support -- built and tested R 4.4.2 on ARM64 (aarch64) via
      QEMU emulation. All integration tests pass. No code changes needed.

## Future Enhancements (v2)

### ARM64 support

Verified working. Built and tested R 4.4.2 on ARM64 (aarch64) via QEMU emulation.
The Dockerfile, delocate-r.py, and tarball naming all handle ARM64 natively -- no
code changes were needed. CI uses native ARM64 runners (`ubuntu-24.04-arm`).

### Other base distros

Could add manylinux_2_31 (Debian 11 / Ubuntu 20.04 glibc) or manylinux_2_34 (RHEL 9
glibc) variants if needed.

### Why delocate-r.py instead of auditwheel-r

The initial POC used `auditwheel-r` (Posit's fork of auditwheel for R packages).
We replaced it with a standalone `delocate-r.py` script (~450 lines, Python 3 stdlib
+ patchelf) for several reasons:

- **No external dependencies**: auditwheel-r requires Python 3.12, pyelftools, and a
  pre-built wheel. delocate-r.py uses only Python 3 stdlib + patchelf.
- **Full control over the allowlist**: auditwheel-r uses the manylinux_2_28 allowlist,
  which includes X11, GLib, and other libs we want to bundle. delocate-r.py uses a
  narrower allowlist (glibc core + compiler runtime only).
- **No fork maintenance**: auditwheel-r had a `Path` vs `str` bug we had to fix.
  delocate-r.py is self-contained.
- **Simpler workflow**: delocate-r.py operates in-place (no wheelhouse copy step).
- **Well-scoped**: we're bundling one R installation, not arbitrary R packages, so
  the edge cases are limited.

delocate-r.py replicates the core auditwheel-r pipeline: discover ELF files, run `ldd`
to find external deps, copy them with SHA256-hash-renamed filenames, rewrite SONAMEs
and RPATHs with patchelf, and fix inter-library DT_NEEDED references. A fixpoint loop
handles transitive dependencies.

---

## Implementation Notes & Retrospective

### What was built

A new `manylinux_2_28` platform producing a portable R 4.4.2 tar.gz
from a single build on Rocky 8 (glibc 2.28):

- **tar.gz** (~106MB) -- direct extraction, tested on Ubuntu Noble, Rocky 8, RHEL 10, openSUSE 15.6

All standard tests pass: R starts, sessionInfo works,
capabilities (jpeg/png/tiff/tcltk/cairo/ICU/libcurl all TRUE), package compilation
with C/C++/Fortran + BLAS/LAPACK linking, HTTPS downloads, and relocatability (move R
to an arbitrary path, it still works).

No DEB/RPM packages are produced -- distro-specific dependencies would defeat the
purpose of a universal build.

### Files created/modified

New files:
- `builder/Dockerfile.manylinux_2_28` -- extends centos-8 with patchelf 0.17.2
- `builder/package.manylinux_2_28` -- post-build portability script
- `builder/delocate-r.py` -- library bundling script
- `builder/test_delocate_r.py` -- 51 unit tests for delocate-r.py
- `test/test-manylinux.sh` -- cross-distro e2e tests

Modified files:
- `Makefile` -- added `manylinux_2_28` to PLATFORMS
- `builder/docker-compose.yml` -- added manylinux_2_28 build service
- `test/docker-compose.yml` -- added manylinux_2_28 test services (4 distros)

### Post-build phases (package.manylinux_2_28)

Phases match the actual code in `package.manylinux_2_28`:

1. **BLAS setup**: remove existing `libRblas.so`, copy system OpenBLAS
   (`libopenblasp.so.0`) as `lib/R/lib/libRblas.so`
2. **delocate-r.py repair**: bundle non-allowed system libs (~65), rewrite RPATHs.
   `LD_LIBRARY_PATH` includes R's lib dir so delocate-r.py can find libRblas.so.
   Operates in-place (no wheelhouse copy step).
3. **Fix BLAS/LAPACK SONAMEs**: `patchelf --set-soname` on libRblas.so and
    libRlapack.so so compiled packages record the correct dependency names
4. **Bundle Tcl/Tk scripts + SSL CA detection**: copy `/usr/share/tcl8.6` and
    `/usr/share/tk8.6` into `lib/R/share/`, then append to `etc/ldpaths`:
    `TCL_LIBRARY`/`TK_LIBRARY` env vars and `CURL_CA_BUNDLE` auto-detection
    (probes Debian, RHEL, SUSE cert paths)
5. **Make bin/R relocatable**: sed-replace hardcoded `R_HOME_DIR` with `readlink -f`
   self-detection
6. **Verify library resolution**: print RPATH info (informational only)
7. **Clean up**: remove DESCRIPTION artifact if present

### Issues encountered and how they were resolved

#### 1. auditwheel-r `str` vs `Path` bug (historical, no longer applicable)
**Problem**: auditwheel-r's directory repair mode yielded plain strings where Path
objects were expected. This was one reason we replaced auditwheel-r with delocate-r.py.

#### 2. delocate-r.py couldn't find libRblas.so
**Problem**: During repair, delocate-r.py uses `ldd` to trace dependencies but couldn't
resolve `libRblas.so` because it's not in standard library paths.
**Fix**: Export `LD_LIBRARY_PATH` with R's lib dir before running delocate-r.py.

#### 3. patchelf `--add-rpath` crashes on non-PIE executables
**Problem**: R's `lib/R/bin/exec/R` is a non-PIE EXEC type binary (not PIE/DYN).
`patchelf --add-rpath` tries to expand the binary but can't handle EXEC type, and
crashes. `--set-rpath` works but only if the new value fits in existing RPATH space.
**Fix**: Removed RPATH additions entirely for the exec binary. R's standard mechanism
is `etc/ldpaths` (sourced by `bin/R` shell script before exec), which sets
`LD_LIBRARY_PATH` to find `libR.so`. This already works for the portable case since
`etc/ldpaths` uses `${R_HOME}` (relative, not hardcoded).

#### 4. OpenBLAS not installed in Docker image
**Problem**: The centos-8 base image doesn't install OpenBLAS at build time -- the
centos-8 platform swaps in OpenBLAS at RPM install time. The manylinux_2_28 build
needs OpenBLAS present at package time so delocate-r.py can bundle it.
**Fix**: Added `openblas-threads` to the manylinux_2_28 Dockerfile.

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
with SSL cert errors. Investigation showed `/etc/ssl/` doesn't even exist -- the
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

#### 10. `lib/R/bin/R` not patched -- `R CMD INSTALL` fails when relocated
**Problem**: R installs two copies of the `R` shell script: `bin/R` (at the prefix
level) and `lib/R/bin/R` (inside R_HOME). Only `bin/R` was patched with the
`readlink -f` self-detection logic. When `R CMD INSTALL` runs (e.g., during
`install.packages()`), it spawns a subprocess calling `lib/R/bin/R` directly. That
script still had `R_HOME_DIR=/opt/R/4.4.2/lib/R` hardcoded, so at a relocated path
it fails with: `. /opt/R/4.4.2/lib/R/etc/ldpaths: No such file`.
**Fix**: Patch both scripts, with different formulas since they're at different depths:
- `bin/R` (at `<prefix>/bin/R`): `R_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")/lib/R"`
- `lib/R/bin/R` (at `<R_HOME>/bin/R`): `R_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"` (no `/lib/R` suffix -- two levels up is already R_HOME)
Same treatment for `Rscript`. Symlinks are skipped (only regular files are patched).

### Surprising things

- **`etc/ldpaths` is the key integration point**. It's sourced by `bin/R` before
  exec'ing the real binary, and it's the natural place to set environment variables for
  portability (LD_LIBRARY_PATH, TCL_LIBRARY, TK_LIBRARY, CURL_CA_BUNDLE). R already
  designed this for relocatability -- we just needed to extend it.

- **delocate-r.py handles R's complex library layout well**. Despite R having libs in
  `lib/R/lib/`, modules in `lib/R/modules/`, and package `.so` files in
  `lib/R/library/*/libs/`, delocate-r.py correctly traced and bundled all dependencies
  into a single `lib/R/lib/.libs/` directory with `$ORIGIN`-relative RPATHs.

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
  relocatability possible -- the shell script can compute paths dynamically before
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

1. **No runtime BLAS swapping**: Unlike the standard centos-8 build where
   `libRblas.so` is a symlink to system BLAS (allowing swaps to MKL, etc.), the
   portable build bundles OpenBLAS directly. Users cannot swap BLAS without rebuilding.

2. **Tcl/Tk hardcoded to 8.6**: The bundled Tcl/Tk scripts assume version 8.6.
   If the build system's Tcl version changes, the phase needs updating.

3. **`libxml` capability is FALSE**: R reports `libxml = FALSE` in `capabilities()`.
   This is because the test checks for `libxml2` headers at compile time via
   `xml2-config`, which is a compile-time concern, not a runtime portability issue.
   R's internal XML support is unaffected.

4. **Target system needs basic runtime libs**: While the builds are portable, the
   target system still needs: glibc >= 2.28, `ca-certificates` (for HTTPS),
   and `fontconfig` (for font configuration in plots). Optionally, a C/C++/Fortran
   compiler and dev packages are needed for compiling R packages from source.
   See [Installation](#installation) above. On minimal containers
   (e.g., Ubuntu Noble), `ca-certificates` is notably absent by default.

### Testing commands

```bash
# Build the Docker image
docker compose -f builder/docker-compose.yml build manylinux_2_28

# Build R (takes ~10 min)
R_VERSION=4.4.2 docker compose -f builder/docker-compose.yml run --rm manylinux_2_28

# Run e2e tests on all 4 distros
R_VERSION=4.4.2 docker compose -f test/docker-compose.yml run --rm manylinux_2_28
R_VERSION=4.4.2 docker compose -f test/docker-compose.yml run --rm manylinux_2_28-centos-8
R_VERSION=4.4.2 docker compose -f test/docker-compose.yml run --rm manylinux_2_28-rhel-10
R_VERSION=4.4.2 docker compose -f test/docker-compose.yml run --rm manylinux_2_28-opensuse-156

# Run unit tests for delocate-r.py
cd builder && python3 -m pytest test_delocate_r.py -v
```
