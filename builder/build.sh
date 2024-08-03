#!/bin/bash
set -e

export CRAN=${CRAN-"https://cran.rstudio.com"}
export S3_BUCKET_PREFIX=${S3_BUCKET_PREFIX-""}
export OS_IDENTIFIER=${OS_IDENTIFIER-"unknown"}
export TARBALL_NAME="R-${R_VERSION}-${OS_IDENTIFIER}.tar.gz"
export R_INSTALL_PATH=${R_INSTALL_PATH:-"/opt/R/${R_VERSION}"}

# Some Dockerfiles may copy a `/env.sh` to set up environment variables
# that require command substitution. If this file exists, source it.
if [[ -f /env.sh ]]; then
    echo "Sourcing environment variables"
    source /env.sh
fi

# upload_r()
upload_r() {
  baseName="r/${OS_IDENTIFIER}"
  if [ -n "$S3_BUCKET" ] && [ "$S3_BUCKET" != "" ]; then
    echo "Storing artifact on s3: ${S3_BUCKET}, tarball: ${TARBALL_NAME}"
    aws s3 cp /tmp/${TARBALL_NAME} s3://${S3_BUCKET}/${S3_BUCKET_PREFIX}${baseName}/${TARBALL_NAME}
    # check if PKG_FILE has been set by a packager script and act accordingly
    if [ -n "$PKG_FILE" ] && [ "$PKG_FILE" != "" ]; then
      if [ -f "$PKG_FILE" ]; then
	aws s3 cp ${PKG_FILE} s3://${S3_BUCKET}/${S3_BUCKET_PREFIX}${baseName}/pkgs/$(basename ${PKG_FILE})
      fi
    fi
  fi
  if [ -n "$LOCAL_STORE" ] && [ "$LOCAL_STORE" != '' ]; then
    echo "Storing artifact locally: ${LOCAL_STORE}, tarball: ${TARBALL_NAME}"
    mkdir -p ${LOCAL_STORE}/${baseName}
    cp /tmp/${TARBALL_NAME} ${LOCAL_STORE}/${baseName}/${TARBALL_NAME}
  fi
}

# archive_r()
archive_r() {
  dir=$(dirname "$R_INSTALL_PATH")
  base=$(basename "$R_INSTALL_PATH")
  tar czf "/tmp/${TARBALL_NAME}" --directory="$dir" "$base" --owner=0 --group=0
}

fetch_r_source() {
  echo "Downloading R-${1}"
  if [ -n "${R_TARBALL_URL}" ]; then
    # Custom tarball URL for testing (e.g., R alpha and beta releases)
    wget -q "${R_TARBALL_URL}" -O /tmp/R-${1}.tar.gz
  elif [ "${1}" = devel ]; then
    # Download the daily tarball of R devel
    wget -q https://cran.r-project.org/src/base-prerelease/R-devel.tar.gz -O /tmp/R-devel.tar.gz
  elif [ "${1}" = "next" ]; then
    wget -q https://cran.r-project.org/src/base-prerelease/R-latest.tar.gz -O /tmp/R-next.tar.gz
  else
    wget -q "${CRAN}/src/base/R-`echo ${1}| awk 'BEGIN {FS="."} {print $1}'`/R-${1}.tar.gz" -O /tmp/R-${1}.tar.gz
  fi
  echo "Extracting R-${1}"
  tar xf /tmp/R-${1}.tar.gz -C /tmp
  # 'next' may contain R-patched/, R-alpha/, etc. make it R-next/
  if [ "${1}" = "next" ]; then
      dirname=`tar tzvf /tmp/R-next.tar.gz | head -1 | awk '{ print $NF }' | cut -d/ -f1`
      mv /tmp/${dirname} /tmp/R-next
  fi
  rm /tmp/R-${1}.tar.gz
}

# Apply a patch for this R version if present. Typically for R-devel.
patch_r() {
  cd /tmp/R-${1}

  if [ -f "/patches/R-${1}.patch" ]; then
      patch -p1 < "/patches/R-${1}.patch"
  fi

  if [ -f "/patches/R-${1}-${OS_IDENTIFIER}.patch" ]; then
      patch -p1 < "/patches/R-${1}-${OS_IDENTIFIER}.patch"
  fi

  if [ -f "/patches/R-${1}-`arch`.patch" ]; then
      patch -p1 < "/patches/R-${1}-`arch`.patch"
  fi
}

# compile_r() - $1 as r version
compile_r() {
  r_version=${1}
  cd "/tmp/R-${r_version}"

  # tools/config.guess in R versions older than 3.2.2 guess 'unknown' instead of 'pc'
  # test the version and properly set the flag.
  build_flag="--build=$(uname -m)-pc-linux-gnu"
  if _version_is_greater_than "${r_version}" 3.2.2; then
    build_flag=''
  fi

  # R 3.6.1 and below require additional compiler flags for GCC 10 and above
  # (e.g., on Debian 11). Add -fcommon to CFLAGS to work around issues with new
  # default of -fno-common for C (fixed in R 3.6.2). Add -fallow-argument-mismatch
  # to FFLAGS to work around issues with changes to argument mismatch checking
  # in Fortran (fixed in R 3.6.2, but not mentioned in NEWS).
  # https://cran.r-project.org/doc/manuals/r-release/NEWS.3.html
  # https://cran.r-project.org/doc/manuals/r-release/R-admin.html#Using-Fortran
  # https://gcc.gnu.org/gcc-10/porting_to.html
  gcc_major_version=$(gcc -dumpversion | cut -d '.' -f 1)
  if _version_is_less_than "${r_version}" 3.6.2 && _version_is_greater_than "${gcc_major_version}" 9; then
    # Default CFLAGS/FFLAGS for all R 3.x versions is '-g -O2' when using GCC
    export CFLAGS='-g -O2 -fcommon'
    export FFLAGS='-g -O2 -fallow-argument-mismatch'
    echo "Setting CFLAGS: ${CFLAGS}"
    echo "Setting FFLAGS: ${FFLAGS}"
  fi

  # Avoid a PCRE2 dependency for R 3.5 and 3.6. R 3.x uses PCRE1, but R 3.5+
  # will link against PCRE2 if present, although it is not actually used.
  # Since there's no way to disable this in the configure script, and we need
  # PCRE2 for R 4.x, we hide PCRE2 from the configure script by temporarily
  # removing the pkg-config file and pcre2-config script.
  #
  # The INCLUDE_PCRE2_IN_R_3 environment variable can be set to include PCRE2
  # in R 3.x builds, for distributions where PCRE2 is always required.
  # In Debian 11/Ubuntu 22/RHEL 9/SUSE 15.6, Pango now depends on PCRE2, so R 3.x will not be compiled with
  # Pango support if the PCRE2 pkg-config file is missing.
  if [[ "${r_version}" =~ ^3 ]] && pkg-config --exists libpcre2-8 && [ -z "$INCLUDE_PCRE2_IN_R_3" ]; then
    mkdir -p /tmp/pcre2
    pc_dir=$(pkg-config --variable pcfiledir libpcre2-8)
    mv ${pc_dir}/libpcre2-8.pc /tmp/pcre2
    config_bin=$(which pcre2-config)
    mv ${config_bin} /tmp/pcre2
    trap "{ mv /tmp/pcre2/libpcre2-8.pc ${pc_dir}; mv /tmp/pcre2/pcre2-config ${config_bin}; }" EXIT
  fi

  # Allow libcurl 8.x to be used in R 4.2 and below. Despite a change in major
  # version number, libcurl 8 changes neither API nor ABI. This applies the same
  # change to configure made in R 4.3.0, replacing exit(1) with exit(0) when
  # LIBCURL_VERSION_MAJOR > 7.
  # https://github.com/wch/r-source/commit/da6638896413bcbb5970b2335b92582853f94e3c
  if _version_is_less_than "${r_version}" 4.3.0; then
    sed -i -z 's/#if LIBCURL_VERSION_MAJOR > 7\n  exit(1)/#if LIBCURL_VERSION_MAJOR > 7\n  exit(0)/' configure
  fi

  # Default configure options. Some Dockerfiles override this with an ENV directive.
  default_configure_options="\
    --enable-R-shlib \
    --with-tcltk \
    --enable-memory-profiling \
    --with-x \
    --with-blas \
    --with-lapack"

  CONFIGURE_OPTIONS=${CONFIGURE_OPTIONS:-$default_configure_options}

  # For RHEL 9, link to external FlexiBLAS starting from R 4.3.0 to align with EPEL 9
  if _version_is_greater_than "${R_VERSION}" 4.2.10; then
    if [[ "${OS_IDENTIFIER}" = "rhel-9" ]]; then
      CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS \
        --with-blas=flexiblas --with-lapack=flexiblas"
    fi
  fi

  echo "Using CONFIGURE_OPTIONS: ${CONFIGURE_OPTIONS}"

  # set some common environment variables for the configure step
  AWK=/usr/bin/awk \
  LIBnn=lib \
  PERL=/usr/bin/perl \
  R_PDFVIEWER=xdg-open \
  R_BROWSER=xdg-open \
  R_PAPERSIZE=letter \
  R_PRINTCMD=/usr/bin/lpr \
  R_UNZIPCMD=/usr/bin/unzip \
  R_ZIPCMD=/usr/bin/zip \
  ./configure \
    --prefix="${R_INSTALL_PATH}" \
    ${CONFIGURE_OPTIONS} \
    ${build_flag}
  make clean
  make
  make install

  # Add OS identifier to the default HTTP user agent.
  # Set this in the system Rprofile so it works when R is run with --vanilla.
  cat <<EOF >> "${R_INSTALL_PATH}"/lib/R/library/base/R/Rprofile
## Set the default HTTP user agent
local({
  os_identifier <- if (file.exists("/etc/os-release")) {
    os <- readLines("/etc/os-release")
    id <- gsub('^ID=|"', "", grep("^ID=", os, value = TRUE))
    version <- gsub('^VERSION_ID=|"', "", grep("^VERSION_ID=", os, value = TRUE))
    sprintf("%s-%s", id, version)
  } else {
    "${OS_IDENTIFIER}"
  }
  options(HTTPUserAgent = sprintf("R/%s (%s) R (%s)", getRversion(), os_identifier,
    paste(getRversion(), R.version\$platform, R.version\$arch, R.version\$os)))
})
EOF
}

# check for packager script
## If it exists this build is ready for packaging with nFPM, so run the script
## else do nothing
package_r() {
  if [[ -f /package.sh ]]; then
    export R_VERSION=${1}
    source /package.sh
  fi
}

set_up_environment() {
  mkdir -p "$R_INSTALL_PATH"
}

_version_is_greater_than() {
  test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

_version_is_less_than() {
  test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$2"
}

###### RUN R COMPILE PROCEDURE ######
set_up_environment
fetch_r_source $R_VERSION
patch_r $R_VERSION
compile_r $R_VERSION
package_r $R_VERSION
archive_r
upload_r $R_VERSION
