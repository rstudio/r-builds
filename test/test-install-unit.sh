#!/usr/bin/env bash
# Unit tests for the quick install script (install.sh).
#
# These source install.sh to load its functions and exercise the pure
# detection / name / URL-building logic. No network calls or installs happen,
# so the tests run anywhere (including CI runners without an arm64 host). The
# end-to-end install path is covered separately by test/test-apt.sh,
# test/test-yum.sh, and test/test-zypper.sh under Docker.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sourcing install.sh loads its functions without running main() (see the guard
# at the bottom of install.sh). Run from a temporary directory so download_url's
# "installer already present" short-circuit never triggers on a stray file.
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT
cd "${TMPDIR_TEST}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../install.sh"

# A fixed version list so valid_version / get_version don't depend on the CDN.
# Mirrors load_r_versions output: newest numeric first, devel/next at the end.
R_VERSIONS=$'4.6.1\n4.6.0\n4.5.3\ndevel\nnext'

fail=0
pass=0

# assert_eq <description> <expected> <actual>
assert_eq () {
  local desc=$1 expected=$2 actual=$3
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: ${desc}"
    echo "        expected: [${expected}]"
    echo "        actual:   [${actual}]"
  fi
}

# assert_arch_unsupported <description> <os> <version> <arch>
# download_name must exit non-zero and print nothing for architectures we
# don't publish packages for.
assert_arch_unsupported () {
  local desc=$1 os=$2 version=$3 arch=$4 out rc
  out=$(download_name "${os}" "${version}" "${arch}")
  rc=$?
  if [[ "${rc}" -ne 0 && -z "${out}" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: ${desc}"
    echo "        expected: non-zero exit and empty output"
    echo "        actual:   rc=${rc} out=[${out}]"
  fi
}

# assert_do_install_error <description> <os> <arch> <expected message substring>
# Drives do_install with its side-effectful steps stubbed so only the arch/OS
# guards run, and checks it exits 1 with the expected message. The stubs live in
# the command-substitution subshell, so they don't leak into other tests.
assert_do_install_error () {
  local desc=$1 fake_os=$2 fake_arch=$3 want=$4 out rc
  out=$(
    check_commands () { :; }
    detect_os () { echo "${fake_os}"; }
    detect_os_version () { echo "9"; }
    prompt_version () { :; }
    uname () { echo "${fake_arch}"; }
    SELECTED_VERSION=4.6.1
    do_install 2>&1
  )
  rc=$?
  if [[ "${rc}" -eq 1 && "${out}" == *"${want}"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: ${desc}"
    echo "        expected: exit 1 with substring [${want}]"
    echo "        actual:   rc=${rc} out=[${out}]"
  fi
}

echo "== sourcing guard: main() does not run when sourced =="
# main() is the only place that sets SCRIPT_ACTION. If the source guard in
# install.sh regressed, sourcing would run the installer (network fetch, prompt,
# or a real package install) instead of just loading functions.
assert_eq "SCRIPT_ACTION unset after sourcing" "" "${SCRIPT_ACTION:-}"

echo "== detect_installer_type =="
assert_eq "ubuntu -> deb"   "deb" "$(detect_installer_type Ubuntu)"
assert_eq "debian -> deb"   "deb" "$(detect_installer_type Debian)"
assert_eq "redhat -> rpm"   "rpm" "$(detect_installer_type RedHat)"
assert_eq "fedora -> rpm"   "rpm" "$(detect_installer_type Fedora)"
assert_eq "centos -> rpm"   "rpm" "$(detect_installer_type CentOS)"
assert_eq "alma -> rpm"     "rpm" "$(detect_installer_type Alma)"
assert_eq "rocky -> rpm"    "rpm" "$(detect_installer_type Rocky)"
assert_eq "oracle -> rpm"   "rpm" "$(detect_installer_type Oracle)"
assert_eq "amazon -> rpm"   "rpm" "$(detect_installer_type Amazon)"
assert_eq "sles12 -> rpm"   "rpm" "$(detect_installer_type SLES12)"
assert_eq "sles1x -> rpm"   "rpm" "$(detect_installer_type SLES1X)"
assert_eq "leap12 -> rpm"   "rpm" "$(detect_installer_type LEAP12)"
assert_eq "leap1x -> rpm"   "rpm" "$(detect_installer_type LEAP1X)"

echo "== download_name: deb (Ubuntu/Debian) =="
assert_eq "ubuntu aarch64 -> arm64 deb" "r-4.6.1_1_arm64.deb" "$(download_name Ubuntu 4.6.1 aarch64)"
assert_eq "ubuntu arm64   -> arm64 deb" "r-4.6.1_1_arm64.deb" "$(download_name Ubuntu 4.6.1 arm64)"
assert_eq "ubuntu x86_64  -> amd64 deb" "r-4.6.1_1_amd64.deb" "$(download_name Ubuntu 4.6.1 x86_64)"
assert_eq "ubuntu amd64   -> amd64 deb" "r-4.6.1_1_amd64.deb" "$(download_name Ubuntu 4.6.1 amd64)"
assert_eq "debian aarch64 -> arm64 deb" "r-4.6.1_1_arm64.deb" "$(download_name Debian 4.6.1 aarch64)"
assert_eq "debian arm64   -> arm64 deb" "r-4.6.1_1_arm64.deb" "$(download_name Debian 4.6.1 arm64)"

echo "== download_name: rpm (RedHat family / SUSE) =="
assert_eq "redhat aarch64 -> aarch64 rpm" "R-4.6.1-1-1.aarch64.rpm" "$(download_name RedHat 4.6.1 aarch64)"
assert_eq "redhat arm64   -> aarch64 rpm" "R-4.6.1-1-1.aarch64.rpm" "$(download_name RedHat 4.6.1 arm64)"
assert_eq "redhat x86_64  -> x86_64 rpm"  "R-4.6.1-1-1.x86_64.rpm"  "$(download_name RedHat 4.6.1 x86_64)"
assert_eq "rocky aarch64  -> aarch64 rpm" "R-4.6.1-1-1.aarch64.rpm" "$(download_name Rocky 4.6.1 aarch64)"
assert_eq "fedora arm64   -> aarch64 rpm" "R-4.6.1-1-1.aarch64.rpm" "$(download_name Fedora 4.6.1 arm64)"
assert_eq "oracle aarch64 -> aarch64 rpm" "R-4.6.1-1-1.aarch64.rpm" "$(download_name Oracle 4.6.1 aarch64)"
assert_eq "sles1x aarch64 -> aarch64 rpm" "R-4.6.1-1-1.aarch64.rpm" "$(download_name SLES1X 4.6.1 aarch64)"
assert_eq "sles12 x86_64  -> x86_64 rpm"  "R-4.6.1-1-1.x86_64.rpm"  "$(download_name SLES12 4.6.1 x86_64)"

echo "== download_name: unsupported architectures fail cleanly =="
assert_arch_unsupported "ubuntu i386"    Ubuntu 4.6.1 i386
assert_arch_unsupported "ubuntu riscv64" Ubuntu 4.6.1 riscv64
assert_arch_unsupported "redhat ppc64le" RedHat 4.6.1 ppc64le
assert_arch_unsupported "ubuntu empty"   Ubuntu 4.6.1 ""

echo "== do_install: fail-fast messages =="
assert_do_install_error "unsupported arch -> arch message" RedHat ppc64le \
  "Unsupported architecture 'ppc64le'"
# A distro detect_os can name but download_name has no case for (e.g. an Ubuntu
# derivative) is an unsupported OS, not an unsupported arch.
assert_do_install_error "unsupported os -> os message" LinuxMint x86_64 \
  "No R package is available for LinuxMint"

echo "== download_url =="
assert_eq "ubuntu 2404 arm64" \
  "https://cdn.posit.co/r/ubuntu-2404/pkgs/r-4.6.1_1_arm64.deb" \
  "$(download_url Ubuntu r-4.6.1_1_arm64.deb 2404)"
assert_eq "ubuntu 2404 amd64" \
  "https://cdn.posit.co/r/ubuntu-2404/pkgs/r-4.6.1_1_amd64.deb" \
  "$(download_url Ubuntu r-4.6.1_1_amd64.deb 2404)"
assert_eq "debian 13 arm64" \
  "https://cdn.posit.co/r/debian-13/pkgs/r-4.6.1_1_arm64.deb" \
  "$(download_url Debian r-4.6.1_1_arm64.deb 13)"
assert_eq "rhel 9 aarch64" \
  "https://cdn.posit.co/r/rhel-9/pkgs/R-4.6.1-1-1.aarch64.rpm" \
  "$(download_url RedHat R-4.6.1-1-1.aarch64.rpm 9)"
assert_eq "rhel 10 aarch64" \
  "https://cdn.posit.co/r/rhel-10/pkgs/R-4.6.1-1-1.aarch64.rpm" \
  "$(download_url RedHat R-4.6.1-1-1.aarch64.rpm 10)"
assert_eq "el 8 -> centos-8" \
  "https://cdn.posit.co/r/centos-8/pkgs/R-4.6.1-1-1.aarch64.rpm" \
  "$(download_url RedHat R-4.6.1-1-1.aarch64.rpm 8)"
assert_eq "rocky 9 aarch64" \
  "https://cdn.posit.co/r/rhel-9/pkgs/R-4.6.1-1-1.aarch64.rpm" \
  "$(download_url Rocky R-4.6.1-1-1.aarch64.rpm 9)"
assert_eq "fedora 42 aarch64" \
  "https://cdn.posit.co/r/fedora-42/pkgs/R-4.6.1-1-1.aarch64.rpm" \
  "$(download_url Fedora R-4.6.1-1-1.aarch64.rpm 42)"
assert_eq "opensuse 156 aarch64" \
  "https://cdn.posit.co/r/opensuse-156/pkgs/R-4.6.1-1-1.aarch64.rpm" \
  "$(download_url SLES1X R-4.6.1-1-1.aarch64.rpm 156)"
assert_eq "opensuse 160 aarch64" \
  "https://cdn.posit.co/r/opensuse-160/pkgs/R-4.6.1-1-1.aarch64.rpm" \
  "$(download_url SLES1X R-4.6.1-1-1.aarch64.rpm 160)"

echo "== download_url: local file short-circuits download =="
touch r-4.6.1_1_arm64.deb
assert_eq "existing installer -> empty url" "" "$(download_url Ubuntu r-4.6.1_1_arm64.deb 2404)"
rm -f r-4.6.1_1_arm64.deb

echo "== valid_version / get_version =="
assert_eq "valid_version present"    "4.6.1" "$(valid_version 4.6.1)"
assert_eq "valid_version absent"     ""      "$(valid_version 9.9.9)"
assert_eq "get_version latest"       "4.6.1" "$(get_version latest)"
assert_eq "get_version exact"        "4.5.3" "$(get_version 4.5.3)"
assert_eq "get_version unknown"      ""      "$(get_version 1.0.0)"

echo
echo "install.sh unit tests: ${pass} passed, ${fail} failed"
if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
