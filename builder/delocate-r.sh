#!/bin/bash
set -euo pipefail

# delocate-r.sh — Bundle system library dependencies into an R installation
#
# Replaces auditwheel-r with a simple shell script using ldd + patchelf.
# Discovers non-allowed shared library dependencies, copies them into
# lib/R/lib/.libs/ with hash-renamed filenames, rewrites RPATHs and DT_NEEDED
# entries so the R installation is self-contained and portable.
#
# Operates in-place on the R installation directory.
#
# Usage: delocate-r.sh <r-install-path>

# ── Allowed libraries (not bundled) ──────────────────────────────────────────
#
# These are expected to exist on any glibc 2.28+ system. Based on the
# manylinux_2_28 standard (PEP 600), minus X11 libs which we bundle for
# maximum portability.
#
# Notable: libX11, libSM, libICE, libXext, libXrender, libglib-2.0, and
# libgobject-2.0 are in the official manylinux_2_28 allowlist but we
# intentionally exclude them so they get bundled, making R work on minimal
# systems without X11 or GLib packages installed.
ALLOWED_LIBS=(
  # glibc core
  "linux-vdso.so"
  "ld-linux-x86-64.so"
  "ld-linux-aarch64.so"
  "libc.so"
  "libm.so"
  "libdl.so"
  "librt.so"
  "libpthread.so"
  "libnsl.so"
  "libutil.so"
  "libresolv.so"
  "libanl.so"
  # Compiler runtime
  "libgcc_s.so"
  "libstdc++.so"
  "libatomic.so"
  # Core system libs
  "libz.so"
  "libexpat.so"
  # GL (keep as system — drivers are system-specific)
  "libGL.so"
  # R internal (loaded via LD_LIBRARY_PATH from ldpaths, not RPATH)
  "libR.so"
  "libRblas.so"
  "libRlapack.so"
)

# ── Helper: compute relative path (pure bash) ───────────────────────────────

relpath() {
  # Compute relative path from $2 to $1 (like python's os.path.relpath)
  # Both paths must be absolute.
  local target="$1"
  local base="$2"

  # Normalize: remove trailing slashes
  target="${target%/}"
  base="${base%/}"

  # Split into arrays
  IFS='/' read -ra target_parts <<< "$target"
  IFS='/' read -ra base_parts <<< "$base"

  # Find common prefix length
  local common=0
  local max=${#base_parts[@]}
  [ ${#target_parts[@]} -lt $max ] && max=${#target_parts[@]}
  while [ $common -lt $max ] && [ "${target_parts[$common]}" = "${base_parts[$common]}" ]; do
    ((common++))
  done

  # Build relative path: go up from base, then down to target
  local result=""
  local i
  for ((i=common; i<${#base_parts[@]}; i++)); do
    result="${result}../"
  done
  for ((i=common; i<${#target_parts[@]}; i++)); do
    result="${result}${target_parts[$i]}/"
  done

  # Remove trailing slash
  result="${result%/}"
  [ -z "$result" ] && result="."
  echo "$result"
}

# ── Parse arguments ──────────────────────────────────────────────────────────

R_PATH="${1:?Usage: delocate-r.sh <r-install-path>}"

if [ ! -d "$R_PATH" ]; then
  echo "ERROR: R installation not found at $R_PATH" >&2
  exit 1
fi

# Strip trailing slash and resolve to absolute path
R_PATH="${R_PATH%/}"
R_PATH="$(cd "$R_PATH" && pwd)"
LIBS_SDIR="lib/R/lib/.libs"
DEST_DIR="${R_PATH}/${LIBS_SDIR}"

echo "delocate-r: repairing $R_PATH (in-place)"

# ── Helper: check if a soname is on the allowlist ────────────────────────────

is_allowed() {
  local soname="$1"
  for allowed in "${ALLOWED_LIBS[@]}"; do
    # Match prefix — e.g., "libz.so" matches "libz.so.1"
    if [[ "$soname" == "${allowed}"* ]]; then
      return 0
    fi
  done
  return 1
}

# ── Phase 1: Discover all ELF files ─────────────────────────────────────────

echo "  Discovering ELF files..."
mapfile -t ELF_FILES < <(
  find "$R_PATH" -type f \( -name "*.so" -o -name "*.so.*" -o -name "R" \) -print0 |
    xargs -0 file --mime-type 2>/dev/null |
    grep -E 'application/x-(pie-)?executable|application/x-sharedlib' |
    cut -d: -f1
)
echo "  Found ${#ELF_FILES[@]} ELF files"

# ── Phase 2: Discover external dependencies ──────────────────────────────────

# Map: soname -> system path (for libs we need to bundle)
declare -A EXTERNAL_LIBS
# Map: elf_file -> space-separated list of sonames it needs
declare -A ELF_NEEDS

echo "  Analyzing dependencies..."
for elf in "${ELF_FILES[@]}"; do
  # ldd resolves all transitive deps. We only need direct DT_NEEDED entries
  # that resolve to system paths (outside R_PATH).
  needs=""
  while IFS= read -r line; do
    # ldd output: "\tlibfoo.so.1 => /usr/lib64/libfoo.so.1 (0x...)"
    # or:         "\tlinux-vdso.so.1 (0x...)"
    # or:         "\t/lib64/ld-linux-x86-64.so.2 (0x...)"
    soname=$(echo "$line" | sed -n 's/^\t\([^ ]*\) => .*/\1/p')
    resolved=$(echo "$line" | sed -n 's/^\t[^ ]* => \([^ ]*\) .*/\1/p')

    [ -z "$soname" ] && continue
    [ -z "$resolved" ] && continue
    [ "$resolved" = "not" ] && continue  # "not found"

    # Skip libs inside the R installation (already bundled or internal)
    if [[ "$resolved" == "${R_PATH}"/* ]]; then
      continue
    fi

    # Skip allowed system libs
    if is_allowed "$soname"; then
      continue
    fi

    EXTERNAL_LIBS["$soname"]="$resolved"
    needs="$needs $soname"
  done < <(LD_LIBRARY_PATH="${R_PATH}/lib/R/lib:${LD_LIBRARY_PATH:-}" ldd "$elf" 2>/dev/null || true)

  if [ -n "$needs" ]; then
    ELF_NEEDS["$elf"]="$needs"
  fi
done

echo "  External libraries to bundle: ${#EXTERNAL_LIBS[@]}"
for soname in "${!EXTERNAL_LIBS[@]}"; do
  echo "    $soname -> ${EXTERNAL_LIBS[$soname]}"
done

if [ ${#EXTERNAL_LIBS[@]} -eq 0 ]; then
  echo "  No external libraries to bundle."
  exit 0
fi

# ── Phase 3: Copy and hash-rename external libraries ────────────────────────

echo "  Bundling libraries into $LIBS_SDIR/"
mkdir -p "$DEST_DIR"

# Map: old soname -> new hash-renamed soname
declare -A SONAME_MAP
# Map: old soname -> dest path of the copied lib
declare -A SONAME_PATH

for soname in "${!EXTERNAL_LIBS[@]}"; do
  src_path="${EXTERNAL_LIBS[$soname]}"

  # Compute hash of the source file (first 8 chars of SHA256)
  shorthash=$(sha256sum "$src_path" | cut -c1-8)

  # Hash-rename using the actual filename (e.g., libICE.so.6.3.0) rather
  # than the soname (libICE.so.6), matching auditwheel-r convention.
  src_name="$(basename "$src_path")"
  base="${src_name%%.*}"     # "libfoo"
  ext="${src_name#*.}"       # "so.1.2.3"
  new_soname="${base}-${shorthash}.${ext}"

  dest_path="${DEST_DIR}/${new_soname}"

  if [ ! -f "$dest_path" ]; then
    cp "$src_path" "$dest_path"
    chmod u+w "$dest_path"

    # Set the SONAME to the new hash-renamed name
    patchelf --set-soname "$new_soname" "$dest_path"

    # Set RPATH to $ORIGIN so grafted libs can find sibling grafted libs
    # (e.g., libreadline needs libtinfo in the same directory)
    patchelf --set-rpath '$ORIGIN' "$dest_path"

    echo "    $soname -> $new_soname"
  fi

  SONAME_MAP["$soname"]="$new_soname"
  SONAME_PATH["$soname"]="$dest_path"
done

# ── Phase 4: Fix inter-library references ────────────────────────────────────
# Grafted libraries may depend on each other. Update DT_NEEDED entries
# from old sonames to new hash-renamed sonames.

echo "  Fixing inter-library references..."
for soname in "${!SONAME_PATH[@]}"; do
  dest_path="${SONAME_PATH[$soname]}"
  replacements=()

  while IFS= read -r needed; do
    [ -z "$needed" ] && continue
    if [ -n "${SONAME_MAP[$needed]+x}" ]; then
      replacements+=("$needed" "${SONAME_MAP[$needed]}")
    fi
  done < <(patchelf --print-needed "$dest_path" 2>/dev/null)

  if [ ${#replacements[@]} -gt 0 ]; then
    # Process replacements in pairs
    for ((i=0; i<${#replacements[@]}; i+=2)); do
      old="${replacements[$i]}"
      new="${replacements[$((i+1))]}"
      patchelf --replace-needed "$old" "$new" "$dest_path"
    done
  fi
done

# ── Phase 5: Patch ELF binaries in the R installation ───────────────────────

echo "  Patching ELF binaries..."
for elf in "${!ELF_NEEDS[@]}"; do
  needs="${ELF_NEEDS[$elf]}"

  # Replace DT_NEEDED entries with hash-renamed sonames
  for soname in $needs; do
    new_soname="${SONAME_MAP[$soname]:-}"
    [ -z "$new_soname" ] && continue
    patchelf --replace-needed "$soname" "$new_soname" "$elf" 2>/dev/null || true
  done

  # Add RPATH to lib/R/lib/.libs/ relative to this binary's location
  elf_dir="$(dirname "$elf")"
  rel_path="$(relpath "$DEST_DIR" "$elf_dir")"
  new_rpath="\$ORIGIN/${rel_path}"

  # Preserve existing in-package RPATHs, add new one
  old_rpath=$(patchelf --print-rpath "$elf" 2>/dev/null || true)
  combined_rpath=""
  if [ -n "$old_rpath" ]; then
    # Keep only RPATH entries that point within the R installation
    IFS=: read -ra rpath_entries <<< "$old_rpath"
    for entry in "${rpath_entries[@]}"; do
      # Resolve $ORIGIN to check if it's within-package
      resolved_entry="${entry/\$ORIGIN/$(dirname "$elf")}"
      resolved_entry="$(cd "$resolved_entry" 2>/dev/null && pwd || true)"
      if [ -n "$resolved_entry" ] && [[ "$resolved_entry" == "${R_PATH}"/* ]]; then
        if [ -n "$combined_rpath" ]; then
          combined_rpath="${combined_rpath}:${entry}"
        else
          combined_rpath="$entry"
        fi
      fi
    done
  fi
  if [ -n "$combined_rpath" ]; then
    combined_rpath="${combined_rpath}:${new_rpath}"
  else
    combined_rpath="$new_rpath"
  fi

  # Deduplicate
  combined_rpath=$(echo "$combined_rpath" | tr ':' '\n' | awk '!seen[$0]++' | tr '\n' ':' | sed 's/:$//')

  patchelf --set-rpath "$combined_rpath" "$elf" 2>/dev/null || {
    # patchelf --set-rpath can fail on non-PIE executables (EXEC type).
    # This is expected for lib/R/bin/exec/R — it uses LD_LIBRARY_PATH instead.
    echo "    WARNING: cannot set RPATH on $elf (non-PIE binary?), skipping"
  }
done

# ── Phase 6: Verify repair ───────────────────────────────────────────────────
# Check that all grafted libs have $ORIGIN RPATH and can resolve their own
# DT_NEEDED entries. Catches regressions like missing sibling RPATHs.

echo "  Verifying repair..."
verify_ok=true

for soname in "${!SONAME_PATH[@]}"; do
  dest_path="${SONAME_PATH[$soname]}"
  new_soname="${SONAME_MAP[$soname]}"

  # Check RPATH contains $ORIGIN
  rpath=$(patchelf --print-rpath "$dest_path" 2>/dev/null || true)
  if [[ "$rpath" != *'$ORIGIN'* ]]; then
    echo "    FAIL: $new_soname missing \$ORIGIN in RPATH (got: '$rpath')" >&2
    verify_ok=false
  fi

  # Check SONAME was rewritten
  actual_soname=$(patchelf --print-soname "$dest_path" 2>/dev/null || true)
  if [ "$actual_soname" != "$new_soname" ]; then
    echo "    FAIL: $new_soname has wrong SONAME '$actual_soname'" >&2
    verify_ok=false
  fi

  # Check all DT_NEEDED entries resolve within lib/R/lib/.libs/ or the allowlist
  while IFS= read -r needed; do
    [ -z "$needed" ] && continue
    if is_allowed "$needed"; then
      continue
    fi
    # Should be a hash-renamed lib in the same directory
    if [ ! -f "${DEST_DIR}/${needed}" ]; then
      echo "    FAIL: $new_soname needs '$needed' but not found in $LIBS_SDIR/" >&2
      verify_ok=false
    fi
  done < <(patchelf --print-needed "$dest_path" 2>/dev/null)
done

# Verify patched ELF binaries can resolve all bundled deps via ldd
for elf in "${!ELF_NEEDS[@]}"; do
  while IFS= read -r line; do
    if echo "$line" | grep -q "not found"; then
      missing_lib=$(echo "$line" | sed 's/^\t\([^ ]*\).*/\1/')
      echo "    FAIL: $(basename "$elf") cannot resolve '$missing_lib'" >&2
      verify_ok=false
    fi
  done < <(LD_LIBRARY_PATH="${R_PATH}/lib/R/lib:${LD_LIBRARY_PATH:-}" ldd "$elf" 2>/dev/null || true)
done

if [ "$verify_ok" = true ]; then
  echo "  Verification passed."
else
  echo "  ERROR: Verification failed. See above." >&2
  exit 1
fi

echo "delocate-r: done. Bundled ${#EXTERNAL_LIBS[@]} libraries into $LIBS_SDIR/"
