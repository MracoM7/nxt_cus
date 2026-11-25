sudo su

mkdir /tmp/mount /tmp/cus

mount /dev/sr1 /tmp/mount

cp -R /tmp/mount/* /tmp/cus

cd /tmp/cus/Ubuntu

bash set_network.sh

apt install git

git clone https://github.com/MracoM7/nxt_cus

cp ./nxt_cus/* ./

bash ./install_ubuntu_modules_nxt.sh

bash ./ubuntu_cus_toolkit_nxt.sh

bash ./decoy_finalize_nxt.sh

trap - DEBUG; history -c && history -w && shutdown -h now

FROM FortiDeceptor GUI: Save
