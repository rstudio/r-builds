# Plan: Portable manylinux_2_28 R Build

## TL;DR

Add a new `manylinux-2-28` platform to r-builds (reusing the centos-8 Docker image)
that builds R and then runs a post-build portability step: auditwheel-r + patchelf
bundle system library dependencies into the R installation and rewrite RPATHs,
producing portable R artifacts conforming to the manylinux_2_28 standard.

Three distribution formats are produced from a single build:
- **tar.gz** — for direct extraction to any path
- **DEB** — for `apt install` on Debian/Ubuntu
- **RPM** — for `dnf install` / `yum install` on RHEL/Fedora/SUSE

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
   whitelist (expected on the target system). auditwheel-r correctly didn't bundle
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
- `package.manylinux-2-28` — runs portability post-processing, then produces DEB and
  RPM packages (via nfpm) alongside the tar.gz
- Standard Makefile/compose targets: `build-r-manylinux-2-28`, `test-r-manylinux-2-28`, etc.

### X11 support: Keep it (Option B)

R is built `--with-x` (same as centos-8). The X11 libraries (`libSM.so.6`,
`libICE.so.6`, `libX11.so.6`, `libXt.so.6`) are **in the manylinux_2_28 whitelist**
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

- patchelf 0.17.2 (from GitHub releases — avoid 0.18.0 per known issues, same version
  as rspm-builder-images)
- Python 3 (system `python3` or Posit Python RPM)
- auditwheel-r (pip install from `rstudio/auditwheel-r`)

### Phase 2: Portability script (`package.manylinux-2-28`)

Runs inside Docker after `build.sh` compiles and installs R:

1. **Pre-repair BLAS fixup**: Remove `libRblas.so.keep` and restore `libRblas.so` as a
   real file (not a symlink to system OpenBLAS), so auditwheel-r can trace and bundle
   the actual BLAS library.

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

4. **Fix `bin/R` R_HOME detection**: sed-replace the hardcoded `R_HOME_DIR=...` line
   with self-detecting logic that derives R_HOME from the script's own filesystem
   location using `readlink -f`, making it fully relocatable.

5. **Fix BLAS/LAPACK SONAMEs**: Use `patchelf --set-soname` to ensure libRblas.so and
   libRlapack.so have correct SONAMEs matching their filenames, so compiled R packages
   record the right dependency names.

6. **Bundle Tcl/Tk scripts**: Copy Tcl/Tk library directories and set `TCL_LIBRARY`/
   `TK_LIBRARY` in `etc/ldpaths`.

7. **SSL CA bundle auto-detection**: Add `CURL_CA_BUNDLE` auto-detection to
   `etc/ldpaths` for cross-distro HTTPS support.

8. **Clean up artifacts**: Remove top-level `DESCRIPTION` file if created by auditwheel-r.

9. **Create DEB and RPM packages**: Use nfpm (already in the centos-8 base image) to
   package the portable R installation as both `.deb` and `.rpm`. Dependencies are
   minimal — only manylinux_2_28 whitelisted libraries (X11, cairo, pango, glib) and
   build tools (gcc, gfortran, make). The tar.gz is created separately by `archive_r`
   in `build.sh`.

### Phase 3: Integration

- Add docker-compose service for `manylinux-2-28` in `builder/docker-compose.yml`.
- Add `manylinux-2-28` to `PLATFORMS` in `Makefile`.
- Add test service in `test/docker-compose.yml` using a different base image
  (e.g., Ubuntu 20.04) to validate cross-distro portability.

### Phase 4: Testing

- Test on build platform (CentOS 8/Rocky 8): R starts, `sessionInfo()`, `ldd` shows bundled libs.
- Test on different distro (Ubuntu 20.04): R starts, package installation works, `capabilities()`.
- Verify with `ldd`/`readelf`/`lsof` that only manylinux_2_28-whitelisted libs come from system paths.
- Relocatability test: move to a different path, verify R starts.

## New Files

- `builder/Dockerfile.manylinux-2-28` — Docker image extending centos-8 with portability tools
- `builder/package.manylinux-2-28` — Post-build portability script (produces tar.gz, DEB, and RPM)

## Verification Checklist

1. `auditwheel-r show /opt/R/<version>/` — manylinux_2_28 compliant
2. `ldd lib/R/lib/libR.so` — bundled deps resolve to `libs/.libs/` paths
3. `ldd lib/R/modules/R_X11.so` — whitelisted X11 libs show as system deps (expected)
4. `readelf -d lib/R/bin/exec/R` — RPATH includes `$ORIGIN/../../../../libs/.libs`
5. On Ubuntu 20.04: R starts, `capabilities()` shows TRUE for jpeg/png/tiff/tcltk/cairo/ICU/libcurl
6. Relocatability: `mv /opt/R/<ver> /tmp/R-test && /tmp/R-test/bin/R -e 'cat("works\n")'`
7. DEB install on Ubuntu 20.04: `apt install ./r-4.4.2_1_amd64.deb` → R works
8. RPM install on Rocky 9: `dnf install ./r-4.4.2-1-1.x86_64.rpm` → R works

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

---

## Implementation Notes & Retrospective

### What was built

A new `manylinux-2-28` platform producing three portable R 4.4.2 distribution formats
from a single build on Rocky 8 (glibc 2.28):

- **tar.gz** (~115MB) — direct extraction, tested on Ubuntu 20.04
- **DEB** (~120MB) — `apt install`, tested on Ubuntu 20.04
- **RPM** (~122MB) — `dnf install`, tested on Rocky 9

All standard tests pass across all three formats: R starts, sessionInfo works,
capabilities (jpeg/png/tiff/tcltk/cairo/ICU/libcurl all TRUE), package compilation
with C/C++/Fortran + BLAS/LAPACK linking, HTTPS downloads, and relocatability (move R
to an arbitrary path, it still works).

The DEB/RPM packages declare only minimal dependencies — manylinux_2_28 whitelisted
system libraries (X11, cairo, pango, glib) and build tools (gcc/g++/gfortran/make).
Everything else is bundled.

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

1. **BLAS setup**: copy system OpenBLAS to `lib/R/lib/libRblas.so`
2. **auditwheel-r repair**: bundle non-whitelisted system libs, rewrite RPATHs
3. **Replace R installation** with repaired output from wheelhouse
4. **Fix BLAS/LAPACK SONAMEs**: `patchelf --set-soname` on libRblas.so and libRlapack.so
5. **Bundle Tcl/Tk scripts**: copy `/usr/share/tcl8.6` and `/usr/share/tk8.6` into
   `lib/R/share/`, set `TCL_LIBRARY`/`TK_LIBRARY` in `etc/ldpaths`
6. **SSL CA bundle detection**: add auto-detection of CA cert paths across distros
   (Debian, RHEL, SUSE) via `CURL_CA_BUNDLE` in `etc/ldpaths`
7. **Make bin/R relocatable**: sed-replace hardcoded `R_HOME_DIR` with `readlink -f`
   self-detection
8. **Verify & clean up**: print RPATH info, remove DESCRIPTION artifact
9. **Create DEB and RPM packages**: nfpm packages from the portable R installation
   with minimal dependencies (whitelisted system libs + build tools only)

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
**Problem**: The centos-8 Dockerfile only lists `openblas-devel` as an RPM runtime
dependency, not a build dependency. The manylinux-2-28 Dockerfile inherits from
centos-8 but needs OpenBLAS present at package time (not just at RPM install time).
**Fix**: Added `openblas-devel` to the manylinux-2-28 Dockerfile.

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

### Known limitations

1. **Makeconf has hardcoded paths**: `lib/R/etc/Makeconf` contains absolute paths from
   configure time (e.g., `-I/opt/R/4.4.2/lib/R/include`). Package compilation works
   because R sets these values at runtime, but some Makeconf variables may break at
   non-standard install paths. This is a v2 enhancement.

2. **X11 requires system packages**: `libX11.so.6`, `libXt.so.6`, etc. are
   manylinux_2_28 whitelisted (not bundled). On minimal containers without X11 libs,
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
   compilation), and manylinux_2_28 whitelisted libs (X11, pango, cairo, glib for full
   capabilities). The DEB/RPM packages declare these as dependencies so they are
   installed automatically; the tarball requires them to be installed manually.

### Testing commands

```bash
# Build the Docker image
docker compose -f builder/docker-compose.yml build manylinux-2-28

# Build R — produces tar.gz, DEB, and RPM (takes ~10 min)
R_VERSION=4.4.2 docker compose -f builder/docker-compose.yml run --rm manylinux-2-28

# Run tarball cross-distro test on Ubuntu 20.04
docker run --rm \
  -e R_VERSION=4.4.2 \
  -e OS_IDENTIFIER=manylinux-2-28 \
  -v "$(pwd)":/r-builds \
  ubuntu:focal /r-builds/test/test-manylinux.sh

# Or via docker compose
R_VERSION=4.4.2 docker compose -f test/docker-compose.yml run --rm manylinux-2-28

# Test DEB install on Ubuntu 20.04
docker run --rm \
  -v "$(pwd)/builder/integration/tmp":/tmp/output \
  ubuntu:focal bash -c '
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive \
    apt-get install -y /tmp/output/manylinux-2-28/r-4.4.2_1_amd64.deb && \
    /opt/R/4.4.2/bin/R --version'

# Test RPM install on Rocky 9
docker run --rm \
  -v "$(pwd)/builder/integration/tmp":/tmp/output \
  rockylinux:9 bash -c '
    dnf install -y /tmp/output/manylinux-2-28/r-4.4.2-1-1.x86_64.rpm && \
    /opt/R/4.4.2/bin/R --version'
```
