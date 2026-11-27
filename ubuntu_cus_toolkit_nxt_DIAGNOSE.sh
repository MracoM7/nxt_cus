#!/bin/bash

# Universal FortiDeceptor customization for Ubuntu Server (tested 20.04 -> 26.04).
#
# The script is re-runnable: every run converges the image to the flags below,
# enabling what is on and removing what is off. Typical workflow:
#   1. fresh install -> run with the defaults -> save as BASE image in FDC
#   2. re-customize BASE -> run with different flags -> save as a new image
#
# Flags can be set from the environment, without editing the file:
#   ENABLE_HTTP_NATIVE=false ENABLE_HTTP_APACHE=true bash ubuntu_cus_toolkit_nxt.sh
#
# Run as root after install_ubuntu_modules_nxt.sh (needed only on a fresh install).

export PATH="$PATH:/usr/sbin:/sbin"
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- flags
: "${ENABLE_SSH:=true}"
: "${ENABLE_SAMBA:=true}"
: "${ENABLE_HTTP_NATIVE:=true}"     # FDC built-in web page (Tornado)
: "${ENABLE_HTTP_APACHE:=false}"    # real Apache site (e.g. WordPress) feeding the FDC web monitor
: "${ENABLE_GIT:=false}"            # hangs at deploy, keep off
: "${ENABLE_SMTP:=true}"
: "${ENABLE_FTP:=true}"
: "${ENABLE_RADIUS:=true}"
: "${ENABLE_VNC:=true}"

: "${ENABLE_CMD_LOGGING:=true}"     # alert on every command line typed in an interactive bash
: "${ENABLE_EXEC_AUDIT:=true}"      # auditd: alert on commands typed in shells the bash hook misses

: "${DEPLOY_DIAG:=false}"           # debug only: report deploy failures to FDC with diagnostics
: "${DEPLOY_DIAG_MIN:=20}"          # minutes after boot before the deploy check runs

: "${DISABLE_SYSTEM_SSHD:=true}"    # mask Ubuntu's sshd: FDC runs its own bundled sshd
: "${APACHE_AUTO_INSTALL:=true}"    # install apache2 if Apache mode is on and it is missing
: "${WP_LOGIN_HOOK:=auto}"          # auto|true|false: WordPress login events with user/pass
: "${WP_ROOT:=/var/www/html}"

# ---------------------------------------------------------------- paths
# Neutral names: an attacker with a shell on the decoy should not read "fdc" anywhere.
WEB_LOG=/var/log/linux_web.log                     # read by FDC TornadoWebMonitor
LOGGER=/usr/local/sbin/a2logrelay
LOG_CONF=logging-relay                             # /etc/apache2/conf-available/logging-relay.conf
SSL_SITE=default-ssl-local                         # /etc/apache2/sites-available/default-ssl-local.conf
CERT_SYNC=/usr/local/sbin/a2certsync
CERT_UNIT=apache2-certsync
APACHE_OVERRIDE=/etc/systemd/system/apache2.service.d/override.conf
WP_HOOK_FILE=audit-log.php
FORWARDER=/usr/local/sbin/audit-forwarder         # relays shell activity to FDC (127.0.0.1:1399)
FORWARDER_UNIT=audit-forwarder
AUDISP_PLUGIN=/usr/local/sbin/audisp-forward
AUDIT_RULES=/etc/audit/rules.d/50-user-exec.rules
BASHRC=/etc/bash.bashrc

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
clear='\033[0m'

SERVICES=()

on() { [ "${!1}" = "true" ]; }

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${red}This script must be run as root${clear}"
    exit 1
  fi
}

validate_flags() {
  local f
  for f in ENABLE_SSH ENABLE_SAMBA ENABLE_HTTP_NATIVE ENABLE_HTTP_APACHE ENABLE_GIT \
           ENABLE_SMTP ENABLE_FTP ENABLE_RADIUS ENABLE_VNC ENABLE_CMD_LOGGING ENABLE_EXEC_AUDIT \
           DEPLOY_DIAG DISABLE_SYSTEM_SSHD APACHE_AUTO_INSTALL; do
    if [ "${!f}" != "true" ] && [ "${!f}" != "false" ]; then
      echo -e "${red}${f} must be true or false (got '${!f}')${clear}"
      exit 1
    fi
  done
  case "$DEPLOY_DIAG_MIN" in ''|*[!0-9]*)
    echo -e "${red}DEPLOY_DIAG_MIN must be a number of minutes${clear}"; exit 1 ;;
  esac
  case "$WP_LOGIN_HOOK" in auto|true|false) ;; *)
    echo -e "${red}WP_LOGIN_HOOK must be auto, true or false${clear}"; exit 1 ;;
  esac
  if on ENABLE_HTTP_NATIVE && on ENABLE_HTTP_APACHE; then
    echo -e "${red}ENABLE_HTTP_NATIVE and ENABLE_HTTP_APACHE cannot both be true${clear}"
    exit 1
  fi
}

check_environment() {
  echo -e "${blue}Checking OS packages and Python environment...${clear}"

  local bins=(python3 ifconfig setfacl)
  on ENABLE_GIT && bins+=(git)
  for bin in "${bins[@]}"; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
      echo -e "${red}${bin} not found, run install_ubuntu_modules_nxt.sh first${clear}"
      exit 1
    fi
  done

  for mod in psutil requests sh netifaces tornado; do
    if ! python3 -c "import ${mod}" 2>/dev/null; then
      echo -e "${red}Python module ${mod} is not installed${clear}"
      exit 1
    fi
  done

  if on ENABLE_HTTP_APACHE && ! command -v apache2 >/dev/null 2>&1; then
    if on APACHE_AUTO_INSTALL; then
      echo -e "${blue}Installing apache2...${clear}"
      apt-get -y -qq update && apt-get -y -qq install apache2 openssl || {
        echo -e "${red}Failed to install apache2${clear}"; exit 1; }
    else
      echo -e "${red}Apache2 not installed and APACHE_AUTO_INSTALL=false${clear}"
      exit 1
    fi
  fi

  if on ENABLE_EXEC_AUDIT && ! command -v auditctl >/dev/null 2>&1; then
    echo -e "${blue}Installing auditd...${clear}"
    apt-get -y -qq update && apt-get -y -qq install auditd || {
      echo -e "${red}Failed to install auditd${clear}"; exit 1; }
  fi
  echo -e "${green}Environment check passed${clear}"
}

# Engine bug on Ubuntu != 24.x: it calls the removed `systemd-resolve`, then falls back to
# `resolvconf -u`. We make the first call fail cleanly and provide a minimal resolvconf.
configure_dns() {
  echo -e "${blue}Configuring DNS fallback...${clear}"

  if [ -d "/etc/cloud/cloud.cfg.d" ]; then
    echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  fi

  rm -f /usr/bin/systemd-resolve

  mkdir -p /etc/resolvconf/resolv.conf.d
  cat > /usr/local/sbin/resolvconf <<'EOL'
#!/bin/sh
BASE_FILE="/etc/resolvconf/resolv.conf.d/base"
if [ -s "$BASE_FILE" ]; then
  rm -f /etc/resolv.conf
  cp "$BASE_FILE" /etc/resolv.conf
  chmod 644 /etc/resolv.conf
fi
exit 0
EOL
  chmod 755 /usr/local/sbin/resolvconf
  ln -sfn /usr/local/sbin/resolvconf /usr/sbin/resolvconf

  # The installer's netplan config (DHCP) never comes up in FDC networks: the engine sets
  # the network itself. Without this, every boot waits ~2 min for "network online".
  systemctl mask systemd-networkd-wait-online.service NetworkManager-wait-online.service >/dev/null 2>&1 || true

  echo -e "${green}DNS configured${clear}"
}

# Python 3.12+ removed ssl.wrap_socket and OpenSSL 3 rejects the engine's legacy TLS.
configure_ssl_compat() {
  echo -e "${blue}Configuring OpenSSL SECLEVEL=1 and Python SSL compatibility...${clear}"

  if [ -f /etc/ssl/openssl.cnf ]; then
    # migrate sections written by older versions of this script
    sed -i 's/fdc_ssl_sect/tls_compat_sect/g; s/fdc_tls_defaults/tls_compat_defaults/g' /etc/ssl/openssl.cnf
    if ! grep -q '^\[tls_compat_defaults\]' /etc/ssl/openssl.cnf; then
      cat >> /etc/ssl/openssl.cnf <<'EOL'

[openssl_init]
ssl_conf = tls_compat_sect

[tls_compat_sect]
system_default = tls_compat_defaults

[tls_compat_defaults]
CipherString = DEFAULT:@SECLEVEL=1
EOL
    fi
  fi

  local py_site
  py_site=$(python3 -c "import site; print(site.getsitepackages()[0])")
  rm -f "${py_site}/fdc_ssl_compat.py" "${py_site}/fdc_ssl_compat.pth"
  cat > "${py_site}/tls_compat.py" <<'EOL'
import ssl

def _patch_ctx(ctx):
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        ctx.set_ciphers("DEFAULT:@SECLEVEL=1")
    except ssl.SSLError:
        pass
    return ctx

_orig_create_default = ssl.create_default_context
def _patched_create_default(*args, **kwargs):
    return _patch_ctx(_orig_create_default(*args, **kwargs))
ssl.create_default_context = _patched_create_default

if not hasattr(ssl, "wrap_socket"):
    def _wrap_socket(sock, keyfile=None, certfile=None, server_side=False,
                     cert_reqs=ssl.CERT_NONE, ssl_version=None, ca_certs=None,
                     do_handshake_on_connect=True, suppress_ragged_eofs=True, ciphers=None):
        protocol = ssl.PROTOCOL_TLS_SERVER if server_side else ssl.PROTOCOL_TLS_CLIENT
        ctx = _patch_ctx(ssl.SSLContext(protocol))
        ctx.verify_mode = cert_reqs
        if ciphers:
            ctx.set_ciphers(ciphers)
        if certfile:
            ctx.load_cert_chain(certfile=certfile, keyfile=keyfile)
        if ca_certs:
            ctx.load_verify_locations(cafile=ca_certs)
        return ctx.wrap_socket(sock, server_side=server_side,
                               do_handshake_on_connect=do_handshake_on_connect,
                               suppress_ragged_eofs=suppress_ragged_eofs)
    ssl.wrap_socket = _wrap_socket
EOL
  echo "import tls_compat" > "${py_site}/tls-compat.pth"

  if ! python3 -c "import ssl; ssl.create_default_context(); assert callable(ssl.wrap_socket)"; then
    echo -e "${red}Failed to configure ssl compatibility shim${clear}"
    exit 1
  fi
}

# FDC starts its own bundled sshd (/root/init/trapinit/openssh) when SSH is selected.
# Ubuntu's sshd is never needed at deploy; left enabled, it stays exposed and unmonitored
# whenever SSH is not ticked in the deploy wizard.
configure_ssh() {
  if on DISABLE_SYSTEM_SSHD; then
    echo -e "${blue}Masking Ubuntu sshd (FDC uses its own)...${clear}"
    systemctl disable --now ssh.socket ssh.service >/dev/null 2>&1 || true
    systemctl mask ssh.socket ssh.service >/dev/null 2>&1 || true
  else
    systemctl unmask ssh.socket ssh.service >/dev/null 2>&1 || true
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    systemctl enable ssh.service >/dev/null 2>&1 || true
  fi
  on ENABLE_SSH && SERVICES+=("ssh")
}

configure_samba() {
  # FDC extracts its own Samba (/opt/samba4); the system one must not run.
  systemctl disable --now smbd nmbd >/dev/null 2>&1 || true
  on ENABLE_SAMBA && SERVICES+=("samba")
}

# Removes everything the Apache mode installs, including files named by older versions
# of this script, so every run starts from a clean state.
remove_apache_integration() {
  rm -f "$APACHE_OVERRIDE"
  rmdir /etc/systemd/system/apache2.service.d 2>/dev/null
  systemctl disable --now "${CERT_UNIT}.path" fdc-ssl-sync.path >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${CERT_UNIT}.service" "/etc/systemd/system/${CERT_UNIT}.path" \
        /etc/systemd/system/fdc-ssl-sync.service /etc/systemd/system/fdc-ssl-sync.path
  systemctl daemon-reload

  if command -v a2disconf >/dev/null 2>&1; then
    a2disconf -q "$LOG_CONF" fdc-monitor >/dev/null 2>&1 || true
    a2dissite -q "$SSL_SITE" fdc-default-ssl >/dev/null 2>&1 || true
  fi
  rm -f "/etc/apache2/conf-available/${LOG_CONF}.conf" /etc/apache2/conf-available/fdc-monitor.conf \
        "/etc/apache2/sites-available/${SSL_SITE}.conf" /etc/apache2/sites-available/fdc-default-ssl.conf
  # per-vhost CustomLog lines injected by older versions
  if [ -d /etc/apache2/sites-available ]; then
    sed -i '/fdc_web_logger\.py\|a2logrelay/d' /etc/apache2/sites-available/*.conf 2>/dev/null
  fi
  rm -f "$LOGGER" "$CERT_SYNC" /usr/local/bin/fdc_web_logger.py /usr/local/bin/fdc_sync_ssl.sh
  rm -f "${WP_ROOT}/wp-content/mu-plugins/${WP_HOOK_FILE}"
  setfacl -x u:www-data "$WEB_LOG" 2>/dev/null || true
}

install_wp_login_hook() {
  local want=false
  case "$WP_LOGIN_HOOK" in
    true) want=true ;;
    auto) [ -f "${WP_ROOT}/wp-config.php" ] && want=true ;;
  esac
  [ "$want" = true ] || return 0

  if [ ! -f "${WP_ROOT}/wp-config.php" ]; then
    echo -e "${red}WP_LOGIN_HOOK=true but no WordPress found in ${WP_ROOT}${clear}"
    exit 1
  fi
  echo -e "${blue}Installing WordPress login hook...${clear}"
  mkdir -p "${WP_ROOT}/wp-content/mu-plugins"
  cat > "${WP_ROOT}/wp-content/mu-plugins/${WP_HOOK_FILE}" <<'EOL'
<?php
/**
 * Plugin Name: Authentication audit
 * Description: Records authentication events for the IT audit trail.
 */
if (!defined('ABSPATH')) {
    exit;
}

function auth_audit_write($user, $pass, $result) {
    $https = !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off';
    $rec = array(
        'firstline'    => ($_SERVER['REQUEST_METHOD'] ?? 'POST') . ' ' . ($_SERVER['REQUEST_URI'] ?? '/wp-login.php'),
        'service_type' => $https ? 'https' : 'http',
        'user'         => ($user === '' || $user === null) ? 'N/A' : (string) $user,
        'pass'         => ($pass === '' || $pass === null) ? 'N/A' : (string) $pass,
        'auth'         => $result,
        'session_id'   => '',
        'remote_ip'    => $_SERVER['REMOTE_ADDR'] ?? '',
        'remote_port'  => (int) ($_SERVER['REMOTE_PORT'] ?? 0),
        'local_ip'     => $_SERVER['SERVER_ADDR'] ?? '',
        'local_port'   => (int) ($_SERVER['SERVER_PORT'] ?? ($https ? 443 : 80)),
        'User-Agent'   => $_SERVER['HTTP_USER_AGENT'] ?? '',
    );
    $json = json_encode($rec, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    if ($json === false) {
        return;
    }
    // the FDC monitor cuts the JSON at the first '}': escape braces inside values
    $json = '{' . str_replace(array('{', '}'), array('\\u007b', '\\u007d'), substr($json, 1, -1)) . '}';
    // WordPress forces PHP to UTC: use the system timezone, like the Apache relay does
    $tz = @timezone_open(trim((string) @file_get_contents('/etc/timezone'))) ?: timezone_open('UTC');
    $line = '[I ' . date_create('now', $tz)->format('ymd H:i:s') . ' web:2239] 200 ' . $json . "\n";
    @file_put_contents('/var/log/linux_web.log', $line, FILE_APPEND | LOCK_EX);
}

$GLOBALS['auth_audit_pw'] = null;

add_filter('authenticate', function ($user, $username, $password) {
    $GLOBALS['auth_audit_pw'] = $password;
    return $user;
}, 1, 3);

add_action('wp_login_failed', function ($username) {
    auth_audit_write($username, $GLOBALS['auth_audit_pw'], 'login failed');
}, 10, 1);

add_action('wp_login', function ($user_login) {
    auth_audit_write($user_login, $GLOBALS['auth_audit_pw'], 'login success');
}, 10, 1);
EOL
  chmod 644 "${WP_ROOT}/wp-content/mu-plugins/${WP_HOOK_FILE}"
  setfacl -m u:www-data:rw "$WEB_LOG"
}

apply_apache_integration() {
  echo -e "${blue}Configuring Apache for the FDC web monitor...${clear}"

  mkdir -p /etc/apache2/ssl
  if [ ! -f /etc/apache2/ssl/server.crt ] || [ ! -f /etc/apache2/ssl/server.key ]; then
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
      -subj "/C=US/ST=California/L=Sunnyvale/O=IT/CN=web.local" \
      -keyout /etc/apache2/ssl/server.key \
      -out /etc/apache2/ssl/server.crt >/dev/null 2>&1
    chmod 600 /etc/apache2/ssl/server.key
  fi

  a2enmod -q ssl setenvif >/dev/null 2>&1
  if ! apache2ctl -S 2>/dev/null | grep -q ":443"; then
    cat > "/etc/apache2/sites-available/${SSL_SITE}.conf" <<'EOL'
<IfModule mod_ssl.c>
<VirtualHost *:443>
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile /etc/apache2/ssl/server.crt
    SSLCertificateKeyFile /etc/apache2/ssl/server.key
</VirtualHost>
</IfModule>
EOL
    a2ensite -q "$SSL_SITE" >/dev/null 2>&1
  fi

  touch "$WEB_LOG"
  chmod 644 "$WEB_LOG"

  # Apache access log -> line format parsed by FDC TornadoWebMonitor:
  #   [I yymmdd HH:MM:SS web:NNNN] <status> {flat JSON}
  # The monitor slices from the first '{' to the first '}', so braces in values are escaped.
  cat > "$LOGGER" <<'EOL'
#!/usr/bin/env python3
import json
import sys
from datetime import datetime

LOG = "/var/log/linux_web.log"

for line in sys.stdin:
    parts = line.rstrip("\r\n").split("\t")
    if len(parts) < 9:
        continue
    status, req, proto, user, r_ip, r_port, l_ip, l_port, ua = parts[:9]
    rec = {
        "firstline": req,
        "service_type": proto if proto in ("http", "https") else "http",
        "user": "N/A" if user in ("", "-") else user,
        "pass": "N/A",
        "auth": "request",
        "session_id": "",
        "remote_ip": r_ip,
        "remote_port": int(r_port) if r_port.isdigit() else 0,
        "local_ip": l_ip,
        "local_port": int(l_port) if l_port.isdigit() else 80,
        "User-Agent": "" if ua == "-" else ua,
    }
    body = json.dumps(rec, separators=(",", ":"))
    body = "{" + body[1:-1].replace("{", "\\u007b").replace("}", "\\u007d") + "}"
    ts = datetime.now().strftime("%y%m%d %H:%M:%S")
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write("[I {} web:2239] {} {}\n".format(ts, status, body))
    except OSError:
        pass
EOL
  chmod 755 "$LOGGER"

  cat > "/etc/apache2/conf-available/${LOG_CONF}.conf" <<EOL
ServerName localhost
SetEnvIf Request_Protocol .* log_proto=http
SetEnvIfExpr "%{HTTPS} == 'on'" log_proto=https
LogFormat "%>s\t%r\t%{log_proto}e\t%u\t%a\t%{remote}p\t%A\t%p\t%{User-Agent}i" relay_tsv
GlobalLog "|${LOGGER}" relay_tsv
EOL
  a2enconf -q "$LOG_CONF" >/dev/null 2>&1

  # FDC injects its certificate for the HTTPS service at deploy: reuse it in Apache.
  cat > "$CERT_SYNC" <<'EOL'
#!/bin/sh
for dir in /usr/local/web /root/init/trapinit/event_tracers/decoy_common/extention_service/web; do
  if [ -f "$dir/server.crt" ] && [ -f "$dir/server.key" ]; then
    cp -f "$dir/server.crt" /etc/apache2/ssl/server.crt
    cp -f "$dir/server.key" /etc/apache2/ssl/server.key
    chmod 600 /etc/apache2/ssl/server.key
    break
  fi
done
EOL
  chmod 755 "$CERT_SYNC"

  # RefuseManualStop: the engine runs `systemctl stop apache2` during decoy preparation.
  # Apache must keep ports 80/443 so FDC's own Tornado server fails to bind; the FDC
  # monitor keeps reading linux_web.log, which is now fed by Apache.
  mkdir -p "$(dirname "$APACHE_OVERRIDE")"
  cat > "$APACHE_OVERRIDE" <<EOL
[Unit]
RefuseManualStop=yes
StartLimitIntervalSec=0

[Service]
ExecStartPre=${CERT_SYNC}
Restart=always
RestartSec=5
EOL

  cat > "/etc/systemd/system/${CERT_UNIT}.service" <<EOL
[Unit]
Description=Sync TLS certificate into Apache

[Service]
Type=oneshot
ExecStart=${CERT_SYNC}
ExecStartPost=/bin/systemctl reload apache2.service
EOL

  cat > "/etc/systemd/system/${CERT_UNIT}.path" <<'EOL'
[Unit]
Description=Watch for TLS certificate deployment

[Path]
PathChanged=/usr/local/web/server.crt
PathChanged=/root/init/trapinit/event_tracers/decoy_common/extention_service/web/server.crt

[Install]
WantedBy=multi-user.target
EOL

  install_wp_login_hook

  if ! apache2ctl configtest; then
    echo -e "${red}Invalid Apache configuration${clear}"
    exit 1
  fi
  systemctl daemon-reload
  systemctl enable apache2 "${CERT_UNIT}.path" >/dev/null 2>&1
  systemctl restart apache2

  SERVICES+=("http_v2")
  if apache2ctl -S 2>/dev/null | grep -q ":443"; then
    SERVICES+=("https_v2")
  fi
}

configure_http_https() {
  remove_apache_integration

  if on ENABLE_HTTP_APACHE; then
    apply_apache_integration
    return 0
  fi

  # Native mode, or no web at all: no real web server may run on the decoy.
  systemctl disable --now apache2 nginx >/dev/null 2>&1 || true
  if on ENABLE_HTTP_NATIVE; then
    SERVICES+=("http_v2" "https_v2")
  fi
}

configure_builtin_services() {
  on ENABLE_GIT && SERVICES+=("git")
  if on ENABLE_SMTP; then
    systemctl disable --now postfix exim4 >/dev/null 2>&1 || true
    SERVICES+=("smtp")
  fi
  if on ENABLE_FTP; then
    systemctl disable --now vsftpd proftpd >/dev/null 2>&1 || true
    SERVICES+=("ftp_v3")
  fi
  if on ENABLE_RADIUS; then
    systemctl disable --now freeradius >/dev/null 2>&1 || true
    SERVICES+=("radius")
  fi
  on ENABLE_VNC && SERVICES+=("vnc")
  return 0
}

# Commands typed outside the FDC fake shell (after `bash`, `sh`, a python pty, ...) are sent
# to the FDC event receiver in the fake shell's own format: they show up as SSH command
# alerts of the attacker's session (FDC matches them by username).
#   - bash hook (PS0): one message per command line typed at an interactive bash prompt
#   - auditd execve: only for commands typed in interactive shells the hook does not cover
# Never reported: shell startup files, tab completion, prompt hooks, the inside of scripts.
remove_session_logging() {
  sed -i '/^# >>> session-logging >>>$/,/^# <<< session-logging <<<$/d' "$BASHRC"
  systemctl disable --now "${FORWARDER_UNIT}.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${FORWARDER_UNIT}.service" "$FORWARDER" "$AUDISP_PLUGIN" "$AUDIT_RULES" \
        /etc/audit/plugins.d/audisp-forward.conf /etc/audisp/plugins.d/audisp-forward.conf
  if command -v augenrules >/dev/null 2>&1; then
    augenrules --load >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload
}

configure_session_logging() {
  remove_session_logging
  if ! on ENABLE_CMD_LOGGING && ! on ENABLE_EXEC_AUDIT; then
    return 0
  fi
  echo -e "${blue}Configuring shell activity forwarding...${clear}"

  cat > "$FORWARDER" <<'EOL'
#!/usr/bin/env python3
# Forwards interactive shell activity to the local event collector.
#
# Two inputs, one output (the FDC event receiver on 127.0.0.1:1399, same message the
# engine's fake shell sends, so alerts look exactly like native SSH command alerts):
#   - UDP 127.0.0.1:5140   one message per command line typed in an interactive bash
#                          (PS0 hook in /etc/bash.bashrc)
#   - unix socket          execve audit records (auditd plugin), used only for commands
#                          typed in interactive shells the bash hook does not cover
#                          (sh/dash, bash --norc, a bash whose hook was removed, ...)
#
# Noise rules: an exec is reported only if its parent is an interactive shell (stdin on a
# tty, no script, no -c), that shell is not covered by a recent hook message, and the
# shell is past its startup files. Children of scripts and of `sh -c` are never reported.
import base64
import json
import os
import pwd
import re
import select
import socket
import time

COLLECTOR = ("127.0.0.1", 1399)
HOOK_ADDR = ("127.0.0.1", 5140)
AUDIT_SOCK = "/run/audit-forwarder.sock"

SHELLS = {"bash", "rbash", "sh", "dash", "zsh", "ksh", "ksh93", "mksh", "ash",
          "busybox", "fish", "tcsh", "csh", "yash"}
VALUE_OPTS = {"--rcfile", "--init-file", "-o", "+o", "-O", "+O"}
HOOK_WINDOW = 3.0       # seconds an exec stays covered by the bash hook
STARTUP_GRACE = 1.0     # ignore execs made while a shell reads its startup files
RATE_MAX, RATE_WINDOW = 20, 5.0
EVENT_TIMEOUT = 0.3     # flush incomplete audit events after this idle time

CLK = os.sysconf("SC_CLK_TCK")
REC = re.compile(r"type=(\w+) msg=audit\(([^)]+)\):(.*)")
FIELD = re.compile(r'([\w\[\]]+)=("[^"]*"|\S+)')
ARG = re.compile(r"a(\d+)(?:\[(\d+)\])?$")

hooked = {}    # bash pid -> time of its last hook message
rate = {}      # shell pid -> (window start, count, suppression noted)
pending = {}   # audit serial -> partial event
out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


# ---------------------------------------------------------------- /proc helpers
def exe_name(pid):
    try:
        return os.path.basename(os.readlink("/proc/{}/exe".format(pid)))
    except OSError:
        return ""


def cmdline(pid):
    try:
        with open("/proc/{}/cmdline".format(pid), "rb") as f:
            return [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
    except OSError:
        return []


def stat_fields(pid):
    try:
        with open("/proc/{}/stat".format(pid)) as f:
            data = f.read()
        return data[data.rfind(")") + 2:].split()
    except OSError:
        return []


def ppid_of(pid):
    f = stat_fields(pid)
    return int(f[1]) if len(f) > 1 else 0


def age(pid):
    f = stat_fields(pid)
    try:
        with open("/proc/uptime") as u:
            uptime = float(u.read().split()[0])
        return uptime - int(f[19]) / CLK
    except (OSError, IndexError, ValueError):
        return 1e9


def uid_of(pid):
    try:
        with open("/proc/{}/status".format(pid)) as f:
            for line in f:
                if line.startswith("Uid:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return None


def ssh_conn(pid):
    try:
        with open("/proc/{}/environ".format(pid), "rb") as f:
            for kv in f.read().split(b"\0"):
                if kv.startswith(b"SSH_CONNECTION="):
                    return kv[15:].decode("utf-8", "replace")
    except OSError:
        pass
    return ""


def stdin_is_tty(pid):
    try:
        target = os.readlink("/proc/{}/fd/0".format(pid))
    except OSError:
        return False
    return target.startswith("/dev/pts/") or target.startswith("/dev/tty")


def interactive_shell(pid):
    name = exe_name(pid)
    if name not in SHELLS or not stdin_is_tty(pid):
        return False
    args = cmdline(pid)[1:]
    if name == "busybox" and args and os.path.basename(args[0]) in SHELLS:
        args = args[1:]
    skip = False
    for a in args:
        if skip:
            skip = False
            continue
        if a in VALUE_OPTS:
            skip = True
        elif a.startswith("--"):
            continue
        elif a[:1] in ("-", "+"):
            if "c" in a[1:]:
                return False        # sh -c '...': not typed interactively
        else:
            return False            # running a script
    return True


def shell_chain(pid):
    """pid plus its ancestors that are forked copies of the same shell (subshells)."""
    exe, cl = exe_name(pid), cmdline(pid)
    chain = [pid]
    for _ in range(16):
        p = ppid_of(chain[-1])
        if p <= 1 or exe_name(p) != exe or cmdline(p) != cl:
            break
        chain.append(p)
    return chain


# ---------------------------------------------------------------- output
def allowed(key, now):
    start, count, noted = rate.get(key, (now, 0, False))
    if now - start > RATE_WINDOW:
        start, count, noted = now, 0, False
    count += 1
    if count <= RATE_MAX:
        rate[key] = (start, count, noted)
        return True, False
    rate[key] = (start, count, True)
    return False, not noted


def b64(s):
    return base64.b64encode(s.encode("utf-8", "replace")).decode()


def emit(cmd, uid, pid, ppid, conn, key, now):
    ok, note = allowed(key, now)
    if not ok:
        if not note:
            return
        cmd = "(high command rate, further commands suppressed for {:.0f}s)".format(RATE_WINDOW)
    try:
        user = pwd.getpwuid(uid).pw_name
    except KeyError:
        user = str(uid)
    p = conn.split()
    sip, sport, dip = (p[0], p[1], p[2]) if len(p) >= 3 else ("0.0.0.0", "0", "0.0.0.0")
    msg = {"mtype": "ssh", "optype": 1304, "msg": b64(cmd), "username": b64(user),
           "dport": 22, "sip": sip, "dip": dip, "sport": int(sport) if sport.isdigit() else 0,
           "pid": pid, "ppid": ppid}
    try:
        out.sendto(json.dumps(msg).encode(), COLLECTOR)
    except OSError:
        pass


# ---------------------------------------------------------------- inputs
def handle_hook(data, now):
    parts = data.decode("utf-8", "replace").split("\x1f")
    if len(parts) != 5 or parts[0] != "1" or not parts[1].isdigit():
        return
    pid, cmd = int(parts[1]), parts[4].strip()
    if exe_name(pid) not in ("bash", "rbash"):
        return
    uid = uid_of(pid)
    if uid is None:
        return
    hooked[pid] = now
    if cmd:
        emit(cmd, uid, pid, ppid_of(pid), ssh_conn(pid) or parts[3], pid, now)


def unquote(v):
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        return v[1:-1]
    if v == "(null)":
        return ""
    try:
        return bytes.fromhex(v).decode("utf-8", "replace")
    except ValueError:
        return v


def decode_argv(execve):
    parts = {}
    for k, v in execve.items():
        m = ARG.match(k)
        if m:
            parts.setdefault(int(m.group(1)), {})[int(m.group(2) or 0)] = unquote(v)
    return ["".join(p[j] for j in sorted(p)) for _, p in sorted(parts.items())]


def process_exec(ev, now):
    sc, ex = ev.get("SYSCALL"), ev.get("EXECVE")
    if sc.get("success") != "yes" or sc.get("key") != '"uexec"':
        return
    try:
        pid, ppid, euid = int(sc["pid"]), int(sc["ppid"]), int(sc["euid"])
    except (KeyError, ValueError):
        return
    argv = decode_argv(ex)
    if not argv or not interactive_shell(ppid):
        return
    chain = shell_chain(ppid)
    if any(now - hooked.get(p, -1e9) < HOOK_WINDOW for p in chain):
        return
    top = chain[-1]
    if age(top) < STARTUP_GRACE:
        return
    emit(" ".join(argv), euid, pid, ppid, ssh_conn(top), top, now)


def handle_audit(data, now):
    for line in data.decode("utf-8", "replace").splitlines():
        m = REC.search(line)
        if not m:
            continue
        rtype, serial, rest = m.groups()
        ev = pending.setdefault(serial, {"t": now})
        ev["t"] = now
        if ev.get("done") or rtype not in ("SYSCALL", "EXECVE"):
            if rtype == "EOE":
                pending.pop(serial, None)
            continue
        ev[rtype] = dict(FIELD.findall(rest))
        if "SYSCALL" in ev and "EXECVE" in ev:
            ev["done"] = True
            process_exec(ev, now)


def main():
    hook = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    hook.bind(HOOK_ADDR)
    try:
        os.unlink(AUDIT_SOCK)
    except FileNotFoundError:
        pass
    old = os.umask(0o177)
    aud = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    aud.bind(AUDIT_SOCK)
    os.umask(old)

    last_gc = time.monotonic()
    while True:
        ready, _, _ = select.select([hook, aud], [], [], EVENT_TIMEOUT)
        now = time.monotonic()
        for s in ready:
            try:
                data = s.recv(262144)
                if s is hook:
                    handle_hook(data, now)
                else:
                    handle_audit(data, now)
            except Exception:
                pass
        for serial in [k for k, v in pending.items() if now - v["t"] > EVENT_TIMEOUT]:
            pending.pop(serial, None)
        if now - last_gc > 60:
            last_gc = now
            for d, ttl in ((hooked, 60), (rate, 60)):
                for k in [k for k, v in d.items() if now - (v if d is hooked else v[0]) > ttl]:
                    d.pop(k, None)


if __name__ == "__main__":
    main()
EOL
  chmod 755 "$FORWARDER"
  if ! python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$FORWARDER"; then
    echo -e "${red}Forwarder syntax check failed${clear}"
    exit 1
  fi

  cat > "/etc/systemd/system/${FORWARDER_UNIT}.service" <<EOL
[Unit]
Description=Audit event forwarder
After=network.target

[Service]
ExecStart=/usr/bin/python3 ${FORWARDER}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOL
  systemctl daemon-reload
  systemctl enable --now "${FORWARDER_UNIT}.service" >/dev/null 2>&1

  if on ENABLE_CMD_LOGGING; then
    cat >> "$BASHRC" <<'EOL'
# >>> session-logging >>>
# Interactive shell commands are logged per IT security policy.
if [[ $- == *i* ]] && (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
    __bp_preexec() {
        local l
        l=$(HISTTIMEFORMAT= builtin history 1)
        l=${l#*[0-9]  }
        [[ -n $l ]] || return 0
        builtin printf '1\x1f%s\x1f%s\x1f%s\x1f%s' "$$" "${USER:-}" "${SSH_CONNECTION:-}" "$l" >/dev/udp/127.0.0.1/5140
    } 2>/dev/null
    __bp_precmd() {
        HISTCONTROL=; HISTIGNORE=; builtin set -o history
        PS0='$(__bp_preexec)'
    }
    [[ $PROMPT_COMMAND == *__bp_precmd* ]] || PROMPT_COMMAND="__bp_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    PS0='$(__bp_preexec)'
fi
# <<< session-logging <<<
EOL
  fi

  if on ENABLE_EXEC_AUDIT; then
    cat > "$AUDISP_PLUGIN" <<'EOL'
#!/usr/bin/env python3
# auditd plugin: passes execve records to the local forwarder over a root-only socket.
import re
import signal
import socket
import sys

SOCK = "/run/audit-forwarder.sock"
KEEP = re.compile(rb"type=(SYSCALL|EXECVE|EOE) ")

signal.signal(signal.SIGHUP, signal.SIG_IGN)
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
for line in sys.stdin.buffer:
    if KEEP.search(line[:200]):
        try:
            s.sendto(line, SOCK)
        except OSError:
            pass
EOL
    chown root:root "$AUDISP_PLUGIN"
    chmod 750 "$AUDISP_PLUGIN"

    local plugdir
    for plugdir in /etc/audit/plugins.d /etc/audisp/plugins.d; do
      [ -d "$plugdir" ] || continue
      cat > "${plugdir}/audisp-forward.conf" <<EOL
active = yes
direction = out
path = ${AUDISP_PLUGIN}
type = always
format = string
EOL
      chmod 640 "${plugdir}/audisp-forward.conf"
      break
    done

    mkdir -p "$(dirname "$AUDIT_RULES")"
    cat > "$AUDIT_RULES" <<'EOL'
-a always,exit -F arch=b64 -S execve,execveat -F euid>=1000 -F euid<60000 -k uexec
-a always,exit -F arch=b32 -S execve -F euid>=1000 -F euid<60000 -k uexec
EOL
    systemctl enable --now auditd >/dev/null 2>&1 || true
    if ! augenrules --load >/dev/null 2>&1; then
      echo -e "${red}Failed to load audit rules${clear}"
      exit 1
    fi
    pkill -HUP -x auditd 2>/dev/null || true
  fi
}

# Debug aid for failed deploys (no access to the decoy): DEPLOY_DIAG_MIN minutes after
# boot, if the engine has not finished, report the failure to FDC through the engine's own
# function. The engine then uploads /root/*.log plus /root/diag.txt to FDC.
configure_deploy_diag() {
  systemctl disable --now boot-healthcheck.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/boot-healthcheck.service /etc/systemd/system/boot-healthcheck.timer \
        /usr/local/sbin/boot-healthcheck
  if ! on DEPLOY_DIAG; then
    systemctl daemon-reload
    return 0
  fi
  echo -e "${blue}Installing deploy diagnostics (${DEPLOY_DIAG_MIN} min)...${clear}"
  cat > /usr/local/sbin/boot-healthcheck <<'EOL'
#!/usr/bin/env python3
# Deploy diagnostics: if the FDC engine has not finished initializing this decoy some
# minutes after boot, report a failure to FDC with the engine's own reporting function.
# On failure reports the engine uploads every log in /root to FDC, so this also ships
# diag.txt (system state collected here) where it can be downloaded from the FDC GUI.
import glob
import json
import logging
import os
import re
import subprocess
import sys
import time

ROOT = os.environ.get("HC_ROOT", "/root")
DONE_FLAG = os.path.join(ROOT, "flag.init.done")
CDROM_MNT = "/mnt/hc"
EXC = re.compile(r"[A-Za-z_][\w.]*(Error|Exception|Exit)\b")
UNIT = re.compile(r"\S+\.(service|socket|mount|timer|path|target|scope|slice|device|swap)$")
CONF_NAMES = ("instanceinit.json", "trapinit/instanceinit.json", "trapinit/instance.json")


def sh(cmd, limit=4000):
    try:
        out = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             timeout=20).stdout.decode("utf-8", "replace")
    except Exception as e:
        out = "<{}>".format(e)
    return out[-limit:]


def find_engine():
    base = os.path.join(ROOT, "init")
    if not os.path.isdir(os.path.join(base, "trapinit")):
        os.makedirs(CDROM_MNT, exist_ok=True)
        sh("mount -o ro /dev/cdrom {}".format(CDROM_MNT))
        base = CDROM_MNT
    conf = None
    for name in (os.path.join(ROOT, "instanceinit.json"),) + tuple(os.path.join(base, n) for n in CONF_NAMES):
        if os.path.isfile(name):
            with open(name) as f:
                conf = json.load(f)
            break
    return os.path.join(base, "trapinit"), conf


def monitor_ip(conf):
    for itf in conf.get("network", {}).get("interfaces", []):
        if (itf.get("brname") or "").lower() == "decoy-br":
            return itf["monitor"]["ip"].split("/")[0]
    return "10.254.254.1"


def last_error():
    best = (0, "")
    for path in glob.glob(os.path.join(ROOT, "*.log")) + glob.glob(os.path.join(ROOT, "*.log.*")):
        try:
            mtime = os.path.getmtime(path)
            with open(path, errors="replace") as f:
                lines = f.readlines()[-400:]
        except OSError:
            continue
        for line in reversed(lines):
            low = line.lower()
            if "traceback (most recent" in low:
                continue    # the exception line below it is more useful, and is found first
            if EXC.match(line.strip()) or "error" in low or "failed" in low:
                if mtime >= best[0]:
                    best = (mtime, "{}: {}".format(os.path.basename(path), line.strip()))
                break
    return best[1][:250] or "no error line found in /root logs"


def last_step():
    """Last 'SUCCESS: ...' line of the engine init log: how far initialization got."""
    for path in (os.path.join(ROOT, "LinuxInit.log"),):
        try:
            with open(path, errors="replace") as f:
                lines = f.readlines()[-2000:]
        except OSError:
            return "no LinuxInit.log (init never started?)"
        for line in reversed(lines):
            if "SUCCESS:" in line:
                return line.split("SUCCESS:", 1)[1].strip()[:80]
        return "LinuxInit.log has no SUCCESS step"
    return ""


def failed_units():
    out = sh("systemctl list-units --failed --plain --no-legend --no-pager")
    names = [l.split()[0] for l in out.splitlines() if l.strip() and UNIT.match(l.split()[0])]
    return ",".join(names)[:120] or "none"


def write_diag(stage):
    parts = ["stage: " + stage, "uptime: " + sh("uptime")]
    for title, cmd in (
        ("/root", "ls -la {}".format(ROOT)),
        ("failed units", "systemctl --failed --no-pager"),
        ("launcherD", "systemctl status launcherD --no-pager -n 30"),
        ("journal errors, previous boot", "journalctl -b -1 -p err --no-pager -n 120"),
        ("journal errors, this boot", "journalctl -b -p err --no-pager -n 120"),
        ("network", "ip -br a; ip r; cat /etc/resolv.conf"),
        ("listening", "ss -lntup"),
        ("processes", "ps -eo pid,ppid,user,etime,cmd --forest | head -150"),
        ("audit", "auditctl -s; auditctl -l"),
    ):
        parts.append("===== {} =====\n{}".format(title, sh(cmd)))
    for path in sorted(glob.glob(os.path.join(ROOT, "*.log"))):
        parts.append("===== tail {} =====\n{}".format(path, sh("tail -n 60 '{}'".format(path))))
    with open(os.path.join(ROOT, "diag.txt"), "w") as f:
        f.write("\n\n".join(parts))


def main():
    if os.path.exists(DONE_FLAG):
        return 0
    engine, conf = find_engine()
    if conf is None:
        return 0                      # not a deployed decoy (e.g. customization VM)
    stage = "init not completed {:.0f} min after boot".format(
        float(open("/proc/uptime").read().split()[0]) / 60)
    write_diag(stage)
    flags = ",".join(n for n in ("disabled", "ready.flg") if os.path.exists(os.path.join(ROOT, n))) or "none"
    msg = "diag: {} | last step: {} | flags: {} | failed units: {} | last error: {}".format(
        stage, last_step(), flags, failed_units(), last_error())

    logging.basicConfig(filename=os.path.join(ROOT, "healthcheck.log"), level=logging.DEBUG)
    logger = logging.getLogger("healthcheck")
    logger.info(msg)
    sys.path.insert(0, engine)
    os.chdir(engine)
    from event_tracers.decoy_common.decoy_lib import send_to_fdc
    send_to_fdc("rpts", conf.get("id"), {"status": 1, "version": conf.get("version"), "msg": msg},
                logger, conf.get("network", {}).get("hostname"), monitor_ip(conf))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOL
  chmod 700 /usr/local/sbin/boot-healthcheck

  cat > /etc/systemd/system/boot-healthcheck.service <<'EOL'
[Unit]
Description=Boot health check

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/sbin/boot-healthcheck
EOL
  cat > /etc/systemd/system/boot-healthcheck.timer <<EOL
[Unit]
Description=Boot health check

[Timer]
OnBootSec=${DEPLOY_DIAG_MIN}min

[Install]
WantedBy=timers.target
EOL
  systemctl daemon-reload
  systemctl enable boot-healthcheck.timer >/dev/null 2>&1
}

install_launcherD_service() {
cat >/usr/bin/launcherD.py <<'EOL'
#!/usr/bin/env python3
import glob
import json
import logging
import os
import traceback
from logging.handlers import RotatingFileHandler
from os import path
import shutil
import subprocess
import time

CD_DEVICES = ("/dev/cdrom", "/dev/sr[0-9]*")
CD_WAIT = 180   # seconds: udev creates the CD device a few seconds after this service starts


class LauncherD():
    def __init__(self):
        self.mount = "/mnt/init"
        self.dest = "/root/init"
        self.conf = None
        self.logger = None
        self.init_logger()

    def init_logger(self):
        # /root, not /tmp: the log must not be readable by an attacker's low-privilege shell
        self.logger = logging.getLogger(__name__)
        self.logger.setLevel(logging.DEBUG)
        handler = RotatingFileHandler("/root/launcherD.log", maxBytes=102400, backupCount=1)
        self.logger.addHandler(handler)

    def find_cd(self):
        """Mount the CD that carries trapinit, waiting for it to show up."""
        import sh
        deadline = time.time() + CD_WAIT
        while True:
            seen = set()
            for pattern in CD_DEVICES:
                for dev in sorted(glob.glob(pattern)):
                    real = os.path.realpath(dev)
                    if real in seen:
                        continue
                    seen.add(real)
                    try:
                        sh.mount("-o", "ro", dev, self.mount)
                    except Exception:
                        continue
                    if path.isdir(path.join(self.mount, "trapinit")):
                        self.logger.debug("init CD found on {}".format(dev))
                        return True
                    try:
                        sh.umount(self.mount)
                    except Exception:
                        pass
            if time.time() > deadline:
                self.logger.error("no CD with trapinit after {}s, devices seen: {}".format(
                    CD_WAIT, sorted(seen) or "none"))
                return False
            time.sleep(2)

    def load_config(self):
        import sh
        if not self.find_cd():
            return
        try:
            if path.exists(self.dest):
                shutil.rmtree(self.dest)
            shutil.copytree(self.mount, self.dest)
            self.logger.debug("got init files")
        except Exception:
            self.logger.error(traceback.format_exc())
        finally:
            try:
                sh.umount(self.mount)
            except Exception:
                pass

    def run_init(self, init):
        script = path.join(self.dest, "trapinit", init)
        self.logger.debug(script)
        p = subprocess.Popen(["python3", script])
        p.wait()

    def run(self):
        if not os.path.exists(self.mount):
            os.mkdir(self.mount)
        self.load_config()

        if os.path.exists("/root/instanceinit.json"):
            conf_path = "/root/instanceinit.json"
        elif os.path.exists("/root/init/trapinit/instanceinit.json"):
            conf_path = "/root/init/trapinit/instanceinit.json"
        else:
            conf_path = "/root/init/trapinit/instance.json"

        self.logger.info(conf_path)
        if os.path.exists(conf_path):
            with open(conf_path, "r") as f:
                self.conf = json.load(f)
            # the config holds decoy credentials and the FDC address: do not log it
            init = self.conf.get("init")
            if not init:
                self.logger.error("no init script found!")
                exit(1)
            self.logger.info("prepare to run {}".format(init))
            self.run_init(init)
        else:
            self.logger.info("no config file found")
        self.logger.info("LauncherD Main Loop ...")
        while True:
            time.sleep(10)


if __name__ == "__main__":
    LauncherD().run()
EOL
chmod 755 /usr/bin/launcherD.py
rm -f /tmp/launcherD.log

cat >/etc/systemd/system/launcherD.service <<'EOL'
[Unit]
Description=launcherD service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/bin/launcherD.py

[Install]
WantedBy=default.target
EOL

systemctl daemon-reload
systemctl enable /etc/systemd/system/launcherD.service
systemctl start launcherD.service
}

prepare_base_image() {
  systemctl stop launcherD.service
  umount /dev/cdrom 2>/dev/null
  rm -rf /root/init
}

notify_fdc() {
cat > /tmp/ubuntu_ready.py <<'EOL'
#!/usr/bin/env python3
import json
import os
import ssl
import sys
import time
from urllib import parse, request

workdir = sys.argv[2]
jpath = os.path.join(workdir, "..", "net.json")
if not os.path.exists(jpath):
    print("No net.json found")
    sys.exit(1)
monitor_ip = "10.254.253.1"
with open(jpath) as f:
    net_cfg = json.load(f)
    monitor_ip = net_cfg["brnat"].get("monitor", monitor_ip)

cpu_name = ""
try:
    with open("/proc/cpuinfo") as f:
        for line in f:
            if line.lower().startswith("model name"):
                cpu_name = line.strip().split(": ")[1]
                break
except FileNotFoundError:
    pass

services = [s for s in sys.argv[1].split(",") if s]
service_name_map = {
    "ssh": "SSH", "samba": "SAMBA", "http_v2": "HTTP", "https_v2": "HTTPS",
    "git": "GIT", "smtp": "SMTP", "ftp_v3": "FTP", "radius": "RADIUS", "vnc": "VNC"
}
services_str = "".join(" " + service_name_map.get(s, s.upper()) for s in services)

log_content = "Installation successful, supported services:{}".format(services_str)
msg = {"version": "1.0", "status": '1', "log": log_content, "cpu_name": cpu_name,
       'os': 'ubuntu', 'services': services}

dst_url = "https://{}:1443/vmcus".format(monitor_ip)
raw_data = {"trapid": '000000', "msg": json.dumps(msg)}
data = bytes(parse.urlencode(raw_data), encoding='utf-8')
ctx = ssl._create_unverified_context()

for attempt in range(1, 4):
    try:
        request.urlopen(dst_url, data=data, timeout=5, context=ctx)
        break
    except Exception as e:
        print("FDC notification attempt {} failed: {}".format(attempt, e))
        if attempt == 3:
            sys.exit(1)
        time.sleep(3)

print("Script Completed. Run 'bash {}', then shut down the VM and save it in the FDC GUI".format(
    os.path.join(workdir, "decoy_finalize_nxt.sh")))
EOL

servicestr=$(IFS=, ; echo "${SERVICES[*]}")
script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
if ! python3 /tmp/ubuntu_ready.py "${servicestr}" "${script_dir}"; then
  echo -e "${red}FDC notification failed${clear}"
  exit 1
fi
}

print_summary() {
  local web=none
  on ENABLE_HTTP_NATIVE && web=native
  on ENABLE_HTTP_APACHE && web=apache
  echo -e "${green}Image profile${clear}"
  echo "  web mode        : ${web}"
  echo "  system sshd     : $(on DISABLE_SYSTEM_SSHD && echo masked || echo enabled)"
  echo "  bash cmd hook   : $(on ENABLE_CMD_LOGGING && echo on || echo off)"
  echo "  exec audit      : $(on ENABLE_EXEC_AUDIT && echo on || echo off)"
  echo "  deploy diag     : $(on DEPLOY_DIAG && echo "on (${DEPLOY_DIAG_MIN} min)" || echo off)"
  if [ "$web" = apache ]; then
    echo "  WP login hook   : $([ -f "${WP_ROOT}/wp-content/mu-plugins/${WP_HOOK_FILE}" ] && echo installed || echo no)"
  fi
  echo "  services to FDC : ${SERVICES[*]:-none}"
}

check_root
validate_flags
check_environment
configure_dns
configure_ssl_compat
configure_ssh
configure_samba
configure_http_https
configure_builtin_services
configure_session_logging
configure_deploy_diag
install_launcherD_service
prepare_base_image
print_summary
notify_fdc
