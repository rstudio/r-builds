#!/bin/bash
set -e

export CRAN=${CRAN-"https://cran.rstudio.com"}
export S3_BUCKET_PREFIX=${S3_BUCKET_PREFIX-""}
export OS_IDENTIFIER=${OS_IDENTIFIER-"unknown"}
export TARBALL_NAME="R-${R_VERSION}-${OS_IDENTIFIER}.tar.gz"

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

# archive_r() - $1 as r version
archive_r() {
  tar czf /tmp/${TARBALL_NAME} --directory=/opt/R ${1} --owner=0 --group=0
}

fetch_r_source() {
  echo "Downloading R-${1}"
  if [ "${1}" = devel ]; then
    # Download the daily tarball of R devel
    wget -q https://stat.ethz.ch/R/daily/R-devel.tar.gz -O /tmp/R-devel.tar.gz
  else
    wget -q "${CRAN}/src/base/R-`echo ${1}| awk 'BEGIN {FS="."} {print $1}'`/R-${1}.tar.gz" -O /tmp/R-${1}.tar.gz
  fi
  echo "Extracting R-${1}"
  tar xf /tmp/R-${1}.tar.gz -C /tmp
  rm /tmp/R-${1}.tar.gz
}

# On CentOS 6, we need to clean up references to the static library and header paths.
clean_r() {
  if [[ -f /clean.sh ]]; then
    echo "Cleaning R build on CentOS 6"
    source /clean.sh
  fi
}

# compile_r() - $1 as r version
compile_r() {
  cd /tmp/R-${1}

  # tools/config.guess in R versions older than 3.2.2 guess 'unknown' instead of 'pc'
  # test the version and properly set the flag.
  build_flag='--build=x86_64-pc-linux-gnu'
  if _version_is_greater_than ${R_VERSION} 3.2.2; then
    build_flag=''
  fi

  # Avoid a PCRE2 dependency for R 3.5 and 3.6. R 3.x uses PCRE1, but R 3.5+
  # will link against PCRE2 if present, although it is not actually used.
  # Since there's no way to disable this in the configure script, and we need
  # PCRE2 for R 4.x, we hide PCRE2 from the configure script by temporarily
  # removing the pkg-config file and pcre2-config script.
  if [[ "${1}" =~ ^3 ]] && pkg-config --exists libpcre2-8; then
    mkdir -p /tmp/pcre2
    pc_dir=$(pkg-config --variable pcfiledir libpcre2-8)
    mv ${pc_dir}/libpcre2-8.pc /tmp/pcre2
    config_bin=$(which pcre2-config)
    mv ${config_bin} /tmp/pcre2
    trap "{ mv /tmp/pcre2/libpcre2-8.pc ${pc_dir}; mv /tmp/pcre2/pcre2-config ${config_bin}; }" EXIT
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
    --prefix=/opt/R/${1} \
    ${CONFIGURE_OPTIONS} \
    ${build_flag}
  make clean
  make
  make install

  # Add OS identifier to the default HTTP user agent.
  # Set this in the system Rprofile so it works when R is run with --vanilla.
  cat <<EOF >> /opt/R/${1}/lib/R/library/base/R/Rprofile
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
## If it exists this build is ready for packaging with fpm, so run the script
## else do nothing
package_r() {
  if [[ -f /package.sh ]]; then
    export R_VERSION=${1}
    source /package.sh
  fi
}

set_up_environment() {
  mkdir -p /opt/R
}

_version_is_greater_than() {
  test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

###### RUN R COMPILE PROCEDURE ######
set_up_environment
fetch_r_source $R_VERSION
compile_r $R_VERSION
clean_r
package_r $R_VERSION
archive_r $R_VERSION
upload_r $R_VERSION
