#!/usr/bin/env bash
set -euo pipefail

# install-rprofile-hook.sh -- Install portable-R startup hooks into the base
# Rprofile so they apply in every R launch context.
#
# Why the base Rprofile and not etc/Rprofile.site?
#   etc/Rprofile.site is skipped under `R --vanilla` and is also bypassed
#   when an embedding host (RStudio's rsession, Positron's R kernel) loads
#   libR.so directly without going through bin/R. The base Rprofile at
#   library/base/R/Rprofile is sourced by R itself during startup, so it
#   runs in every launch context.
#
# This file appends three local() blocks to the base Rprofile:
#   1. Default CRAN repo -> p3m.dev (Posit Public Package Manager)
#   2. TCL_LIBRARY / TK_LIBRARY env vars pointing at our bundled lib/tcl8.6
#      and lib/tk8.6 directories (R < 4.3 needs these; R >= 4.3 ignores them
#      because Tcl/Tk is bundled inside R.framework)
#   3. A .portable environment that wraps install.packages() to rewrite
#      hardcoded /Library/Frameworks/R.framework/... load commands in
#      newly-installed CRAN binary packages. This is macOS-specific and
#      gated on Sys.info()[["sysname"]] == "Darwin".
#
# The existing Rprofile content from CRAN is preserved (we append, not
# overwrite). bin/fix-dylibs is also installed as a manual escape hatch
# in case the install.packages wrapper is shadowed by an IDE.

R_HOME="${1:?Usage: install-rprofile-hook.sh <r-home>}"
R_HOME="$(cd "${R_HOME}" && pwd)"

BASE_RPROFILE="${R_HOME}/library/base/R/Rprofile"
if [[ ! -f "${BASE_RPROFILE}" ]]; then
  echo "ERROR: base Rprofile not found at ${BASE_RPROFILE}" >&2
  exit 1
fi

echo "=== Appending portable-R hooks to ${BASE_RPROFILE} ==="

cat >> "${BASE_RPROFILE}" <<'RPROFILE'

## ── rstudio/r-builds portable R hooks ─────────────────────────────────
## Appended by install-rprofile-hook.sh. Lives in the base Rprofile so it
## runs in every launch context, including R --vanilla and IDE-embedded R.

## Default CRAN mirror: Posit Public Package Manager
local({
  r <- getOption("repos")
  r["CRAN"] <- "https://p3m.dev/cran/latest"
  options(repos = r)
})

## Tcl/Tk library paths for bundled scripts (R < 4.3; R >= 4.3 bundles
## these inside R.framework and ignores the env vars).
local({
  r_home <- Sys.getenv("R_HOME", R.home())
  tcl_dir <- file.path(r_home, "lib", "tcl8.6")
  tk_dir <- file.path(r_home, "lib", "tk8.6")
  if (Sys.getenv("TCL_LIBRARY") == "" && file.exists(tcl_dir))
    Sys.setenv(TCL_LIBRARY = tcl_dir)
  if (Sys.getenv("TK_LIBRARY") == "" && file.exists(tk_dir))
    Sys.setenv(TK_LIBRARY = tk_dir)
})

## .portable environment: macOS CRAN binary package fix-up.
##
## CRAN binary .tgz packages embed absolute Mach-O paths from the CRAN
## build host (/Library/Frameworks/R.framework/...). When R is installed
## anywhere else, those paths don't resolve and `library(pkg)` fails with
## "image not found." This wrapper runs install_name_tool on each .so
## immediately after install.packages() returns, rewriting the framework
## paths to @rpath references that resolve via R's lib/ directory.
##
## Known limitation: IDEs (RStudio, Positron) install their own
## install.packages() override that may shadow this wrapper. If you hit
## "image not found" errors after installing a package via an IDE, run
## `R_HOME/bin/fix-dylibs` manually to patch the installed package.
if (Sys.info()[["sysname"]] == "Darwin") local({
  .portable <- new.env(parent = baseenv())

  # Patch a single .so file: rewrite R.framework references to @rpath
  .portable$fix_so <- function(so) {
    refs <- system2("otool", c("-L", shQuote(so)), stdout = TRUE, stderr = FALSE)
    fw <- grep("/Library/Frameworks/R.framework", refs, value = TRUE)
    if (length(fw) == 0L) return(invisible(FALSE))
    for (line in fw) {
      old <- trimws(sub("\\s+\\(.*", "", line))
      system2("install_name_tool",
              c("-change", shQuote(old),
                shQuote(paste0("@rpath/", basename(old))),
                shQuote(so)),
              stdout = FALSE, stderr = FALSE)
    }
    system2("install_name_tool",
            c("-add_rpath", "@loader_path/../../../lib", shQuote(so)),
            stdout = FALSE, stderr = FALSE)
    system2("codesign", c("-f", "-s", "-", shQuote(so)),
            stdout = FALSE, stderr = FALSE)
    invisible(TRUE)
  }

  # Scan ALL packages in a library directory and patch any unfixed .so files
  .portable$fix_pkgs <- function(pkgs = NULL, lib = .libPaths()[1L]) {
    all_pkgs <- list.dirs(lib, full.names = FALSE, recursive = FALSE)
    fixed <- 0L
    for (pkg in all_pkgs) {
      so_files <- list.files(file.path(lib, pkg, "libs"),
                             pattern = "\\.so$", full.names = TRUE)
      for (so in so_files) {
        if (isTRUE(tryCatch(.portable$fix_so(so), error = function(e) NULL)))
          fixed <- fixed + 1L
      }
    }
    if (fixed > 0L)
      message(sprintf("Portable R: patched %d shared librar%s",
                      fixed, if (fixed == 1L) "y" else "ies"))
    invisible(fixed)
  }

  # Wrapper around utils::install.packages that patches .so files after install
  .portable$install.packages <- function(pkgs, ...) {
    utils <- asNamespace("utils")
    result <- utils$install.packages(pkgs, ...)
    mc <- match.call()
    lib_dir <- if ("lib" %in% names(mc)) eval(mc$lib) else .libPaths()[1L]
    try(.portable$fix_pkgs(pkgs, lib = lib_dir), silent = TRUE)
    invisible(result)
  }

  # Attach .portable above package:utils so it masks install.packages.
  # Default packages load after the base Rprofile runs (pushing any early
  # attach down), so we hook into the last default package (stats) to
  # re-attach at position 2.
  setHook(packageEvent("stats", "attach"), function(...) {
    if (".portable" %in% search()) try(detach(".portable"), silent = TRUE)
    attach(.portable, name = ".portable", pos = 2L, warn.conflicts = FALSE)
  })
})
RPROFILE

echo "  Appended portable-R hooks to base Rprofile"

# ── Manual escape hatch: bin/fix-dylibs ────────────────────────────
# If the .portable install.packages wrapper is shadowed by an IDE, the
# user can run this script to fix any unpatched .so files in their
# library tree.
echo "--- Creating bin/fix-dylibs ---"
cat > "${R_HOME}/bin/fix-dylibs" << 'FIXDYLIBS'
#!/usr/bin/env bash
set -euo pipefail
R_HOME="$(cd "$(dirname "$0")/.." && pwd)"
echo "Scanning for unpatched .so files in ${R_HOME}..."
count=0
for dir in "${R_HOME}/library" "${R_HOME}/modules"; do
  [ -d "$dir" ] || continue
  while IFS= read -r so; do
    if otool -L "$so" 2>/dev/null | grep -q "/Library/Frameworks/R.framework"; then
      otool -L "$so" | grep "/Library/Frameworks/R.framework" | awk '{print $1}' | while read -r old; do
        install_name_tool -change "$old" "@rpath/$(basename "$old")" "$so" 2>/dev/null
      done
      case "$so" in
        */modules/*)         install_name_tool -add_rpath "@loader_path/../lib" "$so" 2>/dev/null || true ;;
        */library/*/libs/*)  install_name_tool -add_rpath "@loader_path/../../../lib" "$so" 2>/dev/null || true ;;
      esac
      codesign -f -s - "$so" 2>/dev/null || true
      echo "  Patched: ${so#${R_HOME}/}"
      count=$((count + 1))
    fi
  done < <(find "$dir" -name "*.so" -type f 2>/dev/null)
done
echo "Done. Patched ${count} files."
FIXDYLIBS
chmod +x "${R_HOME}/bin/fix-dylibs"

echo "=== Portable-R hooks installed ==="
