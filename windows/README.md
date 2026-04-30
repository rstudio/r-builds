# Portable Windows R builds

This directory builds portable, relocatable Windows R distributions by extracting the official CRAN `.exe` installer without running it. The output is a `.zip` that can be extracted to any directory and run from there — no admin rights, no Inno Setup installer dialog, no registry changes, and no side effects on the system R installation.

## Overview

Unlike macOS (which needs a Mach-O patching pipeline because CRAN binaries embed `/Library/Frameworks/R.framework/...` paths), Windows R from CRAN is already largely self-contained: all DLL dependencies are bundled inside `bin\x64\`, paths in `etc\` files use `${R_HOME}` substitution, and `R.exe` discovers its own home directory at runtime via `GetModuleFileName`. As a result, the only post-processing needed is:

1. Download the CRAN `.exe` installer.
2. Extract it with [`innoextract`](https://github.com/dscharrer/innoextract) (no admin, no install). Falls back to `/VERYSILENT /CURRENTUSER` silent install if `innoextract` is unavailable.
3. Clean up `unins*` installer artifacts.
4. Append portable-R hooks (default CRAN repo, portable site-library) to the base Rprofile.
5. Package as `R-{version}-windows.zip`.

No DLL rewriting, no rpath fix-up, no codesigning. Output: a self-contained zip where `bin\R.exe --version` works regardless of where it's extracted.

## Files

```
windows/
  build.ps1   # Orchestrator: download .exe → extract → configure → zip
  test.ps1    # Integration tests (relocatability, Rprofile hooks, package install)
```

## Use cases

Portable Windows builds are useful for:

- **Version managers** (rig, custom scripts) that install multiple R versions side-by-side under user-chosen directories.
- **CI / cloud runners** where you want a specific R version without an admin install.
- **Air-gapped systems** — copy the zip to a machine without internet access.
- **Developer environments** where switching between R versions for a project shouldn't require re-running the Inno Setup installer.

## Limitations

- **x86_64 only.** Windows arm64 R builds exist but the support is too new to base a portable distribution on. We can revisit when CRAN's Windows arm64 binaries are stable.
- **No Rtools bundled.** Compiling R packages from source still requires installing Rtools separately (matched to the R minor version, e.g. Rtools 4.4 for R 4.4.x).
- **CRAN-bundled libraries pin at build time.** Whatever DLLs ship in the `.exe` installer are what end users get; updating requires rebuilding from a newer CRAN release.

## What gets built

x86_64 only, R 3.6.3 onwards. The build matrix in `build-windows.yml` defaults to the last 5 R minor versions plus R 3.6.3 and `devel`. R 3.6.3 is included as a long-term compatibility anchor matching the existing Linux builds.

Output paths on the CDN follow the existing pattern:

```
cdn.posit.co/r/windows/R-{version}-windows.zip
```

## How it works

### Phase 1 — Download (`build.ps1`)

CRAN's Windows installer URL has three tiers, probed newest-first:

| Tier | URL pattern |
|---|---|
| Current release | `cloud.r-project.org/bin/windows/base/R-{ver}-win.exe` |
| Old releases (still on main CDN) | `cloud.r-project.org/bin/windows/base/old/{ver}/R-{ver}-win.exe` |
| Retired releases | `cran-archive.r-project.org/bin/windows/base/old/{ver}/R-{ver}-win.exe` |

Devel uses its own stable URL: `cloud.r-project.org/bin/windows/base/R-devel-win.exe`. The download is cached at `$env:TEMP\R-{ver}-win.exe` and reused on re-runs of the same version (~80 MB per installer adds up otherwise).

`$ProgressPreference = 'SilentlyContinue'` is set globally in the script. PowerShell 5.1's progress bar slows `Invoke-WebRequest` and `Expand-Archive` by 50–100x when running non-interactively (e.g. on GitHub Actions). Without this, a 30-second build takes 25 minutes.

### Phase 2 — Extraction (`build.ps1`)

The installer is an Inno Setup `.exe`. Two extraction methods, in order:

1. **Primary: `innoextract`.** Unpacks the embedded payload directly without running the installer. No admin, no registry, no side effects. We try `Get-Command innoextract` first; if it's not on `PATH`, we install it via `choco install innoextract` if Chocolatey is available; otherwise we download the [official 1.9 Windows release](https://github.com/dscharrer/innoextract/releases/download/1.9/innoextract-1.9-windows.zip) directly. innoextract drops files into `{StagingDir}/app/` — we move that up to `{StagingDir}` and remove the empty `app/` directory.

2. **Fallback: silent install.** If `innoextract` extraction returns non-zero (sometimes happens on very new R versions before innoextract has been updated), we fall back to running the Inno Setup installer with `/VERYSILENT /CURRENTUSER /DIR=<StagingDir>`. This is a real install — the installer process runs to completion — but `/CURRENTUSER` keeps it out of `Program Files` and `/DIR` overrides the default install location. The installer leaves `unins*.{exe,dat,msg}` files behind which we delete in Phase 3.

The 10-minute timeout on the silent install is intentional — Inno Setup occasionally hangs on certain Windows 11 builds, and a stuck CI job is worse than a failed one.

### Phase 3 — Cleanup (`build.ps1`)

Remove `unins*.exe`, `unins*.dat`, `unins*.msg`, and any `*.iss` files. These are installer-only artifacts from the silent-install fallback and serve no purpose at runtime.

### Phase 4 — Portable-R hooks (`build.ps1`)

The script appends two `local()` blocks to **`library\base\R\Rprofile`** (the base Rprofile, sourced by R itself during startup). It is **not** written to `etc\Rprofile.site` — that file is skipped under `R --vanilla` and bypassed by IDEs that load `R.dll` directly without going through `R.exe`. The base Rprofile is sourced in every launch context. This matches the manylinux PR #280 and macOS approach.

The two hooks installed:

1. **Portable site-library** — adds `Sys.getenv("R_HOME")/site-library` to `.libPaths()` so user packages install into the R folder by default. Two consequences:
   - When you copy or move the R-{version} folder, your installed packages travel with it.
   - The default `R_LIBS_USER` location (`Documents\R\win-library\X.Y`) is OS-version-dependent; pinning to `R_HOME/site-library` is more predictable for portable use.
   - If `R_HOME` is on a read-only filesystem (rare for portable use), `dir.create` silently fails and we leave `.libPaths()` unchanged. R falls back to the standard user library.

2. **Default CRAN repo** → `https://p3m.dev/cran/latest` (Posit Public Package Manager). Provides binary R packages for Windows for the same R version matrix this build targets.

The append is done with `[System.IO.File]::AppendAllText` rather than `Add-Content` because `Add-Content` adds CRLF line endings via `$OutputEncoding`, which would mix with the LF-only line endings in CRAN's base Rprofile. R reads either fine, but mixing is ugly.

### Phase 5 — Packaging (`build.ps1`)

`Compress-Archive` to a `.zip` named `R-{version}-windows.zip`. The staging tree is removed in a `finally` block, but the cached `.exe` installer at `$env:TEMP\R-{ver}-win.exe` is intentionally preserved so re-runs of the same version skip the download.

`$OutputDir` handling: PowerShell's `Join-Path` naively concatenates even when the second argument is rooted, producing e.g. `D:\repo\D:\temp\out`. CI passes a rooted `$env:RUNNER_TEMP\r-builds-output`, so we test `[System.IO.Path]::IsPathRooted($OutputDir)` and use `$OutputDir` directly when it's already rooted; otherwise we resolve relative to the repo root.

## IDE compatibility (RStudio, Positron)

Both RStudio and Positron on Windows discover R installations by parsing files in the install tree (registry-based discovery is a fallback). Two requirements:

- **`bin\R.exe` and `bin\x64\R.exe` must both exist.** Older RStudio versions look for `bin\x64\R.exe` specifically (R 4.1 and earlier had separate 32-bit and 64-bit builds in `bin\i386\` and `bin\x64\`); newer RStudio also accepts `bin\R.exe` in the unified layout used since R 4.2. The CRAN installer's payload covers both layouts depending on the R version, and our extraction preserves what CRAN ships.
- **Startup hooks must live in the base Rprofile** (`library\base\R\Rprofile`), not in `etc\Rprofile.site`. `etc\Rprofile.site` is skipped under `R --vanilla` and may be skipped or sourced at an unexpected time when the IDE embeds R via `R.dll`. The base Rprofile is sourced unconditionally during R's own startup sequence.

For RStudio specifically, the IDE wraps `install.packages()` with its own override at startup. Unlike macOS, no `.so` fix-up wrapper is needed on Windows — CRAN binary `.zip` packages are already self-contained — so the IDE wrapping is harmless here.

## R < 4.2 caveat: Rfe.exe argv quoting bug

On R < 4.2, `bin\R.exe` and `bin\Rscript.exe` are `Rfe.exe` launchers (`src/gnuwin32/front-ends/Rfe.c`) that re-assemble `argv` into a `cmd.exe` command string without escaping internal quotes. Result: `Rscript -e "cat('hello')"` silently truncates the expression at the first quote.

The real binaries live at `bin\x64\R.exe` and `bin\x64\Rterm.exe` in those older versions. `test.ps1` works around this by:

1. Preferring `bin\x64\R.exe` over `bin\R.exe` when both exist.
2. Writing the R expression to a temp file and using `R.exe -f <file>` instead of `R.exe -e <string>`.

R 4.2 and later put the real binaries in `bin\` directly and don't have this bug, but the temp-file approach works on all versions so the test code uses it unconditionally.

## Adding support for a new R minor version

Most new R minor versions need no code changes. The build matrix in `build-windows.yml` resolves `last-5,3.6.3,devel` via `manage_r_versions.py`, so a new release version is automatically picked up.

Two cases require maintenance:

- **CRAN moves an old release off the main mirror to `cran-archive.r-project.org`.** Already handled by the third candidate URL — no action needed unless CRAN changes the path layout.
- **Inno Setup ships a format change innoextract doesn't yet support.** The silent-install fallback covers this. If innoextract starts failing on every new R release, watch for [innoextract releases](https://github.com/dscharrer/innoextract/releases) and update the pinned `1.9` reference to the newest version.

## Build and test commands

```powershell
# Build R for Windows
$env:R_VERSION = "4.4.3"; make build-r-windows

# Run integration tests against a built zip (extracted automatically by Make)
$env:R_VERSION = "4.4.3"; make test-r-windows

# Direct invocation (no Make)
.\windows\build.ps1 -Version 4.4.3 -OutputDir output
Expand-Archive output\R-4.4.3-windows.zip -DestinationPath output\
.\windows\test.ps1 -RHome output\R-4.4.3
```

The Makefile's `build-r-windows` target also extracts the zip before running tests so `make build-r-windows && make test-r-windows` works locally.

## What the tests verify

`test.ps1` covers:

- R starts and reports its version.
- `R.home()` matches the extracted directory (proves runtime path discovery survives extraction to an arbitrary location).
- R evaluates expressions from a `-f <file>` invocation (sidesteps the R < 4.2 Rfe.exe argv-quoting bug).
- Relocatability — copy R to `$env:TEMP\r-relocated-test`, verify R still starts and produces correct stdout there.
- Base Rprofile hooks survive `R --vanilla`: default CRAN repo is `p3m.dev`, portable site-library is on `.libPaths()`.
- Binary package install via `install.packages("jsonlite")` against PPM. CRAN's `bin/windows/contrib/3.6/` is empty (CRAN only retains the installer for old R, not the compiled packages); PPM serves Windows binaries for every R minor from 3.6 onward.

## Troubleshooting

**`Rscript -e "expr"` silently truncates the expression** — you're on R < 4.2 and hitting the Rfe.exe argv bug. Use `Rscript -f <file>` or upgrade to R 4.2+.

**Extraction fails with `innoextract: not a supported Inno Setup version`** — innoextract is older than the Inno Setup version CRAN used. The silent-install fallback should kick in automatically; if not, force it by removing innoextract from `PATH` before running the build script.

**R can't find packages after the install tree is moved** — verify the portable site-library hook ran. Check `tail -1 library\base\R\Rprofile` (or `Get-Content library\base\R\Rprofile -Tail 20`) and confirm the `local_lib <- file.path(Sys.getenv("R_HOME"), "site-library")` block is present.

**Build is extremely slow on PowerShell 5.1** — `$ProgressPreference = 'SilentlyContinue'` is set in `build.ps1`, but if you're invoking the script with `-NoProfile` and overriding the variable, restore it. The PS 5.1 progress bar is a known bottleneck for `Invoke-WebRequest` and `Expand-Archive`.

## Related projects

- **[portable-r/portable-r-windows](https://github.com/portable-r/portable-r-windows)** — independent prototype of the same approach. Used as a reference; this pipeline shares its core idea (CRAN .exe extraction + minimal post-process) but adds CI integration, the innoextract+silent-install fallback chain, and the base-Rprofile hook design.
- **[`macos/README.md`](../macos/README.md)** — companion macOS portable builds. Same goals, much heavier post-processing because CRAN macOS binaries embed framework paths.
- **[`builder/portable-r/`](../builder/portable-r/README.md)** — the Linux portable builds. Different mechanism (compile from source + bundle libs via `delocate_r.py`) but the same goal of relocatable, distribution-independent R.
