#!/bin/bash
THIS_VERSION="1.1.0"

# Call with:
#   bash -c "$(curl -L https://rstd.io/r-install)"

SCRIPT_ACTION=$1
SCRIPT_ACTION=${SCRIPT_ACTION:-install}

# Set to the full version to install. Must be either available on S3 or in the working directory
R_VERSION=${R_VERSION:-}
# The version may optionally be provided as a second argument
if [[ "$2" != "" ]]; then
  R_VERSION=$2
fi

# Run unattended; show no questions, assume default answers.
# May also be set by the '-y'/'yes' options on the install action.
RUN_UNATTENDED=${RUN_UNATTENDED:-0}
if [[ "$3" == "-y" || "$3" == "yes" ]]; then
  RUN_UNATTENDED=1
fi

SUDO=
if [[ $(id -u) != "0" ]]; then
  SUDO=sudo
fi

# The root of the S3 URL for downloads
CDN_URL='https://cdn.rstudio.com/r'

# The URL for listing available R versions
VERSIONS_URL="${CDN_URL}/versions.json"

R_VERSIONS=$(curl -s ${VERSIONS_URL} | \
  # Matches the JSON line that contains the r versions
  grep r_versions | \
  # Gets the value of the `r_version` property (e.g., "[ 3.0.0, 3.0.3, ... ]")
  cut -f2 -d ":" | \
  # Removes the opening and closing brackets of the array
  cut -f2 -d "[" | cut -f1 -d "]" | \
  # Removes the quotes and commas from the values
  sed -e 's/\"//g' | sed -e 's/\,//g' | \
  # Appends a placeholder to the end of the string. Without an extra element at the
  # end, the last version will be missing after we reverse the order.
  { IFS= read -r vers; printf '%s placeholder' "$vers"; } | \
  # Reverses the order of the list
  ( while read -d ' ' f;do g="$f${g+ }$g" ;done;echo "$g" ))

# Returns the OS
detect_os () {
  OS='cat /etc/*-release'
  distro=$($OS | grep DISTRIB_ID | cut -f2 -d "=")
  if test -f /etc/SuSE-release
  then
   distro="LEAP12"
  fi
  if [[ -f /etc/centos-release || -f /etc/redhat-release ]]
  then
   distro="RedHat"
  fi
  if [[ $(cat /etc/os-release | grep -e "^CPE_NAME\=*" | cut -f 2 -d '=') =~ cpe:/o:suse:sles:12 ]]
  then
    distro="SLES12"
  fi
  if [[ $(cat /etc/os-release | grep -e "^CPE_NAME\=*" | cut -f 2 -d '=') =~ cpe:/o:opensuse:leap:42 ]]
  then
    distro="LEAP12"
  fi
  if [[ $(cat /etc/os-release | grep -e "^CPE_NAME\=*" | cut -f 2 -d '=') =~ cpe:/o:opensuse:leap:15 ]]
  then
   distro="SLES15"
  fi
  if [[ $(cat /etc/os-release | grep -e "^CPE_NAME\=*" | cut -f 2 -d '=') =~ cpe:/o:suse:sles:15 ]]
  then
   distro="LEAP15"
  fi
  if [[ $(cat /etc/os-release | grep -e "^CPE_NAME\=*" | cut -f 2 -d '=') =~ cpe:2.3:o:amazon:amazon_linux:2 ]]
  then
   distro="Amazon"
  fi
  if [[ $(cat /etc/os-release | grep -e "^CPE_NAME\=*" | cut -f 2 -d '=') =~ cpe:/o:almalinux:almalinux: ]]
  then
   distro="Alma"
  fi
  if [[ $(cat /etc/os-release | grep -e "^CPE_NAME\=*" | cut -f 2 -d '=') =~ cpe:/o:rocky:rocky: ]]
  then
   distro="Rocky"
  fi
  if [[ $(cat /etc/os-release | grep -e "^ID\=*" | cut -f 2 -d '=') == "debian" ]]; then
    distro="Debian"
  fi
  
  echo "${distro}"
}

# Returns the OS version
detect_os_version () {
  os=$1
  if [[ "${os}" =~ ^(RedHat|Alma|Rocky)$ ]]; then
    # Get the major version. /etc/redhat-release is used if /etc/os-release isn't available,
    # e.g., on CentOS/RHEL 6.
    if [[ -f /etc/os-release ]]; then
      cat /etc/os-release | grep VERSION_ID= | sed -E 's/VERSION_ID="([0-9.]*)"/\1/' | cut -d '.' -f 1
    elif [[ -f /etc/redhat-release ]]; then
      cat /etc/redhat-release | sed -E 's/[^0-9]+([0-9.]+)[^0-9]*/\1/' | cut -d '.' -f 1
    fi
  fi
  if [[ "${os}" == "Ubuntu" ]] || [[ "${os}" == "Debian" ]]; then
    cat /etc/os-release | grep -e "^VERSION_ID\=*" | cut -f 2 -d '=' | sed -e 's/[".]//g'
  fi
  if [[ "${os}" == "SLES15" ]] || [[ "${os}" == "LEAP15" ]]; then
    cat /etc/os-release | grep -e "^VERSION_ID\=*" | cut -f 2 -d '=' | sed -e 's/[".]//g'
  fi
  # reuse rhel7 binaries for amazon
  if [[ "${os}" == "Amazon" ]]; then
    echo "7"
  fi
}

# Returns the installer type
detect_installer_type () {
  os=$1
  case $os in
    "RedHat" | "CentOS" | "LEAP12" | "LEAP15" | "SLES12" | "SLES15" | "Amazon" | "Alma" | "Rocky")
      echo "rpm"
      ;;
    "Ubuntu" | "Debian")
      echo "deb"
      ;;
  esac
}

# Lists available R versions
show_versions () {
  for v in ${R_VERSIONS}
  do
    echo "  ${v}"
  done
}

# Same as above but for automation purposes
do_show_versions () {
  for v in ${R_VERSIONS}
  do
    echo "${v}"
  done
}

# Returns the installer name for a given version and OS
download_name () {
  os=$1
  version=$2
  case $os in
    "RedHat" | "CentOS" | "Amazon" | "Alma" | "Rocky")
      echo "R-${version}-1-1.x86_64.rpm"
      ;;
    "Ubuntu" | "Debian")
      echo "r-${version}_1_amd64.deb"
      ;;
    "LEAP12" | "LEAP15" | "SLES12" | "SLES15")
      echo "R-${version}-1-1.x86_64.rpm"
      ;;
  esac
}

# Returns a download URL for a given version and OS
download_url () {
  os=$1
  name=$2
  ver=$3

  # If the current directory already contains the download, then
  # there's no need to download it
  if [ -f ${name} ]; then
    echo ""
  else

    case $os in
      "RedHat" | "CentOS" | "Amazon" | "Alma" | "Rocky")
        if [ "${ver}" -ge 9 ]; then
          echo "${CDN_URL}/rhel-${ver}/pkgs/${name}"
        else
          echo "${CDN_URL}/centos-${ver}/pkgs/${name}"
        fi
        ;;
      "Ubuntu")
        echo "${CDN_URL}/ubuntu-${ver}/pkgs/${name}"
        ;;
      "Debian")
        echo "${CDN_URL}/debian-${ver:-9}/pkgs/${name}"
        ;;
      "LEAP12" | "SLES12")
        echo "${CDN_URL}/opensuse-42/pkgs/${name}"
        ;;
      "LEAP15" | "SLES15")
        if [ "${ver}" -ge 154 ]; then
          echo "${CDN_URL}/opensuse-154/pkgs/${name}"
        elif [ "${ver}" -ge 153 ]; then
          echo "${CDN_URL}/opensuse-153/pkgs/${name}"
        elif [ "${ver}" -eq 152 ]; then
          echo "${CDN_URL}/opensuse-152/pkgs/${name}"
        else
          echo "${CDN_URL}/opensuse-15/pkgs/${name}"
        fi
        ;;
    esac
  fi
}

# Given a version or "latest", returns a version to download. If no
# valid input version is given, returns blank ("").
get_version () {
  versions=(${R_VERSIONS})
  version_input=$1
  if [ "${version_input}" = "latest" ]; then
    version_input=${versions[0]}
  fi
  # Convert short version to real version
  echo $(valid_version $version_input)
}

# Checks to see if a version is valid
valid_version () {
  ver=$1
  result=
  for v in ${R_VERSIONS}
  do
    if [[ "${v}" = "${ver}" ]]; then
      result=${v}
    fi
  done
  echo ${result}
}

# Prompts for the version until a valid version is entered.
SELECTED_VERSION=${R_VERSION}
prompt_version () {
  while [ "$SELECTED_VERSION" = "" ]; do
    echo "Available Versions"
    show_versions
    echo "Enter version to install: (<ENTER> for latest)"
    read version_input
    if [ "$version_input" = "" ]; then
      version_input="latest"
    fi
    SELECTED_VERSION=$(get_version "${version_input}")
  done
}

# Installs R
install () {
  installer_type=$1
  installer_name=$2
  os=$3
  ver=$4
  if [ "$installer_type" = "deb" ]; then
    install_deb ${installer_name}
  else
    install_rpm ${installer_name} ${os} ${ver}
  fi
}

# Installs R for Ubuntu/Debian
install_deb () {
  installer_name=$1
  echo "Install from DEB installer ${installer_name}..."

  if ! has_sudo "apt-get"; then
    echo "Must have sudo privileges to run apt-get"
    exit 1
  fi
  yes=
  yesapt=
  if [[ "${RUN_UNATTENDED}" -ne "0" ]]; then
      yes="--n"
      yesapt="-y"
      export DEBIAN_FRONTEND=noninteractive
  fi
  echo "Updating package indexes..."
  ${SUDO} apt-get update
  echo "Installing ${installer_name}..."
  ${SUDO} apt-get install ${yesapt} gdebi-core
  ${SUDO} gdebi ${yes} "${installer_name}"
}

# Installs R for RHEL/CentOS and SUSE
install_rpm () {
  installer_name=$1
  os=$2
  ver=$3
  echo "User install from RPM installer ${installer_name}..."
  install_pre "${os}" "${ver}"
  yes=
  if [[ "${RUN_UNATTENDED}" -ne "0" ]]; then
      yes="-y"
  fi
  case $os in
    "RedHat" | "CentOS" | "Amazon" | "Alma" | "Rocky")
      if ! has_sudo "yum"; then
        echo "Must have sudo privileges to run yum"
        exit 1
      fi
      echo "Updating package indexes..."
      ${SUDO} yum check-update -y
      echo "Installing ${installer_name}..."
      ${SUDO} yum install ${yes} "${installer_name}"
      ;;
    "LEAP12" | "LEAP15" | "SLES12" | "SLES15")
      if ! has_sudo "zypper"; then
        echo "Must have sudo privileges to run zypper"
        exit 1
      fi
      echo "Updating package indexes..."
      ${SUDO} zypper refresh
      echo "Installing ${installer_name}..."
      ${SUDO} zypper --no-gpg-checks install ${yes} "${installer_name}"
      ;;
  esac
}

# Installs prerequisites for RHEL/CentOS and SUSE
install_pre () {
  os=$1
  ver=$2

  case $os in
    "RedHat" | "CentOS" | "Alma" | "Rocky")
      install_epel "${os}" "${ver}"
      ;;
    "Amazon")
      install_epel_amzn
      ;;
    "SLES12")
      install_python_backports
      ;;
    "LEAP12" | "LEAP15" | "SLES15")
      ;;
  esac
}

# Installs EPEL for Amazon Linux 2
install_epel_amzn () {
  yes=
  if [[ "${RUN_UNATTENDED}" -ne "0" ]]; then
      yes="-y"
  fi
  ${SUDO} amazon-linux-extras install epel ${yes}
}

# Installs EPEL for RHEL/CentOS/Alma/Rocky
install_epel () {
  os=$1
  ver=$2
  yes=
  if [[ "${RUN_UNATTENDED}" -ne "0" ]]; then
      yes="-y"
  fi
  case $ver in
    "6")
      ${SUDO} yum install ${yes} https://dl.fedoraproject.org/pub/epel/epel-release-latest-6.noarch.rpm
      ;;
    "7")
      ${SUDO} yum install ${yes} https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
      ;;
    "8")
      ;;
    "9")
      if [[ "${os}" == "RedHat" ]]; then
        ${SUDO} subscription-manager repos --enable "codeready-builder-for-rhel-9-$(arch)-rpms"
        ${SUDO} dnf install ${yes} https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
      else
        ${SUDO} dnf install ${yes} dnf-plugins-core
        ${SUDO} dnf config-manager --set-enabled crb
        ${SUDO} dnf install ${yes} epel-release
      fi
      ;;
  esac
}

# Installs the Python backports repository for SLES 12
install_python_backports () {
  SLE_VERSION="SLE_$(grep "^VERSION=" /etc/os-release | sed -e 's/VERSION=//' -e 's/"//g' -e 's/-/_/')"
  ${SUDO} zypper --gpg-auto-import-keys addrepo https://download.opensuse.org/repositories/devel:/languages:/python:/backports/$SLE_VERSION/devel:languages:python:backports.repo
}

do_download () {
  url=$1
  file_name=$(basename "${url}")

  wget_rc=$(check_command "wget")
  curl_rc=$(check_command "curl")
  rc=0

  if [ "${url}" = "" ]; then
    echo "Installer already exists. Not downloading."
  else
    echo "Downloading installer from ${url}..."

    if [[ -z "${wget_rc}" ]]; then
        echo "Downloading ${url}..."

        if [[ "${RUN_UNATTENDED}" -ne "0" ]]; then
          wget -q --header "User-Agent: ${RS_USER_AGENT:-r-builds}" "${url}"
        else
          wget --progress=bar --header "User-Agent: ${RS_USER_AGENT:-r-builds}" "${url}"
        fi
        rc=$?
    # Or, If curl is around, use that.
    elif [[ -z "${curl_rc}" ]]; then
        echo "Downloading ${url}..."
        if [[ "${RUN_UNATTENDED}" -ne "0" ]]; then
          curl -fsSL -H "User-Agent: ${RS_USER_AGENT:-r-builds}" --output "${file_name}" "${url}"
        else
          curl -fL -H "User-Agent: ${RS_USER_AGENT:-r-builds}" --output "${file_name}" --progress-bar "${url}"
        fi
        rc=$?
    # Otherwise, we can't go on.
    else
        echo
        echo "You need either wget or curl to be able to download an installation bundle."
        echo "Either install one of those two tools or download the installation bundle"
        echo "manually."
        return 7
    fi

    if [[ "${rc}" -ne "0" ]]; then
        echo
        echo "We were unable to download the installation bundle."
        exit ${rc}
    fi
  fi
}

# This helps determine whether a given command exists or not.
check_command () {
    cmd=$1
    type "${cmd}" > /dev/null 2> /dev/null
    rc=$?

    if [[ "${rc}" = "0" ]]; then
        echo ""
    else
        echo "${rc}"
    fi
}

has_sudo () {
  if [[ "${SUDO}" == "" ]]; then
    test "0" == "0"
  else
    cmd=$1
    output=$(sudo -n -l "${cmd}")
    rc=$?

    test "0" == "${rc}"
  fi
}

check_commands () {
  curl_rc=$(check_command "curl")
  if [[ "${curl_rc}" != "" ]]; then
    echo "The curl command is required."
    exit 1
  fi

  if [[ "${SUDO}" != "" ]]; then
    sudo_rc=$(check_command "sudo")
    if [[ "${sudo_rc}" != "" ]]; then
      echo "The sudo command is required."
      exit 1
    fi
  fi
}

do_install () {

  # Check for curl
  check_commands

  # Detect OS
  os=$(detect_os)
  [ -z $os ] && { echo "OS not detected"; exit 1; }

  # Also detect the OS version (this may be blank if it's not relevant)
  os_ver=$(detect_os_version "${os}")

  # Determine version to download
  prompt_version
  [ -z $SELECTED_VERSION ] && { echo "Invalid version"; exit 1; }

  # Get the name of the installer to use
  installer_file_name=$(download_name "${os}" "${SELECTED_VERSION}")

  # Get the URL to download from. If the installer already exists in the current
  # directory, this will return a blank string.
  url=$(download_url "${os}" "${installer_file_name}" "${os_ver}")

  # Download the installer if necessary
  do_download ${url}

  # Install R
  installer_type=$(detect_installer_type "${os}")
  install "${installer_type}" "${installer_file_name}" "${os}" "${os_ver}"
}

do_show_usage() {
  echo "r-builds quick install version ${THIS_VERSION}"
  echo "Usage: `basename $0` [-i|-r|-v|-h|install|rversions|version|help]"
  echo "Where:"
  echo "'-i' or 'install' [version] [-y|yes] (default) list R versions available for quick install and prompt for one"
  echo "If a version is provided, the installation proceeds without prompting, confirmations can be optionally skipped"
  echo "'-r' or 'rversions' list the R versions available for quick install, one per line"
  echo "'-v' or 'version' shows the version of this command"
  echo "'-h' or 'help' show this info"
}

# Choose a command to perform
case ${SCRIPT_ACTION} in
  "-i"|"install")
    do_install
    ;;
  "-r"|"rversions")
    do_show_versions
    ;;
  "-v"|"version")
    echo "r-builds quick install version ${THIS_VERSION}"
    ;;
  "-h"|"help"|*)
    do_show_usage
    ;;
esac
