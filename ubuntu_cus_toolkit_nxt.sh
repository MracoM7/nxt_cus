#!/bin/bash

# Custom Ubuntu ISO configuration for FortiDeceptor.
# Run as root after install_ubuntu_modules_nxt.sh.

export PATH="$PATH:/usr/sbin:/sbin"
export DEBIAN_FRONTEND=noninteractive

ENABLE_SSH=true
ENABLE_SAMBA=true
ENABLE_HTTP_NATIVE=true
ENABLE_HTTP_APACHE=false
ENABLE_GIT=false
ENABLE_SMTP=true
ENABLE_FTP=true
ENABLE_RADIUS=true
ENABLE_VNC=true

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
clear='\033[0m'

SERVICES=()

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${red}This script must be run as root${clear}"
    exit 1
  fi
}

check_environment() {
  echo -e "${blue}Checking OS packages and Python environment...${clear}"

  if $ENABLE_HTTP_NATIVE && $ENABLE_HTTP_APACHE; then
    echo -e "${red}ENABLE_HTTP_NATIVE and ENABLE_HTTP_APACHE cannot both be true${clear}"
    exit 1
  fi

  local bins=(python3 ifconfig setfacl)
  if $ENABLE_SSH; then bins+=(sshd); fi
  if $ENABLE_GIT; then bins+=(git); fi

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

  if $ENABLE_HTTP_APACHE; then
    if ! apache2 -v >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
      echo -e "${red}Apache2/openssl not installed, install them before running this script${clear}"
      exit 1
    fi
  fi
  echo -e "${green}Environment check passed${clear}"
}

configure_dns() {
  echo -e "${blue}Configuring DNS fallback and syslog routing...${clear}"

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

  echo -e "${green}DNS configured${clear}"
}

configure_ssh() {
  $ENABLE_SSH || return 0
  echo -e "${blue}Configuring OpenSSH...${clear}"

  systemctl disable --now ssh.socket 2>/dev/null || true
  systemctl enable ssh.service >/dev/null 2>&1 || true
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/01-fdc-ssh.conf <<'EOL'
PasswordAuthentication yes
PermitRootLogin yes
EOL

  if ! sshd -t; then
    echo -e "${red}Invalid sshd configuration${clear}"
    exit 1
  fi
  systemctl restart ssh.service
  SERVICES+=("ssh")
}

configure_samba() {
  $ENABLE_SAMBA || return 0
  systemctl disable --now smbd nmbd 2>/dev/null || true
  SERVICES+=("samba")
}

configure_ssl_compat() {
  echo -e "${blue}Configuring OpenSSL SECLEVEL=1 and Python 3.12+ SSL compatibility...${clear}"

  if [ -f /etc/ssl/openssl.cnf ] && ! grep -q '^\[fdc_tls_defaults\]' /etc/ssl/openssl.cnf; then
    cat >> /etc/ssl/openssl.cnf <<'EOL'

[openssl_init]
ssl_conf = fdc_ssl_sect

[fdc_ssl_sect]
system_default = fdc_tls_defaults

[fdc_tls_defaults]
CipherString = DEFAULT:@SECLEVEL=1
EOL
  fi

  local py_site
  py_site=$(python3 -c "import site; print(site.getsitepackages()[0])")
  cat > "${py_site}/fdc_ssl_compat.py" <<'EOL'
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
    def _wrap_socket(
        sock,
        keyfile=None,
        certfile=None,
        server_side=False,
        cert_reqs=ssl.CERT_NONE,
        ssl_version=None,
        ca_certs=None,
        do_handshake_on_connect=True,
        suppress_ragged_eofs=True,
        ciphers=None,
    ):
        protocol = ssl.PROTOCOL_TLS_SERVER if server_side else ssl.PROTOCOL_TLS_CLIENT
        ctx = _patch_ctx(ssl.SSLContext(protocol))
        ctx.verify_mode = cert_reqs
        if ciphers:
            ctx.set_ciphers(ciphers)
        if certfile:
            ctx.load_cert_chain(certfile=certfile, keyfile=keyfile)
        if ca_certs:
            ctx.load_verify_locations(cafile=ca_certs)
        return ctx.wrap_socket(
            sock,
            server_side=server_side,
            do_handshake_on_connect=do_handshake_on_connect,
            suppress_ragged_eofs=suppress_ragged_eofs,
        )
    ssl.wrap_socket = _wrap_socket
EOL
  echo "import fdc_ssl_compat" > "${py_site}/fdc_ssl_compat.pth"

  if ! python3 -c "import ssl; ssl.create_default_context(); assert callable(ssl.wrap_socket)"; then
    echo -e "${red}Failed to configure ssl compatibility shim${clear}"
    exit 1
  fi
}

configure_http_https() {
  if $ENABLE_HTTP_NATIVE; then
    systemctl disable --now apache2 nginx 2>/dev/null || true
    SERVICES+=("http_v2" "https_v2")
    return 0
  fi

  $ENABLE_HTTP_APACHE || return 0
  echo -e "${blue}Configuring Apache for the FDC web monitor...${clear}"

  mkdir -p /etc/apache2/ssl
  if [ ! -f /etc/apache2/ssl/server.crt ] || [ ! -f /etc/apache2/ssl/server.key ]; then
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
      -subj "/C=US/ST=California/L=Sunnyvale/O=IT/CN=web.local" \
      -keyout /etc/apache2/ssl/server.key \
      -out /etc/apache2/ssl/server.crt >/dev/null 2>&1
    chmod 600 /etc/apache2/ssl/server.key
  fi

  a2enmod ssl setenvif >/dev/null 2>&1
  if ! apache2ctl -S 2>/dev/null | grep -q ":443"; then
    cat > /etc/apache2/sites-available/fdc-default-ssl.conf <<'EOL'
<IfModule mod_ssl.c>
<VirtualHost *:443>
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile /etc/apache2/ssl/server.crt
    SSLCertificateKeyFile /etc/apache2/ssl/server.key
</VirtualHost>
</IfModule>
EOL
    a2ensite fdc-default-ssl >/dev/null 2>&1
  fi

  touch /var/log/linux_web.log /var/log/web.log
  chmod 644 /var/log/linux_web.log /var/log/web.log

  cat > /usr/local/bin/fdc_web_logger.py <<'EOL'
#!/usr/bin/env python3
import sys, json
from datetime import datetime

for line in sys.stdin:
    parts = line.rstrip("\r\n").split("\t")
    if len(parts) < 9:
        continue
    status, req, proto, user, r_ip, r_port, l_ip, l_port, ua = parts[:9]
    ts = datetime.now().strftime("%y%m%d %H:%M:%S")
    payload = json.dumps({
        "firstline": req,
        "service_type": proto if proto in ("http", "https") else "http",
        "user": "" if user == "-" else user,
        "pass": "",
        "remote_ip": r_ip,
        "remote_port": int(r_port) if r_port.isdigit() else 0,
        "local_ip": l_ip,
        "local_port": int(l_port) if l_port.isdigit() else 80,
        "User-Agent": "" if ua == "-" else ua
    }, separators=(",", ":"))
    record = f"[I {ts} web:2239] {status} {payload}\n"
    for path in ("/var/log/linux_web.log", "/var/log/web.log"):
        try:
            with open(path, "a", encoding="utf-8") as f:
                f.write(record)
        except OSError:
            pass
EOL
  chmod 755 /usr/local/bin/fdc_web_logger.py

  cat > /etc/apache2/conf-available/fdc-monitor.conf <<'EOL'
ServerName localhost
SetEnvIf Request_Protocol .* fdc_proto=http
SetEnvIfExpr "%{HTTPS} == 'on'" fdc_proto=https
LogFormat "%>s\t%r\t%{fdc_proto}e\t%u\t%a\t%{remote}p\t%A\t%p\t%{User-Agent}i" fdc_tsv_format
GlobalLog "|/usr/local/bin/fdc_web_logger.py" fdc_tsv_format
EOL
  a2enconf fdc-monitor >/dev/null 2>&1

  cat > /usr/local/bin/fdc_sync_ssl.sh <<'EOL'
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
  chmod 755 /usr/local/bin/fdc_sync_ssl.sh

  mkdir -p /etc/systemd/system/apache2.service.d
  cat > /etc/systemd/system/apache2.service.d/override.conf <<'EOL'
[Unit]
RefuseManualStop=yes
StartLimitIntervalSec=0

[Service]
ExecStartPre=/usr/local/bin/fdc_sync_ssl.sh
Restart=always
RestartSec=5
EOL

  cat > /etc/systemd/system/fdc-ssl-sync.service <<'EOL'
[Unit]
Description=Sync FortiDeceptor SSL certificate into Apache

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fdc_sync_ssl.sh
ExecStartPost=/bin/systemctl reload apache2.service
EOL

  cat > /etc/systemd/system/fdc-ssl-sync.path <<'EOL'
[Unit]
Description=Watch for FortiDeceptor SSL certificate deployment

[Path]
PathChanged=/usr/local/web/server.crt
PathChanged=/root/init/trapinit/event_tracers/decoy_common/extention_service/web/server.crt

[Install]
WantedBy=multi-user.target
EOL

  if ! apache2ctl configtest; then
    echo -e "${red}Invalid Apache configuration${clear}"
    exit 1
  fi
  systemctl daemon-reload
  systemctl enable apache2 fdc-ssl-sync.path >/dev/null 2>&1
  systemctl start apache2
  systemctl reload apache2
  SERVICES+=("http_v2")
  if apache2ctl -S 2>/dev/null | grep -q ":443"; then
    SERVICES+=("https_v2")
  fi
}

configure_builtin_services() {
  if $ENABLE_GIT; then
    SERVICES+=("git")
  fi
  if $ENABLE_SMTP; then
    systemctl disable --now postfix exim4 2>/dev/null || true
    SERVICES+=("smtp")
  fi
  if $ENABLE_FTP; then
    systemctl disable --now vsftpd proftpd 2>/dev/null || true
    SERVICES+=("ftp_v3")
  fi
  if $ENABLE_RADIUS; then
    systemctl disable --now freeradius 2>/dev/null || true
    SERVICES+=("radius")
  fi
  if $ENABLE_VNC; then
    SERVICES+=("vnc")
  fi
}

install_launcherD_service() {
cat >/usr/bin/launcherD.py <<'EOL'
#!/usr/bin/env python3
import json
import logging
import os
import traceback
from logging.handlers import RotatingFileHandler
from os import path
import shutil
import subprocess
import time


class LauncherD():
    def __init__(self):
        self.mount = "/mnt/init"
        self.dest = "/root/init"
        self.conf = None
        self.logger = None
        self.init_logger()

    def init_logger(self):
        self.logger = logging.getLogger(__name__)
        self.logger.setLevel(logging.DEBUG)
        handler = RotatingFileHandler("/tmp/launcherD.log", maxBytes=102400, backupCount=1)
        self.logger.addHandler(handler)

    def load_config(self):
        import sh
        try:
            sh.mount("/dev/cdrom", self.mount)
            if path.exists(self.dest):
                shutil.rmtree(self.dest)
            shutil.copytree(self.mount, self.dest)
            sh.umount(self.mount)
            self.logger.debug("got init files")
        except Exception:
            self.logger.error(traceback.format_exc())

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
            self.logger.info(self.conf)
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

services = sys.argv[1].split(",")
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
echo -e "${green}Registering services: ${servicestr}${clear}"
script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
if ! python3 /tmp/ubuntu_ready.py "${servicestr}" "${script_dir}"; then
  echo -e "${red}FDC notification failed${clear}"
  exit 1
fi
}

check_root
check_environment
configure_dns_and_syslog
configure_ssh
configure_samba
configure_ssl_compat
configure_http_https
configure_builtin_services
install_launcherD_service
prepare_base_image
notify_fdc