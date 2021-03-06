#!/bin/bash
# OpenVPN server deployment with optional ad blocking functionality using CentOS 8

domain="example.com" # FQDN of the server
dns="1.1.1.1 1.0.0.1" # List of nameservers to be used
adblock="yes" # Change to anything but "yes" if ad blocking is not preferred

# Disable as much logging as possible
systemctl disable rsyslog systemd-journald systemd-journald.socket --now

cat ./Configs/rsyslog-systemd.conf >/etc/rsyslog.conf
rm -rf /etc/rsyslog.d/*

find /var/log/ -type f -name "*" -exec truncate -s 0 {} +

while IFS= read -r -d '' log
do
  ln -sfn /dev/null "$log"
done< <(find /var/log/ -type f -name "*" -print0)

cat ./Configs/dev-null.service >/etc/systemd/system/dev-null.service

# Install packages
yum install openvpn easy-rsa mailx dnsmasq -y

# Disable bash history saving
sed -i -e "s/HISTFILESIZE=.*/HISTFILESIZE=0/g" /root/.bashrc /etc/skel/.bashrc
for dir in /home/*
do
  [[ -d "$dir" ]] || break
  sed -i -e "s/HISTFILESIZE=.*/HISTFILESIZE=0/g" "$dir"/.bashrc
done

# Configure dnsmasq
cat ./Configs/dnsmasq.conf >/etc/dnsmasq.conf
for ip in $dns; do
  echo "server=$ip" >>/etc/dnsmasq.conf
done
nmcli con mod "System eth0" ipv4.dns "127.0.0.1"

# Configure easy-rsa
mkdir -p /etc/easy-rsa
cp -r /usr/share/easy-rsa/3.0.*/* /etc/easy-rsa

# Generate Diffie Hellman & HMAC
mkdir -p /etc/openvpn/server
openssl dhparam -out /etc/openvpn/server/dh.pem 2048
openvpn --genkey --secret /etc/openvpn/server/ta.key

# Initialise PKI
cat ./Configs/vars >/etc/easy-rsa/vars
( cd /etc/easy-rsa || return
source ./vars
./easyrsa init-pki

# Generate ca
./easyrsa build-ca nopass
cp /etc/easy-rsa/pki/ca.crt /etc/openvpn/server

# Generate & sign server cert
./easyrsa gen-req vpn-server nopass
./easyrsa sign-req server vpn-server
cp /etc/easy-rsa/pki/private/vpn-server.key /etc/openvpn/server/
cp /etc/easy-rsa/pki/issued/vpn-server.crt /etc/openvpn/server/ )

# Enable ip forwarding & firewall hardening rules
echo "net.ipv4.ip_forward = 1" >/etc/sysctl.conf
cat ./Configs/iptables-config >/etc/sysconfig/iptables-config
modprobe iptable_nat
echo 1 | tee /proc/sys/net/ipv4/ip_forward

# For dnsmasq
firewall-cmd --permanent --zone=trusted --add-interface=tun0
firewall-cmd --permanent --zone=trusted --add-interface=tun1

# For openvpn - eth0 or main external interface should be in the DROP zone
firewall-cmd --permanent --zone=drop --add-port=443/tcp
firewall-cmd --permanent --zone=drop --add-port=1194/udp
firewall-cmd --permanent --zone=drop --add-service openvpn
firewall-cmd --permanent --zone=drop --add-masquerade
interface=$(ip route get 1.1.1.1 | awk 'NR==1 {print $(NF-2)}')
firewall-cmd --permanent --zone=drop --direct --passthrough ipv4 -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$interface" -j MASQUERADE
firewall-cmd --permanent --zone=drop --direct --passthrough ipv4 -t nat -A POSTROUTING -s 10.8.1.0/24 -o "$interface" -j MASQUERADE
firewall-cmd --reload

# Openvpn conifguration - Use UDP 1194 mainly but TCP 443 is good for restrictive newtorks. Looking at you, free wifi.
cat ./Configs/server.conf >/etc/openvpn/server/tcpserver.conf
cat ./Configs/server.conf >/etc/openvpn/server/udpserver.conf
sed -i -e " s/port\ .*/port\ 1194/g
            s/proto\ .*/proto\ udp4/g
            s/dev\ .*/dev\ tun1/g
            s/10.8.0/10.8.1/g " \
            /etc/openvpn/server/udpserver.conf

# Client .ovpn profile
mkdir -p /etc/openvpn/template-profiles
mkdir -p /etc/openvpn/client-profiles
cat ./Configs/profile.ovpn >/etc/openvpn/template-profiles/profile.ovpn
sed -i -e "s/\$domain/""$domain""/g" /etc/openvpn/template-profiles/profile.ovp

# Copy cert & ovpn profile generator script
cat ./Configs/gen-ovpn >/usr/local/bin/gen-ovpn
chmod +x /usr/local/bin/gen-ovpn

# ADBLOCK SECTION
if [[ $adblock == "yes" ]]; then
  # Install and configure pixelserv
  cat ./Configs/pixelserv.pl >/usr/local/bin/pixelserv.pl
  cat ./Configs/pixelserv.service >/etc/systemd/system/pixelserv.service

  # Setup blocklist update script
  cat ./Configs/adblock.sh >/usr/local/bin/adblock.sh
  cat ./Configs/adblock.service >/etc/systemd/system/adblock.service
  cat ./Configs/adblock.timer >/etc/systemd/system/adblock.timer
  chmod +x /usr/local/bin/pixelserv.pl /usr/local/bin/adblock.sh
  /usr/local/bin/adblock.sh
  systemctl enable adblock.timer --now
  echo "conf-file=/etc/dnsmasq.adblock" >> /etc/dnsmasq/dnsmasq.conf
fi
# END ABLOCK SECTION

# Enable and start everything
systemctl restart NetworkManager
systemctl enable  openvpn-server@tcpserver \
                  openvpn-server@udpserver \
                  dev-null \
                  dnsmasq \
                  pixelserv --now

# Just in case dnsmasq starts up too soon and can't listen on the VPN addresses
systemctl restart dnsmasq

# OPTIONAL - Run:
# systemctl edit --full dnsmasq
#
# Add the following lines to [Service]:
# Restart=on-failure
# RestartSec=5s

# TODO
# Create script for on-demand revocation
# cd /etc/easy-rsa
# ./easyrsa revoke $VPNCLIENT
# ./easyrsa gen-crl
# cp /etc/easy-rsa/pki /etc/openvpn/server/
# sed -i -e "s/.*crl-verify.*/crl-verify\ \/etc\/openvpn\/server\/crl.pem/g"/etc/openvpn/server/server.conf

printf "Setup complete.\n"
