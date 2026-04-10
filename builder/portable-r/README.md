# Portable R Builds (manylinux / musllinux)

This directory documents R's portable builds, which produce cross-distro R tarballs that work across Linux distributions without distro-specific packages.

## Overview

A portable R build takes a standard R build (compiled on a specific distro) and runs a post-build portability step: `delocate_r.py` + patchelf bundle shared library dependencies (~65 on manylinux, ~67 on musllinux) into the R installation and rewrite RPATHs, producing relocatable packages that work across Linux distributions.

Two platform families are supported:

- **manylinux** (glibc-based) -- works on any glibc-based Linux distro (RHEL, Ubuntu, Debian, Fedora, SUSE, Arch, etc.)
- **musllinux** (musl-based) -- works on Alpine Linux and other musl libc distributions

Package formats produced:

- **tar.gz** -- universal, works on any compatible Linux (manylinux and musllinux)
- **DEB** -- for Debian, Ubuntu, and derivatives (manylinux only; auto-installs `ca-certificates` and `fontconfig`)
- **RPM** -- for RHEL, Fedora, SUSE, Amazon Linux, and derivatives (manylinux only; auto-installs `ca-certificates` and `fontconfig`)
- **APK** -- for Alpine Linux and derivatives (musllinux only; auto-installs `ca-certificates`, `fontconfig`, and `ttf-dejavu`)

Unlike the standard r-builds packages (which are distro-specific and must be installed to a fixed path), portable builds are fully relocatable -- R detects its own location at runtime via `readlink -f`. This makes them suitable for tools that manage multiple R versions in user-chosen directories.

The naming follows Python's PEP 600 convention: `manylinux_<major>_<minor>` refers to the minimum glibc version required. `musllinux_<major>_<minor>` refers to the minimum musl libc version required.

### Use cases

Portable manylinux builds are useful for:

- **Unsupported distros**: Linux distributions without dedicated r-builds packages, such as Amazon Linux 2023 and Arch Linux
- **Minimal/container environments**: Docker images, CI runners, and cloud VMs where you want R without pulling in distro-specific repos
- **Version managers**: Tools like rig or custom scripts that install multiple R versions to user-chosen directories
- **Older/newer distro versions**: Distro versions outside the supported matrix (e.g., older Ubuntu LTS, newer Fedora) that still meet the glibc requirement
- **Air-gapped systems**: Copy the tarball to systems without internet access

### Limitations

- **System deps**: `ca-certificates` is needed for HTTPS (e.g., `install.packages()` from CRAN), and `fontconfig` is needed for font discovery in plots. Both are present on most systems and are auto-installed by the DEB/RPM/APK packages. R starts and runs fine without them -- only HTTPS downloads and text rendering in plots are affected. On Alpine, `ttf-dejavu` is also needed since fontconfig does not pull in fonts automatically.
- **No runtime BLAS swapping**: OpenBLAS is bundled directly as `libRblas.so`. Users cannot swap to MKL or other BLAS implementations without rebuilding.

## Current builds

| Platform | Base image | libc | Compatible distros |
|---|---|---|---|
| `manylinux_2_34` | Rocky 9 | glibc 2.34 | RHEL 9+, Ubuntu 22.04+, Debian 12+, openSUSE 15.5+, Fedora 36+, Amazon Linux 2023+, Arch Linux |
| `musllinux_1_2` | Alpine 3.21 | musl 1.2 | Alpine 3.19+, any musl 1.2+ distro |

We use `manylinux_2_34` (based on RHEL 9) rather than `manylinux_2_28` (RHEL 8) to get newer libraries like OpenSSL 3.x and to work around issues with RHEL 8's old version of fontconfig (2.13, which doesn't understand modern config directives like `<reset-dirs/>`).

## Platform support

Based on [Posit platform support](https://docs.posit.co/platform-support.html). Check the current list when updating -- distros and EOL dates change frequently.

| Distro | EOL | glibc | Minimum manylinux |
|---|---|---|---|
| RHEL 8 (Rocky/Alma 8) | May 2029 | 2.28 | manylinux_2_28 (not built) |
| RHEL 9 (Rocky/Alma 9) | May 2032 | 2.34 | manylinux_2_34 |
| RHEL 10 | May 2035 | 2.39 | manylinux_2_34 |
| Ubuntu 22.04 | Apr 2027 | 2.35 | manylinux_2_34 |
| Ubuntu 24.04 | Apr 2029 | 2.39 | manylinux_2_34 |
| SLES 15 SP7 | Jul 2031 | 2.38 | manylinux_2_34 |
| Debian 12 | Jun 2026 | 2.36 | manylinux_2_34 |
| Debian 13 | Jun 2028 | 2.41 | manylinux_2_34 |

All currently supported distros are covered by `manylinux_2_34`, with the exception of RHEL 8 (which would require `manylinux_2_28`). RHEL 8 is still served by the standard distro-specific r-builds packages.

### manylinux compatibility reference

From [pep600_compliance](https://github.com/mayeut/pep600_compliance), useful manylinux tiers and their compatible distros:

| manylinux | glibc | Build base | Compatible with |
|---|---|---|---|
| `manylinux_2_17` | 2.17 | manylinux-2014 | CentOS 7+, Amazon Linux 1+ |
| `manylinux_2_34` | 2.34 | Rocky/Alma 9 | RHEL 9+, Ubuntu 22.04+, Debian 12+ |
| `manylinux_2_39` | 2.39 | Rocky/Alma 10 | RHEL 10+, Ubuntu 24.04+, Debian 13+ |

## Architecture

### Files per portable R platform

Each portable platform requires these files:

```
builder/
  Dockerfile.<platform>       # Docker image with build tools + portability tools
  package.<platform>           # Post-build script: library bundling, relocatability
  portable-r/
    delocate_r.py              # Shared: library bundling script (supports --policy manylinux|musllinux)
    test_delocate_r.py         # Unit tests for delocate_r.py
    test-manylinux.sh          # Cross-distro integration tests (manylinux)
    test-musllinux.sh          # Alpine integration tests (musllinux)
```

### How it works

1. **Build R** (`build.sh`): Standard R compilation using the distro's system libs
2. **Bundle deps** (`package.<platform>` calls `delocate_r.py`):
   - Discovers all ELF files in the R installation
   - Runs `ldd` to find external shared library dependencies
   - Copies non-allowed libs into `lib/R/lib/.libs/` with hash-renamed filenames
   - Rewrites RPATHs to `$ORIGIN`-relative paths using patchelf
   - Fixes inter-library DT_NEEDED references and SONAMEs
3. **Make relocatable** (`package.<platform>`):
   - Patches `bin/R` and `lib/R/bin/R` with `readlink -f` self-detection
   - Bundles Tcl/Tk scripts (currently hardcoded to 8.6), adds CA cert auto-detection to `etc/ldpaths`
4. **Package**: `build.sh` creates the tar.gz, then nfpm builds DEB and RPM packages from the portable installation

### delocate_r.py allowlist

`delocate_r.py` replicates the core pipeline from [auditwheel](https://github.com/pypa/auditwheel) (Python's binary portability tool) and auditwheel-r (Posit's internal R adaptation), adapted for R's specific needs.

From auditwheel: ELF dependency discovery via `ldd`, hash-renamed library grafting, `$ORIGIN`-relative RPATH rewriting via patchelf, SONAME and DT_NEEDED fixups.

From auditwheel-r: R-specific library excludes (`libR.so`, `libRblas.so`, `libRlapack.so`), using actual filenames rather than sonames for renamed targets, and the fixpoint loop for resolving transitive dependencies.

A standalone script was created instead of using auditwheel-r directly because:
- **No external dependencies**: auditwheel-r requires Python 3.12, `pyelftools`, and a pre-built wheel. `delocate_r.py` uses only Python 3 stdlib + patchelf.
- **Full control over the allowlist**: auditwheel-r uses the official manylinux allowlist, which includes X11 and GLib. We intentionally bundle those for portability on minimal systems. Bundling libs outside the manylinux allowlist carries some ABI compatibility risk if the target system loads a different version of the same library in the same process. In practice, this is mitigated by bundling the entire dependency chain (e.g., all X11 libs together) so there's no mixing of bundled and system versions within R's graphics stack.
- **Simpler, in-place workflow**: operates directly on one R installation rather than the wheelhouse copy step designed for R packages.
- **No fork maintenance**: auditwheel's library API changes often for Python-specific needs, and a self-contained script avoids upstream dependency churn.

The allowlist in `delocate_r.py` determines which libraries are NOT bundled (expected on the target system). It uses per-policy allowlists selected via `--policy manylinux|musllinux`.

#### manylinux allowlist

Intentionally narrower than the official manylinux spec:

**Allowed (not bundled):**
- glibc core: `libc.so`, `libm.so`, `libdl.so`, `librt.so`, `libpthread.so`, etc.
- Compiler runtime: `libgcc_s.so`, `libstdc++.so`
- Core system: `libz.so`, `libexpat.so`
- GL drivers: `libGL.so` (system-specific)
- R internal: `libR.so`, `libRblas.so`, `libRlapack.so`

**Bundled despite being in the official manylinux allowlist:**
- X11 libs (`libX11`, `libSM`, `libICE`, etc.) - ensures graphics work without X11 packages
- GLib/GObject - not always installed on minimal systems

#### musllinux allowlist

More restrictive than the manylinux allowlist because musl has fewer core libraries:

**Allowed (not bundled):**
- musl libc: `libc.musl-*` (includes libc, libm, libdl, librt, libpthread -- musl consolidates these into one library)
- VDSO: `linux-vdso.so`
- Core system: `libz.so`
- GL drivers: `libGL.so` (system-specific)
- R internal: `libR.so`, `libRblas.so`, `libRlapack.so`

**Bundled on musllinux but allowed on manylinux:**
- `libgcc_s.so`, `libstdc++.so` -- not guaranteed on clean Alpine installations
- `libexpat.so` -- not in musl's core library set

### System dependencies at runtime

The tarball is self-contained except for:

| Dependency | Why | Package |
|---|---|---|
| glibc >= build version (manylinux) or musl >= 1.2 (musllinux) | Core C library | (always present) |
| `ca-certificates` | SSL/TLS certificate bundle for HTTPS | `ca-certificates` |
| `fontconfig` | Font config files for text rendering | `fontconfig` (on openSUSE/SLES, also install `dejavu-fonts`) |
| `ttf-dejavu` (Alpine only) | Fonts for text rendering in plots | `ttf-dejavu` (not pulled in by fontconfig on Alpine) |
| `which` | Required by R's `utils` package at startup | `which` (RHEL/SUSE; included in `debianutils` on Debian/Ubuntu; in `coreutils` on Alpine) |

For compiling R packages from source, users also need a C/C++/Fortran compiler and dev packages for `pcre2`, `lzma`, `bz2`, `zlib`, `icu`.

### fontconfig handling

Fontconfig requires special treatment because:

1. The library (`libfontconfig.so`) is bundled, but it reads the system's `/etc/fonts/fonts.conf` at runtime
2. Older fontconfig versions don't understand config directives from newer versions (e.g. `<reset-dirs/>` added in 2.14), causing warnings on modern distros
3. If fontconfig is not bundled, R's entire graphics stack fails to load on systems without the fontconfig package

The solution: **build a newer fontconfig from source** if the base image's version is too old. The Dockerfile has a conditional check:

```dockerfile
ENV FONTCONFIG_MIN_VERSION=2.14
RUN FC_VERSION=$(rpm -q --qf '%{VERSION}' fontconfig 2>/dev/null || echo "0") && \
    if [ version >= min ]; then skip; else build 2.15.0 from source; fi
```

Version 2.15.0 was chosen because:
- Latest release using autotools (2.16+ requires meson)
- Matches Ubuntu 24.04, RHEL 10, Debian 13
- Understands all config directives through `<reset-dirs/>`

On base images with fontconfig >= 2.14 (e.g. Rocky 9+), this step is skipped automatically.

## Adding a new manylinux version

### When to add a new version

Add a higher manylinux version (e.g. `manylinux_2_34` on Rocky 9) when:

- You want newer system library versions (OpenSSL 3.x, newer libcurl, etc.)
- The base image provides better toolchain support
- You want to drop older distro compatibility in exchange for smaller tarballs (fewer libs to bundle if the target has more pre-installed)

Note: a higher manylinux version is NOT needed just to run on newer distros. `manylinux_2_34` already runs on RHEL 10, Ubuntu 24.04, etc.

### Step-by-step

1. **Choose a base image** from the [pep600_compliance build bases](https://github.com/mayeut/pep600_compliance):
   - `manylinux_2_34` -> `rockylinux:9`
   - `manylinux_2_39` -> `rockylinux:10` (when available)

2. **Create `builder/Dockerfile.<platform>`** based on the existing manylinux Dockerfile:
   - Match the corresponding centos/rhel Dockerfile for R build dependencies
   - Include patchelf install
   - Check if fontconfig source build is needed (Rocky 9 ships 2.14.0, which is exactly the minimum -- should be sufficient, but test for warnings)
   - Include the `--with-2025blas` configure flag for R >= 4.5.0 BLAS compat

3. **Create `builder/package.<platform>`** -- can likely reuse `package.manylinux_2_34` directly or with minor adjustments:
   - OpenBLAS package name may differ (check `openblas-threads` vs `openblas`)
   - Tcl/Tk version may differ (8.6 vs 9.x)
   - BLAS library path may differ

4. **Add docker-compose services**:
   - `builder/docker-compose.yml`: build service
   - `test/docker-compose.yml`: test services on multiple distros

5. **Add to Makefile**: add platform to `PLATFORMS` list

6. **Test on target distros**: run `test-manylinux.sh` on distros that match the new manylinux level and also on distros with newer glibc

### Rocky 9 / manylinux_2_34 tradeoffs

A `manylinux_2_34` build on Rocky 9 would provide:

| Library | Rocky 8 | Rocky 9 | Benefit |
|---|---|---|---|
| glibc | 2.28 | 2.34 | Drops RHEL 8, Ubuntu 20.04, Debian 10 |
| OpenSSL | 1.1.1k | **3.0.7** | Modern TLS, SHA-3, post-quantum readiness |
| fontconfig | 2.13.1 (build 2.15.0) | **2.14.0** | No source build needed |
| ICU | 60.3 | 67.1 | Better Unicode support |
| pango | 1.42.4 | 1.48.7 | Improved text rendering |
| cairo | 1.15.12 | 1.17.4 | Better graphics |
| GCC | 8.5 | 11.4 | Newer compiler, better optimizations |

**Compatible distros** (glibc >= 2.34):
RHEL 9+, Ubuntu 22.04+, Debian 12+, Fedora 36+, Amazon Linux 2023+

**Dropped distros** (not supported by manylinux_2_34):
RHEL 8, Ubuntu 20.04, Debian 10-11, openSUSE 15.4-15.5, Amazon Linux 2

### Parallel builds strategy

You can build multiple manylinux versions in parallel:

- **manylinux_2_34**: Covers all Posit-supported distros except RHEL 8 (EOL May 2029)

A `manylinux_2_28` build for RHEL 8 compatibility could be added in the future if needed (the deleted files are recoverable from git history).

## musllinux / Alpine

Alpine Linux uses musl libc instead of glibc. The `musllinux_1_2` platform builds on Alpine 3.21 and produces portable R for musl-based systems.

### How it differs from manylinux

- **Base image**: Alpine 3.21 instead of Rocky Linux
- **Allowlist**: musllinux policy is more restrictive -- `libgcc_s` and `libstdc++` must be bundled (not guaranteed on clean Alpine), and `libexpat` is not in musl's core set
- **Package formats**: APK + tar.gz (no DEB/RPM, since musl binaries don't run on glibc systems)
- **Fontconfig**: Alpine 3.21 ships fontconfig 2.15.0, so no source build is needed
- **patchelf**: Installed from Alpine packages (not built from source)
- **patchelf strtab fix**: patchelf 0.18.0 (the Alpine 3.21 version) has a bug where `.dynstr` VAddr becomes inconsistent with its LOAD segment on large binaries (e.g., ~34MB OpenBLAS). `delocate_r.py` includes `fix_patchelf_strtab()` to detect and correct this after patchelf runs.
- **Runtime deps**: On Alpine, `ttf-dejavu` is required in addition to `ca-certificates` and `fontconfig`, since fontconfig does not pull in fonts automatically

### musllinux_1_2 phases (package.musllinux_1_2)

1. **BLAS setup**: Replace reference BLAS with OpenBLAS
2. **delocate_r repair**: Bundle system libs with `--policy musllinux` (~67 libs)
3. **Fix BLAS/LAPACK SONAMEs**: Fix SONAMEs + run `fix_patchelf_strtab()` on large binaries
4. **Bundle Tcl/Tk scripts + SSL CA detection**: Same as manylinux, with Alpine-specific paths
5. **Make bin/R relocatable**: Same `readlink -f` self-detection as manylinux
6. **Verify + clean up**: Print RPATH info, remove DESCRIPTION artifact
7. **Build APK package**: Via nfpm, with `ca-certificates`, `fontconfig`, and `ttf-dejavu` as dependencies

### Build and test

```bash
# Build R
R_VERSION=4.5.3 MAKEFLAGS=-j4 make build-r-musllinux_1_2

# Run integration tests (Alpine 3.21)
R_VERSION=4.5.3 make test-r-musllinux_1_2

# Run unit tests (includes musllinux policy tests)
cd builder/portable-r && python3 -m pytest test_delocate_r.py -v
```

## Testing

### Build and test commands

```bash
# Build R (manylinux)
R_VERSION=4.5.3 MAKEFLAGS=-j4 make build-r-manylinux_2_34

# Run integration tests (all 4 distros)
R_VERSION=4.5.3 make test-r-manylinux_2_34
R_VERSION=4.5.3 make test-r-manylinux_2_34-rocky-9
R_VERSION=4.5.3 make test-r-manylinux_2_34-rhel-10
R_VERSION=4.5.3 make test-r-manylinux_2_34-opensuse-156

# Build and test musllinux
R_VERSION=4.5.3 MAKEFLAGS=-j4 make build-r-musllinux_1_2
R_VERSION=4.5.3 make test-r-musllinux_1_2

# Run unit tests for delocate_r.py
cd builder/portable-r && python3 -m pytest test_delocate_r.py -v
```

### What the tests verify

- R starts and `sessionInfo()` works
- `capabilities()` returns TRUE for jpeg/png/tiff/tcltk/cairo/ICU/libcurl
- Graphics devices work (png, jpeg, tiff, svg, cairo, pdf)
- No unexpected output from plotting (no fontconfig warnings)
- Package installation from CRAN works
- Package compilation with C/C++/Fortran + BLAS/LAPACK linking works
- HTTPS downloads work (CA certificate detection)
- Relocatability (move R to different path, verify it still works)
- `R CMD INSTALL` works from relocated path
- libRblas.so/libRlapack.so have correct SONAMEs

### Test distros

The integration test (`test-manylinux.sh`) runs on multiple distros to validate cross-distro portability. When adding a new manylinux version, test on:

1. The build distro itself (e.g. Rocky 9 for manylinux_2_34)
2. A distro with newer glibc that has different library paths (e.g. Ubuntu Noble)
3. A distro with different package manager (e.g. openSUSE)
4. The newest Posit-supported distro (to catch fontconfig/config issues)

## Related projects

- **[r-hub/r-glibc](https://github.com/r-hub/r-glibc)**: Portable R via static linking on Ubuntu 18.04. More self-contained (bundles CA certs and static tool binaries), but not relocatable (hardcoded `/opt/R/` paths), requires per-version X11 patches for every R release, and uses an EOL base image. Our approach uses dynamic linking + RPATH rewriting, which avoids per-version patches and enables relocatability at the cost of requiring `ca-certificates` and `fontconfig` system packages.
- **[astral-sh/python-build-standalone](https://github.com/astral-sh/python-build-standalone)**: Portable Python via static linking. Targets glibc 2.17+. Doesn't handle fontconfig (not needed for Python). Uses `uv`/`sysconfigpatcher` for path fixups.
