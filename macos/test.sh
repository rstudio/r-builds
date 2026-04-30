#!/usr/bin/env bash
set -euo pipefail

R_HOME="${1:?Usage: test.sh <r-home>}"
R_HOME="$(cd "${R_HOME}" && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

MOVED=""
trap 'rm -rf "${MOVED}"' EXIT

echo "=== Testing R installation at ${R_HOME} ==="

# 1. R starts — released R prints "R version X.Y.Z", devel prints
# "R Under development (unstable) ..."; match both.
echo "--- Test: R starts ---"
if "${R_HOME}/bin/R" --version 2>&1 | head -1 | grep -qE "^R (version|Under development)"; then
  pass "R --version reports R version"
else
  fail "R --version did not report R version"
fi

# 1b. bin/R static R_HOME_DIR= line is well-formed for IDE discovery.
# Positron's getRHomePathDarwin parses this line as text and validates the
# resulting path on disk, so a malformed slot (e.g. ".-arm64" from a broken
# version-introspection fallback) would silently break IDE discovery even
# though CLI execution still works via the runtime override on the next line.
echo "--- Test: static R_HOME_DIR= slot is well-formed ---"
STATIC_LINE=$(grep '^R_HOME_DIR=' "${R_HOME}/bin/R" | head -1)
SLOT_RE='^R_HOME_DIR=/Library/Frameworks/R\.framework/Versions/(devel|patched|next|[0-9]+\.[0-9]+)-(arm64|x86_64)/Resources$'
if [[ "${STATIC_LINE}" =~ ${SLOT_RE} ]]; then
  pass "static R_HOME_DIR= slot: ${STATIC_LINE#R_HOME_DIR=/Library/Frameworks/R.framework/Versions/}"
else
  fail "static R_HOME_DIR= is malformed: ${STATIC_LINE}"
fi

# 2. R_HOME derivation
echo "--- Test: R_HOME derivation ---"
R_HOME_REPORTED=$("${R_HOME}/bin/R" --vanilla --no-echo -e 'cat(R.home())' 2>/dev/null)
R_HOME_RESOLVED="$(cd "${R_HOME}" && pwd -P)"
if [ "${R_HOME_REPORTED}" = "${R_HOME_RESOLVED}" ] || [ "${R_HOME_REPORTED}" = "${R_HOME}" ]; then
  pass "R.home() matches expected R_HOME"
else
  fail "R.home() = '${R_HOME_REPORTED}', expected '${R_HOME}'"
fi

# 3. Rscript works
echo "--- Test: Rscript ---"
RSCRIPT_OUT=$("${R_HOME}/bin/Rscript" -e 'cat("hello")' 2>/dev/null)
if [ "${RSCRIPT_OUT}" = "hello" ]; then
  pass "Rscript executes correctly"
else
  fail "Rscript output: '${RSCRIPT_OUT}', expected 'hello'"
fi

# 4. Capabilities
echo "--- Test: Capabilities ---"
for cap in cairo png tcltk; do
  if "${R_HOME}/bin/Rscript" -e "stopifnot(capabilities('${cap}'))" 2>/dev/null; then
    pass "capability: ${cap}"
  else
    fail "capability: ${cap} not available"
  fi
done

# 5. BLAS/LAPACK
echo "--- Test: BLAS/LAPACK ---"
if "${R_HOME}/bin/Rscript" -e 'stopifnot(is.numeric(solve(matrix(1:4,2,2))))' 2>/dev/null; then
  pass "BLAS/LAPACK: matrix solve works"
else
  fail "BLAS/LAPACK: matrix solve failed"
fi

# 6. No hardcoded framework paths in Mach-O
echo "--- Test: No hardcoded paths ---"
HARDCODED_FOUND=0
while IFS= read -r f; do
  if file "${f}" 2>/dev/null | grep -q "Mach-O"; then
    if otool -L "${f}" 2>/dev/null | grep -qE "/tmp/r-(build|install)|/Library/Frameworks/R\.framework|/opt/(homebrew|R/)|/usr/local/(Cellar|opt|lib)"; then
      fail "hardcoded path in ${f#${R_HOME}/}"
      otool -L "${f}" | grep -E "/tmp/r-(build|install)|/Library/Frameworks|/opt/(homebrew|R/)|/usr/local/(Cellar|opt|lib)" | head -3
      HARDCODED_FOUND=1
    fi
  fi
done < <(find "${R_HOME}" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) 2>/dev/null)
if [ "${HARDCODED_FOUND}" -eq 0 ]; then
  pass "no hardcoded absolute paths in any Mach-O binary"
fi

# 7. Makeconf uses -lR not -framework R
echo "--- Test: Makeconf ---"
if [ -f "${R_HOME}/etc/Makeconf" ]; then
  LIBR=$(grep "^LIBR " "${R_HOME}/etc/Makeconf" 2>/dev/null || true)
  if echo "${LIBR}" | grep -q "\-lR"; then
    pass "Makeconf LIBR uses -lR"
  else
    fail "Makeconf LIBR: ${LIBR}"
  fi
  if echo "${LIBR}" | grep -q "framework"; then
    fail "Makeconf LIBR still references -framework"
  fi
fi

# 8. Works without DYLD vars
echo "--- Test: No DYLD vars needed ---"
if env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH \
    "${R_HOME}/bin/Rscript" -e 'cat("no DYLD OK")' 2>/dev/null | grep -q "no DYLD OK"; then
  pass "works without DYLD_* variables"
else
  fail "requires DYLD_* variables"
fi

# 9. Relocatability (R and Rscript both exercised at the new location)
echo "--- Test: Relocatability ---"
MOVED="/tmp/r-relocated-$$"
cp -R "${R_HOME}" "${MOVED}"
MOVED_HOME=$("${MOVED}/bin/R" --vanilla --no-echo -e 'cat(R.home())' 2>/dev/null)
MOVED_RESOLVED="$(cd "${MOVED}" && pwd -P)"
if [ "${MOVED_HOME}" = "${MOVED_RESOLVED}" ] || [ "${MOVED_HOME}" = "${MOVED}" ]; then
  pass "relocated R reports correct new R_HOME"
  if "${MOVED}/bin/Rscript" -e 'cat("relocated Rscript OK\n")' 2>/dev/null | grep -q "relocated Rscript OK"; then
    pass "relocated Rscript works"
  else
    fail "relocated Rscript failed"
  fi
else
  fail "relocated R.home() = '${MOVED_HOME}', expected '${MOVED}'"
fi
rm -rf "${MOVED}"

# 10. Source package compilation — exercises Makeconf, headers, linker flags
echo "--- Test: Source package compilation ---"
if "${R_HOME}/bin/R" --vanilla --no-echo -e '
  tmp <- tempdir()
  install.packages("jsonlite", repos="https://cloud.r-project.org", type="source", lib=tmp, quiet=TRUE)
  stopifnot(requireNamespace("jsonlite", lib.loc=tmp))
  cat("source install OK\n")
' 2>/dev/null | grep -q "source install OK"; then
  pass "source package compilation (jsonlite)"
else
  fail "source package compilation failed (may need Xcode CLT)"
fi

# 11. Base Rprofile hooks survive --vanilla — the whole reason we install
# them in library/base/R/Rprofile rather than etc/Rprofile.site (which
# --vanilla skips) is so they work in every launch context including
# IDE-embedded R sessions. This test asserts:
#   - default CRAN repo is p3m.dev (PPM)
#   - .portable environment is attached at position 2 above package:utils
echo "--- Test: Base Rprofile hooks under --vanilla ---"
HOOK_OUT=$("${R_HOME}/bin/R" --vanilla --no-echo -e '
  cat("repo=", getOption("repos")["CRAN"], "\n", sep="")
  cat("portable_attached=", ".portable" %in% search(), "\n", sep="")
' 2>/dev/null)
if echo "${HOOK_OUT}" | grep -q '^repo=https://p3m\.dev/'; then
  pass "default CRAN repo set to p3m.dev under --vanilla"
else
  fail "default CRAN repo not p3m.dev under --vanilla: $(echo "${HOOK_OUT}" | grep '^repo=')"
fi
if echo "${HOOK_OUT}" | grep -q '^portable_attached=TRUE'; then
  pass ".portable env attached under --vanilla"
else
  fail ".portable env not attached under --vanilla: $(echo "${HOOK_OUT}" | grep '^portable_attached=')"
fi

# 12. Binary package install — exercises the .portable Rprofile hook's
# post-install dylib fix-up (install_name_tool + codesign).
#
# Use CRAN + PPM together so install.packages picks whichever has the
# binary for this R version × platform combo:
#   - CRAN covers R 4.2+ big-sur-arm64, 4.3+ big-sur-x86_64, 4.6 sonoma-arm64,
#     plus old unified macosx/contrib/4.1/ (but only for x86_64 pkgType).
#   - PPM covers R 4.1-4.5 on both arches via legacy paths.
#   - Neither has R 3.x (matrix skips those).
# R resolves Contrib URLs via .Platform$pkgType, so passing both repos lets
# install.packages find the package in whichever serves it.
echo "--- Test: Binary package install ---"
if "${R_HOME}/bin/R" --no-save --no-restore --no-init-file --no-echo -e '
  tmp <- tempdir()
  repos <- c(CRAN = "https://cloud.r-project.org",
             PPM  = "https://packagemanager.posit.co/cran/latest")
  install.packages("jsonlite", repos=repos, type="binary", lib=tmp, quiet=TRUE)
  stopifnot(requireNamespace("jsonlite", lib.loc=tmp))
  cat("binary install OK\n")
' 2>/dev/null | grep -q "binary install OK"; then
  pass "binary package install (jsonlite)"
else
  fail "binary package install failed"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [ "${FAIL}" -gt 0 ]; then exit 1; fi
