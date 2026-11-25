#!/bin/bash

# Install prerequisites for the custom Ubuntu ISO (FortiDeceptor).
# Run as root with the VM network already configured.

export PATH="$PATH:/usr/sbin:/sbin"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
clear='\033[0m'

# System Samba excluded: FDC extracts /opt/samba4 from samba.tar.xz.
# Apache2 excluded: install manually only for ISOs with a custom web app.
PACKAGES=(
  acl
  net-tools
  rsyslog
  openssl
  openssh-server
  openssh-client
  git
  gcc
  make
  python3-dev
  python3-pip
  python3-setuptools
  python3-requests
  python3-sh
  python3-netifaces
  python3-psutil
  python3-tornado
)

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${red}This script must be run as root${clear}"
    exit 1
  fi
}

update_index() {
  echo -e "${yellow}Updating apt package index...${clear}"
  if ! apt-get -y -qq update; then
    echo -e "${red}Failed to update apt index, run apt-get update manually${clear}"
    exit 1
  fi
  echo -e "${green}Done!${clear}"
}

install_pkg() {
  local pkg="$1"
  echo -e "${yellow}Installing ${pkg}...${clear}"
  if ! apt-get -y -qq install "${pkg}"; then
    echo -e "${red}Failed to install ${pkg}${clear}"
    exit 1
  fi
  echo -e "${green}Done!${clear}"
}

verify_install() {
  echo -e "${yellow}Verifying Python modules and system binaries...${clear}"
  if ! python3 -c "import requests, sh, netifaces, psutil, tornado, setuptools"; then
    echo -e "${red}Verification failed: missing Python module${clear}"
    exit 1
  fi
  for bin in ifconfig setfacl rsyslogd sshd git gcc make openssl; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
      echo -e "${red}Verification failed: ${bin} not found${clear}"
      exit 1
    fi
  done
  echo -e "${green}All Ubuntu modules verified and ready!${clear}"
}

check_root
update_index
for pkg in "${PACKAGES[@]}"; do
  install_pkg "${pkg}"
done
verify_install