#!/usr/bin/env bash
set -euo pipefail

R_HOME="${1:?Usage: install-rprofile-hook.sh <r-home>}"
R_HOME="$(cd "${R_HOME}" && pwd)"

echo "=== Installing Rprofile.site hook in ${R_HOME} ==="

cat > "${R_HOME}/etc/Rprofile.site" << 'RPROFILE'
# Rprofile.site — rstudio/r-builds portable R distribution
# This file is sourced at R startup. It provides:
# 1. Automatic patching of CRAN binary packages for macOS portability
# 2. Posit Package Manager as default repository

# ── Default repository: Posit Package Manager ──────────────────────
local({
  r <- getOption("repos")
  r["CRAN"] <- "https://packagemanager.posit.co/cran/latest"
  options(repos = r)
})

# ── Tcl/Tk library paths (for bundled Tcl/Tk) ────────────────────
# CRAN binary packages and older .pkg installers expect Tcl/Tk at a
# system path. When we bundle Tcl/Tk in our lib/ directory, we need
# to tell R where to find the script files (init.tcl, etc.).
# Following r-builds PR #280 pattern.
local({
  r_home <- Sys.getenv("R_HOME", R.home())
  tcl_dir <- file.path(r_home, "lib", "tcl8.6")
  tk_dir <- file.path(r_home, "lib", "tk8.6")
  if (Sys.getenv("TCL_LIBRARY") == "" && file.exists(tcl_dir))
    Sys.setenv(TCL_LIBRARY = tcl_dir)
  if (Sys.getenv("TK_LIBRARY") == "" && file.exists(tk_dir))
    Sys.setenv(TK_LIBRARY = tk_dir)
})

# ── .portable environment: CRAN binary package compatibility ───────
# CRAN binary packages (.tgz) embed absolute Mach-O paths from the
# CRAN build machine (/Library/Frameworks/R.framework/...). This hook
# transparently rewrites them after install.packages() completes.

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
  # Default packages load after Rprofile.site (pushing any early attach down),
  # so we hook into the last default package (stats) to re-attach at position 2.
  setHook(packageEvent("stats", "attach"), function(...) {
    if (".portable" %in% search()) try(detach(".portable"), silent = TRUE)
    attach(.portable, name = ".portable", pos = 2L, warn.conflicts = FALSE)
  })
})
RPROFILE

# ── Also create bin/fix-dylibs for manual use ──────────────────────
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

echo "=== Rprofile.site hook installed ==="
