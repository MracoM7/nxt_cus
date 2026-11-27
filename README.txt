sudo su

mkdir /tmp/mount /tmp/cus

mount /dev/sr1 /tmp/mount

cp -R /tmp/mount/* /tmp/cus

cd /tmp/cus/Ubuntu

bash set_network.sh

apt install git

git clone https://github.com/MracoM7/nxt_cus

cp ./nxt_cus/* ./

# Fresh install only (skip when re-customizing the BASE image)
bash ./install_ubuntu_modules_nxt.sh

# BASE image: all standard services (defaults)
bash ./ubuntu_cus_toolkit_nxt.sh

# Derived image from BASE: override flags from the environment, e.g. WordPress on Apache
#   ENABLE_HTTP_NATIVE=false ENABLE_HTTP_APACHE=true bash ./ubuntu_cus_toolkit_nxt.sh
# Install WordPress in /var/www/html BEFORE running it: the login hook is added automatically.

bash ./decoy_finalize_nxt.sh

trap - DEBUG; history -c && history -w && shutdown -h now

FROM FortiDeceptor GUI: Save
