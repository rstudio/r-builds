#!/bin/bash

# Call with:
#   bash -c "$(curl -L https://rstd.io/r-install)"

SCRIPT_ACTION=$1
SCRIPT_ACTION=${SCRIPT_ACTION:-install}

# Set to the full version to install. Must be either available on S3 or in the working directory
R_VERSION=${R_VERSION:-}

SUDO=
if [[ $(id -u) != "0" ]]; then
  SUDO=sudo
fi

# The root of the S3 URL for downloads
CDN_URL='https://cdn.rstudio.com/r'

# The URL for listing available R versions
VERSIONS_URL="${CDN_URL}/versions.json"

R_VERSIONS=$(curl ${VERSIONS_URL} | \
  # Matches the JSON line that contains the r versions
  grep r_versions | \
  # Gets the value of the `r_version` property (e.g., "[ 3.0.0, 3.0.3, ... ]")
  cut -f2 -d ":" | \
  # Removes the opening and closing brackets of the array
  cut -f2 -d "[" | cut -f1 -d "]" | \
  # Removes the quotes and commas from the values
  sed -e 's/\"//g' | sed -e 's/\,//g' | \
  # Reverses the order of the list
  ( while read -d ' ' f;do g="$f${g+ }$g" ;done;echo "$g" ))

# Returns the OS
detect_os () {
  OS='cat /etc/*-release'
  distro=$($OS | grep DISTRIB_ID | cut -f2 -d "=")
  if test -f /etc/SuSE-release
  then
   distro="SUSE"
  fi
  if [[ -f /etc/centos-release || -f /etc/redhat-release ]]
  then
   distro="RedHat"
  fi
  if [[ $(cat /etc/os-release | grep -e "^CPE_NAME\=*" | cut -f 2 -d '=') == "\"cpe:/o:opensuse:leap:15.0\"" ]]
  then
   distro="SUSE15"
  fi
  if [[ $(cat /etc/os-release | grep -e "^CPE_NAME\=*" | cut -f 2 -d '=') == "\"cpe:/o:suse:sles:15\"" ]]
  then
   distro="SUSE15"
  fi
  if [[ $(cat /etc/os-release | grep -e "^ID\=*" | cut -f 2 -d '=') == "debian" ]]; then
    distro="Debian"
  fi
  echo "${distro}"
}

# Returns the OS version
detect_os_version () {
  os=$1
  if [[ "${os}" == "RedHat" ]]; then
    if [[ $(cat /etc/os-release | grep -e "^VERSION_ID\=*" | cut -f 2 -d '=') =~ ^(\"8.|28) ]]; then
      echo "8"
    else
      if [[ -f /etc/os-release ]]; then
        cat /etc/os-release | grep -e "^VERSION_ID\=*" | cut -f 2 -d '=' | sed -e 's/"//g'
      else
        if [[ -f /etc/redhat-release ]]; then
          if [[ $(cat /etc/redhat-release | grep "6.") ]]; then
            echo 6
          fi
        fi
      fi
    fi
  fi
  if [[ "${os}" == "Ubuntu" ]]; then
    cat /etc/os-release | grep -e "^VERSION_ID\=*" | cut -f 2 -d '=' | sed -e 's/[".]//g'
  fi
}

# Returns the installer type
detect_installer_type () {
  os=$1
  if [ "${os}" = "SUSE" ]; then
    echo "rpm"
  else
    if [ "${os}" = "SUSE15" ]; then
      echo "rpm"
    else
      if [ "${os}" = "RedHat" ]; then
        echo "rpm"
      else
        echo "deb"
      fi
    fi
  fi
}

# Lists available R versions
show_versions () {
  for v in ${R_VERSIONS}
  do
    echo "  ${v}"
  done
}

# Returns the installer name for a given version and OS
download_name () {
  os=$1
  version=$2
  case $os in
    "RedHat" | "CentOS")
      echo "R-${version}-1-1.x86_64.rpm"
      ;;
    "Ubuntu" | "Debian")
      echo "r-${version}_1_amd64.deb"
      ;;
    "SUSE" | "SUSE15")
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
      "RedHat" | "CentOS")
        echo "${CDN_URL}/centos-${ver}/pkgs/${name}"
        ;;
      "Ubuntu")
        echo "${CDN_URL}/ubuntu-${ver}/pkgs/${name}"
        ;;
      "Debian")
        echo "${CDN_URL}/debian-9/pkgs/${name}"
        ;;
      "SUSE")
        echo "${CDN_URL}/opensuse-42/pkgs/${name}"
        ;;
      "SUSE15")
        echo "${CDN_URL}/opensuse-15/pkgs/${name}"
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

  ${SUDO} apt-get install gdebi-core
  ${SUDO} gdebi "${installer_name}"
}

# Installs R for RHEL/CentOS and SUSE
install_rpm () {
  installer_name=$1
  os=$2
  ver=$3
  echo "User install from RPM installer ${installer_name}..."
  install_pre "${os}" "${ver}"
  case $os in
    "RedHat" | "CentOS")
      if ! has_sudo "yum"; then
        echo "Must have sudo privileges to run yum"
        exit 1
      fi
      ${SUDO} yum install "${installer_name}"
      ;;
    "SUSE" | "SUSE15")
      if ! has_sudo "zypper"; then
        echo "Must have sudo privileges to run zypper"
        exit 1
      fi
      ${SUDO} zypper --no-gpg-checks install "${installer_name}"
      ;;
  esac
}

# Installs prerequisites for RHEL/CentOS and SUSE
install_pre () {
  os=$1
  ver=$2

  case $os in
    "RedHat" | "CentOS")
      install_epel "${ver}"
      ;;
    "SUSE")
      install_sci
      ;;
    "SUSE15")
      ;;
  esac
}

# Installs EPEL for RHEL/CentOS
install_epel () {
  ver=$1

  case $ver in
    "6")
      ${SUDO} yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-6.noarch.rpm
      ;;
    "7")
      ${SUDO} yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
      ;;
    "8")
      ;;
  esac
}

# Installs the Science repository for SLES 12
install_sci () {
  ${SUDO} zypper --gpg-auto-import-keys addrepo https://download.opensuse.org/repositories/science/SLE_12/science.repo
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
        wget --progress=bar "${url}"
        rc=$?
    # Or, If curl is around, use that.
    elif [[ -z "${curl_rc}" ]]; then
        echo "Downloading ${url}..."
        curl --output "${file_name}" --progress-bar "${url}"
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

# Choose a command to perform
case ${SCRIPT_ACTION} in
  "install")
    do_install
    ;;
esac
