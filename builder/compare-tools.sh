#!/usr/bin/env bash
set -e

# compare-tools.sh — Run both delocate-r.py and auditwheel-r-repair.py on
# identical copies of a freshly-built R installation and compare the results.
#
# This script must be run inside the manylinux-2-28 Docker container after
# R has been compiled (by build.sh's compile_r) but before packaging. It's
# called as: source /build.sh --compare
#
# Normal usage (stand-alone):
#   R_VERSION=4.4.2 docker compose run --rm --entrypoint bash manylinux-2-28 -c '
#     source /build.sh
#     set_up_environment; fetch_r_source $R_VERSION; patch_r $R_VERSION; compile_r $R_VERSION
#     /compare-tools.sh
#   '

R_VERSION="${R_VERSION:-4.4.2}"
R_INSTALL_PATH="${R_INSTALL_PATH:-/opt/R/${R_VERSION}}"

echo "=== Using R at ${R_INSTALL_PATH} ==="
R_LIB_DIR="${R_INSTALL_PATH}/lib/R/lib"

# Make two copies — one for each tool
cp -a ${R_INSTALL_PATH} /tmp/R-delocate
cp -a ${R_INSTALL_PATH} /tmp/R-auditwheel

# Swap BLAS in both copies (same as package.sh phase 1)
for dir in /tmp/R-delocate /tmp/R-auditwheel; do
  rm -f "${dir}/lib/R/lib/libRblas.so"
  cp /usr/lib64/libopenblasp.so.0 "${dir}/lib/R/lib/libRblas.so"
done

# Make two copies
cp -a ${R_INSTALL_PATH} /tmp/R-delocate
cp -a ${R_INSTALL_PATH} /tmp/R-auditwheel

echo ""
echo "============================================"
echo "=== Tool 1: delocate-r.py ==="
echo "============================================"
export LD_LIBRARY_PATH="/tmp/R-delocate/lib/R/lib"
python3 /delocate-r.py /tmp/R-delocate

echo ""
echo "============================================"
echo "=== Tool 2: auditwheel-r-repair.py ==="
echo "============================================"
export LD_LIBRARY_PATH="/tmp/R-auditwheel/lib/R/lib"
cd /tmp
python3.12 /auditwheel-r-repair.py /tmp/R-auditwheel

echo ""
echo "============================================"
echo "=== Comparison ==="
echo "============================================"

DL_DIR=$(find /tmp/R-delocate -name ".libs" -type d | head -1)
AW_DIR=$(find /tmp/wheelhouse -name ".libs" -type d | head -1)

echo "delocate-r:   ${DL_DIR} — $(ls "${DL_DIR}" | wc -l) libs"
echo "auditwheel-r: ${AW_DIR} — $(ls "${AW_DIR}" | wc -l) libs"

# Normalize: strip hashes and version suffixes beyond SONAME
# e.g., "libICE-7cb805b5.so.6.3.0" -> "libICE.so.6"
#        "libICE-7cb805b5.so.6"     -> "libICE.so.6"
normalize() {
  # Strip hash: libfoo-HASH.so.X... -> libfoo.so.X...
  # Then strip version beyond SONAME: libfoo.so.X.Y.Z -> libfoo.so.X
  sed 's/-[0-9a-f]\{6,8\}\./\./' | sed 's/\(\.so\.[0-9]\+\)\(\.[0-9.]*\)$/\1/'
}

ls "${DL_DIR}" | normalize | sort -u > /tmp/dl.txt
ls "${AW_DIR}" | normalize | sort -u > /tmp/aw.txt

echo ""
echo "Only in delocate-r.py:"
comm -23 /tmp/dl.txt /tmp/aw.txt || true
echo ""
echo "Only in auditwheel-r:"
comm -13 /tmp/dl.txt /tmp/aw.txt || true
echo ""
COMMON=$(comm -12 /tmp/dl.txt /tmp/aw.txt | wc -l)
echo "In both: ${COMMON} libs"

# Check if same hashes (identical source file content)
echo ""
echo "=== Hash comparison (same file content?) ==="
# Extract just the hash from each filename: libfoo-HASH.so.X -> HASH
extract_hash() {
  sed -n 's/.*-\([0-9a-f]\{6,8\}\)\.so.*/\1/p'
}
ls "${DL_DIR}" | sort > /tmp/dl-full.txt
ls "${AW_DIR}" | sort > /tmp/aw-full.txt

# Build a map: normalized_name -> hash for each tool
MATCH=0
DIFF=0
ONLY_DL=0
while IFS= read -r dl_name; do
  dl_base=$(echo "$dl_name" | normalize)
  dl_hash=$(echo "$dl_name" | extract_hash)
  # Find matching lib in auditwheel output
  aw_name=$(ls "${AW_DIR}" | normalize | grep -Fn "$dl_base" /tmp/aw-full.txt 2>/dev/null | head -1 || true)
  # Use normalized names to find match
  aw_match=$(grep "^${dl_base}$" /tmp/aw.txt || true)
  if [ -n "$aw_match" ]; then
    # Find the auditwheel file with same normalized name
    aw_file=$(ls "${AW_DIR}" | while read -r f; do
      if [ "$(echo "$f" | normalize)" = "$dl_base" ]; then
        echo "$f"
        break
      fi
    done)
    aw_hash=$(echo "$aw_file" | extract_hash)
    if [ "$dl_hash" = "$aw_hash" ]; then
      MATCH=$((MATCH + 1))
    else
      DIFF=$((DIFF + 1))
      echo "  DIFF hash: $dl_name vs $aw_file"
    fi
  fi
done < /tmp/dl-full.txt
echo "Same hash (identical source): ${MATCH}"
echo "Different hash: ${DIFF}"
