# Portable macOS R builds

This directory builds portable, relocatable macOS R distributions by post-processing the official CRAN `.pkg` installer. The output is a `.tar.gz` that can be extracted to any directory and run from there — no admin rights, no Gatekeeper installer prompt, and no side effects on the system R installation.

## Overview

Unlike the Linux portable builds (which compile R from source and bundle system libraries with `delocate_r.py` + patchelf), the macOS pipeline starts from the existing CRAN binary. CRAN ships high-quality macOS installers built with Apple's blessed toolchain (custom gfortran, correct configure flags, bundled Tcl/Tk and gfortran runtime). Replicating that toolchain from scratch would be complex and fragile, so we treat the CRAN `.pkg` as a known-good upstream and only apply the smallest set of changes needed for relocatability:

1. Download the CRAN `.pkg` installer.
2. Extract it with `pkgutil --expand-full` (no admin, no install).
3. Rewrite hardcoded `/Library/Frameworks/R.framework/...` Mach-O load commands to `@rpath` / `@loader_path` references.
4. Patch `bin/R`, `bin/Rscript`, `etc/Makeconf`, `etc/Renviron` to derive `R_HOME` at runtime.
5. Append portable-R hooks (default CRAN repo, Tcl/Tk paths, CRAN binary package fix-up) to the base Rprofile.
6. Codesign all Mach-O binaries (ad-hoc on staging, Developer ID + notarized on production).
7. Package as `R-{version}-macos-{arch}.tar.gz`.

Output: a self-contained tarball where `bin/R --version` works regardless of where the directory is extracted.

## Files

```
macos/
  build.sh                    # Orchestrator: download .pkg → extract → patch → tarball
  patch-mach-o.sh             # Phase 1: rewrite Mach-O load commands to @rpath/@loader_path
  make-relocatable.sh         # Phase 2: patch bin/R, Rscript, Makeconf for runtime R_HOME
  install-rprofile-hook.sh    # Phase 3: append portable-R hooks to base Rprofile
  notarize.sh                 # Submit signed build to Apple Notary Service
  entitlements.plist          # Hardened-runtime entitlements (JIT, library validation, dyld env)
  test.sh                     # Integration tests (relocatability, capabilities, package installs)
```

## Use cases

Portable macOS builds are useful for:

- **Version managers** (rig, custom scripts) that install multiple R versions side-by-side under user-chosen directories.
- **CI / cloud runners** where you want a specific R version without an admin install.
- **Air-gapped systems** — copy the tarball to a machine without internet access.
- **Developer environments** where switching between R versions for a project shouldn't require touching `/Library/Frameworks/R.framework`.

## Limitations

- **No CRAN binaries before R 4.1.** CRAN does not host a macOS `.pkg` installer for R 4.0.x or earlier on either the main mirror (`cloud.r-project.org`) or `cran-archive.r-project.org` for arm64, and R 4.0.x has no usable `.pkg` at all. Building these would mean compiling from source — out of scope for this pipeline.
- **CRAN-bundled libraries are pinned at build time.** Tcl/Tk, gfortran runtime, OpenBLAS — whatever CRAN ships in the `.pkg` is what you get. Updating these requires rebuilding from a newer CRAN release.
- **Gatekeeper quarantine on tarballs.** macOS attaches `com.apple.quarantine` to anything downloaded via `curl`/browser. On unsigned/un-notarized builds this triggers Gatekeeper warnings on first run. On notarized production builds it does not. Either way, `xattr -dr com.apple.quarantine ~/R/R-{version}` strips it.

## What gets built

Both arm64 (Apple Silicon) and x86_64 (Intel; runs under Rosetta 2 on Apple Silicon hosts) for R 4.1.0 onwards. The build matrix in `build-macos.yml` defaults to the last 5 R minor versions plus `devel`, with R < 4.1 skipped.

Output paths on the CDN follow the existing pattern:

```
cdn.posit.co/r/macos-arm64/R-{version}-macos-arm64.tar.gz
cdn.posit.co/r/macos-x86_64/R-{version}-macos-x86_64.tar.gz
```

## How it works

### Phase 1 — Download and extract (`build.sh`)

CRAN's macOS URL layout has shifted multiple times. As of 2026-04, the candidate URLs probed in order are:

| R version | arch | URL pattern |
|---|---|---|
| R 4.6+ | arm64 | `cloud.r-project.org/bin/macosx/sonoma-arm64/base/R-{ver}-arm64.pkg` |
| R 4.3 - 4.5 | arm64 | `cloud.r-project.org/bin/macosx/big-sur-arm64/base/R-{ver}-arm64.pkg` |
| R 4.6+ | x86_64 | `cloud.r-project.org/bin/macosx/big-sur-x86_64/base/R-{ver}-x86_64.pkg` |
| R 4.3 - 4.5 | x86_64 | same as R 4.6+ |
| R 4.1 - 4.2 | arm64 | `cloud.r-project.org/bin/macosx/big-sur-arm64/base/R-{ver}-arm64.pkg` |
| R 4.1 - 4.2 | x86_64 | `cloud.r-project.org/bin/macosx/base/R-{ver}.pkg` |
| R 3.6.x | x86_64 | `cran-archive.r-project.org/bin/macosx/base/R-{ver}.nn.pkg` (note: not built) |
| devel | both | `mac.r-project.org/{sonoma,big-sur}-{arch}/R-{branch}-branch/...` |

For arm64, sonoma-arm64 is probed first; if it 404s (R ≤ 4.5), the script falls through to big-sur-arm64. CRAN does not ship a sonoma-x86_64 prefix — x86_64 stays on big-sur-x86_64 across the matrix.

Devel builds at `mac.r-project.org` use a per-branch subdirectory. The branch number rolls forward (4.6 → 4.7 → ...), so `build.sh` iterates a list of plausible branches newest-first, picks the first that returns 200 OK, and uses that. Update the `branches` array in `resolve_pkg_url()` when R rolls a major branch.

`pkgutil --expand-full` extracts the Xar archive. R lives at `R.framework/Versions/{ver}-{arch}/Resources/` (or `Versions/Current/Resources/`), which we flatten into `R-{version}/`. R 4.2 and earlier x86_64 also ship a separate `tcltk*.pkg` payload — we extract its `libtcl*.dylib` / `libtk*.dylib` into our `lib/` and the `tcl8.6/` / `tk8.6/` script directories into `lib/tcl8.6/` / `lib/tk8.6/`.

### Phase 2 — Mach-O patching (`patch-mach-o.sh`)

CRAN binaries embed absolute paths everywhere — every `LC_LOAD_DYLIB` load command, every `LC_RPATH`, the `LC_ID_DYLIB` of every `.dylib` — pointing into `/Library/Frameworks/R.framework/Versions/{ver}-{arch}/Resources/lib/`. `patch-mach-o.sh` walks every Mach-O file (`.dylib`, `.so`, `bin/exec/R`, `bin/Rscript.bin`) and:

- Rewrites every load command containing `/Library/Frameworks/R.framework` to a relative reference. The exact replacement depends on context:
  - `lib/*.dylib` peer references → `@loader_path/{libname}` (peer in same directory)
  - `bin/exec/R` → `@executable_path/../../lib/{libname}` (R lives at `bin/exec/R`, so `../../lib` reaches `lib/`)
  - `library/{pkg}/libs/*.so` → `@rpath/{libname}` + `LC_RPATH @loader_path/../../../lib`
  - `modules/*.so` → `@rpath/{libname}` + `LC_RPATH @loader_path/../lib`
- Sets `LC_ID_DYLIB` on every `lib/*.dylib` to `@rpath/{name}.dylib` so consumers don't pick up the framework path from the dylib's own ID.
- Rewrites non-system absolute paths (`/opt/R/{arch}/lib/...` for R 4.3+ Tcl/Tk in some builds, `/usr/local/lib/...` for older Tcl/Tk) when the referenced library exists in our bundled `lib/`.

After all rewrites, every Mach-O file is codesigned. See [Code signing and notarization](#code-signing-and-notarization) below.

### Phase 3 — Runtime relocation (`make-relocatable.sh`)

`bin/R` is a shell script CRAN sets up with a static `R_HOME_DIR=/Library/Frameworks/R.framework/Versions/{ver}-{arch}/Resources` line. Two changes are needed:

- **Add a runtime override** that re-derives `R_HOME_DIR` from the script's own location:
  ```sh
  R_HOME_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")")/.." && pwd)"
  ```
  This is **inserted before** `R_HOME="${R_HOME_DIR}"`, not in place of the static line. Keeping the original static `R_HOME_DIR=` line intact matters for IDE compatibility — see [IDE compatibility](#ide-compatibility-rstudio-positron) below.

- **Replace the embedded framework prefix** in `R_SHARE_DIR`, `R_INCLUDE_DIR`, `R_DOC_DIR` with `${R_HOME_DIR}`-relative paths.

`bin/Rscript` needs a version-aware fix because the Rscript binary's behavior changed in R 4.2:

- **R < 4.2**: `Rscript` is a Mach-O binary that **ignores** the `R_HOME` env var and uses compiled-in paths. We replace it entirely with a shell wrapper that calls `bin/R --slave`. (Same pattern as the Linux portable build's `Rscript`.)
- **R >= 4.2**: `Rscript` respects `R_HOME`. We rename the binary to `Rscript.bin` and replace `Rscript` with a shell wrapper that exports `R_HOME` and execs `Rscript.bin`. The wrapper is plain Bash so it remains relocatable.

`etc/Makeconf` also needs patching for compiled R packages to link correctly:

- Replace the embedded framework prefix with `$(R_HOME)`.
- Replace `LIBR = -F.../Versions/.../Resources/lib -framework R` with `LIBR = -L"$(R_HOME)/lib" -lR` so packages link directly against `libR.dylib`. The framework reference would only resolve if R were actually installed at `/Library/Frameworks/R.framework/...`.
- Strip remaining `-F/Library/Frameworks/...` flags.

`etc/Renviron`, `etc/ldpaths`, and any other text scripts in `bin/` get a global `s|<framework-path>|${R_HOME}|g` replacement.

### Phase 4 — Portable-R hooks (`install-rprofile-hook.sh`)

The script appends three `local()` blocks to **`library/base/R/Rprofile`** (the base Rprofile, sourced by R itself during startup). It is **not** written to `etc/Rprofile.site` — that file is skipped under `R --vanilla` and bypassed by IDEs that load `libR.dylib` directly without going through `bin/R`. The base Rprofile is sourced in every launch context. This matches the manylinux PR #280 approach.

The three hooks installed:

1. **Default CRAN repo** → `https://p3m.dev/cran/latest` (Posit Public Package Manager). Provides binary R packages for macOS for the same R version × arch matrix this build targets.

2. **Tcl/Tk library paths** — sets `TCL_LIBRARY` and `TK_LIBRARY` to `${R_HOME}/lib/tcl8.6` and `${R_HOME}/lib/tk8.6` if those directories exist (only true for R < 4.3 builds where build.sh extracted the Tcl/Tk sub-package). R >= 4.3 bundles Tcl/Tk inside R.framework and does not need these env vars.

3. **`.portable` environment for CRAN binary package fix-up** (macOS-only; gated on `Sys.info()[["sysname"]] == "Darwin"`). CRAN binary `.tgz` packages embed absolute Mach-O paths from CRAN's build host (`/Library/Frameworks/R.framework/...`). When R is installed anywhere else, `library(pkg)` fails with "image not found." The wrapper:
   - Defines `.portable$install.packages` that calls `utils::install.packages` and then runs `install_name_tool` on the freshly-installed `.so` files, rewriting each framework reference to `@rpath/{libname}`, adding an `LC_RPATH @loader_path/../../../lib`, and ad-hoc resigning.
   - Attaches `.portable` at `pos = 2L` of the search path via a `setHook(packageEvent("stats", "attach"), ...)` hook so it masks the regular `install.packages`. `stats` is the last default package to attach during R startup, so this fires after all default packages but before user code runs.

   **Known limitation:** RStudio and Positron install their own `install.packages` overrides at IDE startup. If those attach above `.portable` in the search path (typically as `tools:rstudio` at position 2), the `.portable` wrapper is shadowed and the fix-up does not run. As an escape hatch, `bin/fix-dylibs` is a standalone shell script that scans the library tree for unpatched `.so` files and runs the same `install_name_tool` rewrites manually. We will revisit this design after testing in real IDE sessions.

## Code signing and notarization

`patch-mach-o.sh` Phase 6 codesigns every Mach-O binary in the tree:

- **Local / staging builds**: ad-hoc signed (`codesign -s -`). Required because `install_name_tool` invalidates any existing signature; without re-signing, macOS refuses to load the dylib. Ad-hoc signed binaries run on the build machine but are quarantined on download by Gatekeeper.

- **Production builds**: signed with the Developer ID Application certificate when `CODESIGN_IDENTITY` is set, with the hardened runtime enabled and entitlements applied (see `entitlements.plist`). Required entitlements:
  - `com.apple.security.cs.allow-jit` — R's byte-code compiler.
  - `com.apple.security.cs.allow-unsigned-executable-memory` — Rcpp and other packages that generate code at runtime.
  - `com.apple.security.cs.disable-library-validation` — needed because users install third-party packages with their own Mach-O `.so` files signed by other teams (or ad-hoc resigned by the `.portable` hook).
  - `com.apple.security.cs.allow-dyld-environment-variables` — `DYLD_LIBRARY_PATH`, etc.

After Developer ID signing, `notarize.sh` zips the build with `ditto -c -k --keepParent` and submits it to Apple's notary service via `xcrun notarytool submit --wait`. On acceptance, the build is whole-package notarized — but we don't currently staple individual files inside the tarball, so end users still get one quarantine warning per file on first run if they open in Finder. Running `xattr -dr com.apple.quarantine ~/R/R-{version}` after extraction clears it. (Not stapling each file is a deliberate choice — there are thousands of `.so` files in a typical R install and stapling each would dramatically inflate build time. Document the `xattr` command in the install instructions instead.)

The notarization step is gated in CI on **both** the Developer ID secret and the notarization credentials being present. Apple rejects ad-hoc-signed binaries, so submitting without `MACOS_DEVELOPER_CERTIFICATE` configured produces a confusing signature error — the gate avoids that.

Required CI secrets for production:

| Secret | Content |
| --- | --- |
| `MACOS_DEVELOPER_CERTIFICATE` | Base64 of the `.p12` (Developer ID Application cert + private key) |
| `MACOS_DEVELOPER_CERTIFICATE_PASSWORD` | The `.p12` export password |
| `MACOS_NOTARIZATION_USER_NAME` | Apple ID email |
| `MACOS_NOTARIZATION_USER_PASSWORD` | App-specific password from appleid.apple.com → Sign-In and Security |
| `APPLE_TEAM_ID` | 10-char Team ID from developer.apple.com → Membership |

## IDE compatibility (RStudio, Positron)

Both RStudio and Positron discover R installations by parsing `bin/R` as a text file rather than executing it. Two things must be true for IDE discovery to succeed:

- **`bin/R` must contain a parseable static `R_HOME_DIR=` line.** This is why `make-relocatable.sh` *inserts* a runtime override above the static line rather than replacing it. The IDE's parser finds the static line and is happy; the runtime override fires at exec time and pins `R_HOME_DIR` to the actual extracted path. The catch-all `sed` that converts other framework references to `${R_HOME}` excludes any line starting with `R_HOME_DIR=` so this static value survives intact — without that exclusion the static line gets rewritten to `R_HOME_DIR=${R_HOME}` and Positron rejects the install with `Can't find DESCRIPTION for the utils package at ${R_HOME}/library/utils/DESCRIPTION`.
- **Startup hooks must live in the base Rprofile** (`library/base/R/Rprofile`), not in `etc/Rprofile.site`. `etc/Rprofile.site` is skipped under `R --vanilla` and may be skipped or sourced at an unexpected time when the IDE embeds R via `libR.dylib`. The base Rprofile is sourced unconditionally during R's own startup sequence.

### Positron's "orthogonal install" check requires the framework path to exist

Positron (`getRHomePathDarwin` in `extensions/positron-r/src/r-installation.ts`) extracts the value of the first `R_HOME_DIR=` line and then validates that path on disk by looking for `library/utils/DESCRIPTION` inside it. Our portable R's static line points at the canonical framework path (e.g. `/Library/Frameworks/R.framework/Versions/4.4-arm64/Resources`), which only resolves on a host that has a real R 4.4 install at that location. On a host that has, say, only R 4.5 installed, Positron rejects our portable R as an "invalid installation" even though it works fine from the command line, RStudio, and any embedded R consumer that doesn't go through Positron's discovery path.

Workarounds for end users who need Positron compatibility:

- **Symlink the canonical path** to the portable install:
  ```bash
  sudo mkdir -p /Library/Frameworks/R.framework/Versions/<ver>-<arch>
  sudo ln -s /path/to/extracted/R-<ver> \
    /Library/Frameworks/R.framework/Versions/<ver>-<arch>/Resources
  ```
  Test-only, requires sudo. Don't do this on a system with a real R install at the same version.
- **Install the portable R *at* the canonical path** in the first place. Defeats the "extract anywhere" design but does work transparently with Positron.
- **Use a different IDE** (RStudio, Positron-Pro Server, plain console) that doesn't have the same discovery requirement.

A cleaner long-term fix would be to either upstream a relaxation of Positron's path check (allow `bin/R`-relative discovery as a fallback when the parsed `R_HOME_DIR` doesn't resolve) or to ship the build's static `R_HOME_DIR=` line as a placeholder Positron is willing to accept. Both are deferred until the design is past the experimental phase.

### RStudio's `install.packages` wrapper

RStudio attaches a `tools:rstudio` environment at search position 2 during session init. `tools:rstudio` does **not** include an `install.packages` override (verified by `find('install.packages')` returning `.portable package:utils` from inside an RStudio session, with the `.portable` wrapper's `fix_pkgs` body present). So our `setHook(packageEvent("stats", "attach"), ...)` mechanism that re-attaches `.portable` at search position 2 ends up at position 3 after RStudio's own attach, but still wins for `install.packages()` resolution — search-path lookup walks the path top-down and `tools:rstudio` is transparent for that name.

Validated end-to-end on RStudio macOS arm64 with R 4.4.3: `install.packages("jsonlite")` from the RStudio console correctly downloaded the CRAN binary `.tgz`, the `.portable` wrapper's `install_name_tool` patch ran, and `library(jsonlite)` loaded cleanly with zero remaining `/Library/Frameworks/R.framework` references in the installed `.so`.

## Adding support for a new R minor version

Most new R minor versions need no code changes. The build matrix in `build-macos.yml` resolves `last-5,3.6.3,devel` via `manage_r_versions.py`, so a new release version is automatically picked up.

Two cases require maintenance:

- **R rolls to a new major branch** (e.g. 4.6 → 4.7). `build.sh`'s `resolve_pkg_url()` iterates a fixed `branches=("4.8" "4.7" "4.6" "4.5" "4.4")` list newest-first when resolving devel URLs. When a new branch opens, prepend the new branch number; when the oldest branch closes, drop it.
- **CRAN changes its directory layout** (has happened multiple times — `big-sur-arm64`, `big-sur-x86_64`, the unified `macosx/base`, and `cran-archive.r-project.org` are all current as of 2026-04). When this happens, add the new candidate to `resolve_pkg_url()` and probe newest-first.

Beyond URL resolution, the patching pipeline is structurally version-agnostic. The two version-aware code paths are:

- The Rscript wrapper in `make-relocatable.sh` (R < 4.2 vs R >= 4.2 — see Phase 3 above).
- The Tcl/Tk sub-package extraction in `build.sh` (R < 4.3 ships it as a separate `tcltk*.pkg`; R >= 4.3 bundles it in R.framework).

If a new R version breaks something, start by checking whether either of those branches needs updating.

## Build and test commands

```bash
# Build R for macOS (defaults to host architecture)
R_VERSION=4.4.3 make build-r-macos

# Build a specific architecture
R_VERSION=4.4.3 ARCH=arm64 make build-r-macos
R_VERSION=4.4.3 ARCH=x86_64 make build-r-macos    # runs under Rosetta 2

# Run integration tests against a built tarball
R_VERSION=4.4.3 make test-r-macos
R_VERSION=4.4.3 ARCH=x86_64 make test-r-macos

# Direct invocation (no Make)
bash macos/build.sh 4.4.3 arm64 output
tar xzf output/R-4.4.3-macos-arm64.tar.gz -C output/
bash macos/test.sh output/R-4.4.3
```

The Makefile's `build-r-macos` target also extracts the tarball before running tests so `make build-r-macos && make test-r-macos` works locally.

## What the tests verify

`test.sh` covers:

- R starts and reports its version.
- `R.home()` matches the extracted directory (proves runtime `R_HOME` derivation).
- `Rscript` works and produces correct stdout.
- `capabilities("cairo")`, `capabilities("png")`, `capabilities("tcltk")` all return `TRUE`.
- `solve(matrix(1:4, 2, 2))` works (proves BLAS/LAPACK link-loads).
- No Mach-O file in the tree references `/Library/Frameworks/R.framework`, `/tmp/r-build|install`, `/opt/homebrew`, `/opt/R`, or `/usr/local/(Cellar|opt|lib)` — proves Phase 1 covered everything.
- `etc/Makeconf` LIBR uses `-lR` (not `-framework R`) — proves Phase 3.
- R works without `DYLD_LIBRARY_PATH` / `DYLD_FALLBACK_LIBRARY_PATH` — proves rpath rewriting is sufficient on its own.
- Relocatability — copy R to `/tmp/r-relocated-{pid}`, verify `R.home()` reports the new path and Rscript runs there.
- Source package compilation (`install.packages("jsonlite", type="source")`) — exercises Makeconf, headers, linker flags. Requires Xcode CLT.
- Base Rprofile hooks survive `R --vanilla` — proves the move from `etc/Rprofile.site` to the base Rprofile worked, and `.portable` is attached.
- Binary package install via `install.packages("jsonlite", type="binary")` — exercises the `.portable` hook's `install_name_tool` fix-up. Both CRAN and PPM are passed as repos so the call resolves on whichever serves the binary for this R version × arch combo.

## Troubleshooting

**"image not found" loading a package after `install.packages()`** — the package's `.so` files still reference `/Library/Frameworks/R.framework/...`. The `.portable` hook didn't run (likely shadowed by an IDE) or was disabled. Run `~/R/R-{version}/bin/fix-dylibs` manually.

**`Rscript` complains about `R_HOME`** — for R < 4.2 the Rscript binary ignores `R_HOME` and uses compiled-in paths. The shell wrapper installed by `make-relocatable.sh` should sidestep this; if it didn't (e.g. someone re-extracted the tarball over an existing install), re-run `make-relocatable.sh`.

**Gatekeeper blocks bin/R on first run** — if you downloaded the tarball with `curl` and the build was not notarized, run `xattr -dr com.apple.quarantine ~/R/R-{version}` once. Notarized production builds should not need this.

**`bin/R` works but the IDE can't find R** — verify `bin/R` still contains a static `R_HOME_DIR=...` line. If it was overwritten (e.g. by an extra sed pass), the IDE's text parser can't extract a path. The runtime override should be *inserted before* the static line, not replace it.

## Related projects

- **[portable-r/portable-r-macos](https://github.com/portable-r/portable-r-macos)** — independent prototype of the same approach. Used as a reference; this pipeline shares its core idea (CRAN .pkg + post-process) but adds CI integration, Developer ID signing, the version-aware Rscript wrapper, and the base-Rprofile hook design.
- **[builder/portable-r/](../builder/portable-r/README.md)** — the Linux portable builds. Different mechanism (compile from source + bundle libs via `delocate_r.py`) but the same goal of relocatable, distribution-independent R.
