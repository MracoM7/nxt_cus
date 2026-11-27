#!/bin/bash

# Final VM cleanup before shutdown and saving in FDC.
# Run as root after ubuntu_cus_toolkit_nxt.sh.

export PATH="$PATH:/usr/sbin:/sbin"

RESET_MACHINE_ID=true
RESET_SSH_HOSTKEYS=false     # true: requires host key regeneration at first boot
# Lock the accounts created while installing Ubuntu (uid 1000-59999): FDC applies its fake
# shell only to its own lure users, so any other account with a password would give a real
# shell. Requires a root password: root is then the only way in, from the FDC console only.
: "${LOCK_LOCAL_USERS:=true}"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
clear='\033[0m'

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${red}This script must be run as root${clear}"
    exit 1
  fi
}

lock_local_users() {
  [ "$LOCK_LOCAL_USERS" = true ] || return 0
  if [ "$(passwd -S root 2>/dev/null | awk '{print $2}')" != "P" ]; then
    echo -e "${red}root has no password: run 'passwd root' first, or you will not be able to log in${clear}"
    echo -e "${red}to this image again when re-customizing it (or set LOCK_LOCAL_USERS=false)${clear}"
    exit 1
  fi
  echo -e "${blue}Locking local accounts...${clear}"
  local name uid g
  while IFS=: read -r name _ uid _; do
    [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] || continue
    passwd -l "$name" >/dev/null 2>&1
    for g in sudo admin lxd adm; do
      gpasswd -d "$name" "$g" >/dev/null 2>&1
    done
    echo "  ${name}: password locked, removed from sudo/lxd/adm"
  done < /etc/passwd
}

stop_logging() {
  echo -e "${blue}Stopping syslog and shell audit...${clear}"
  trap - DEBUG 2>/dev/null
  systemctl stop syslog.socket rsyslog.service 2>/dev/null || true
}

clean_logs() {
  echo -e "${blue}Cleaning logs...${clear}"
  find /var/log -type f -not -path '/var/log/journal/*' \
    \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
  find /var/log -type f -not -path '/var/log/journal/*' -exec truncate -s0 {} +
  journalctl --rotate >/dev/null 2>&1 || true
  journalctl --vacuum-time=1s >/dev/null 2>&1 || true
  apt-get clean
  rm -f /tmp/launcherD.log /root/launcherD.log /root/launcherD.log.1 /tmp/ubuntu_ready.py
}

clean_history() {
  echo -e "${blue}Cleaning shell history...${clear}"
  truncate -c -s0 /root/.bash_history 2>/dev/null
  for hist in /home/*/.bash_history; do
    truncate -c -s0 "${hist}" 2>/dev/null
  done
}

reset_machine_id() {
  $RESET_MACHINE_ID || return 0
  echo -e "${blue}Resetting machine-id...${clear}"
  truncate -s0 /etc/machine-id
  [ -L /var/lib/dbus/machine-id ] || rm -f /var/lib/dbus/machine-id
}

reset_ssh_hostkeys() {
  $RESET_SSH_HOSTKEYS || return 0
  echo -e "${blue}Removing SSH host keys...${clear}"
  rm -f /etc/ssh/ssh_host_*
  echo -e "${yellow}Host keys removed: ensure they are regenerated at first boot${clear}"
}

check_root
lock_local_users
stop_logging
clean_logs
clean_history
reset_machine_id
reset_ssh_hostkeys
sync

echo -e "${green}Cleanup completed. Run: trap - DEBUG; history -c && history -w && shutdown -h now${clear}"