#!/bin/bash
# OpenVPN server deployment using Amazon Linux

# FQDN of the server
domain="example.com"
# List of user accounts to create

# Disable as much logging as possible
cat ./Configs/rsyslog-systemd.conf >/etc/rsyslog.conf
rm -rf /etc/rsyslog.d/*
ln -sfn /dev/null /var/log/lastlog
ln -sfn /dev/null /var/log/wtmp
ln -sfn /dev/null /var/log/audit/audit.log

# Install packages
yum install wget -y
( cd /tmp || return
wget http://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
yum install /tmp/epel-release-latest-7.noarch.rpm -y
yum install openvpn easy-rsa mailx -y

# Disable bash history saving
sed -i -e "s/HISTFILESIZE=.*/HISTFILESIZE=0/g" /root/.bashrc /etc/skel/.bashrc
for dir in $(ls -d /home/*)
do
    sed -i -e "s/HISTFILESIZE=.*/HISTFILESIZE=0/g" $dir/.bashrc
done

# Use Cloudflare DNS
sed -i -e "s/dns-nameservers.*/dns-nameservers\ \ 1.1.1.1\ 1.0.0.1/g" /etc/network/interfaces

# Configure easy-rsa
mkdir -p /etc/easy-rsa
cp -r /usr/share/easy-rsa/3.0.*/* /etc/easy-rsa

# Generate Diffie Hellman & HMAC
mkdir -p /etc/openvpn/server
openssl dhparam -out /etc/openvpn/server/dh.pem 2048
openvpn --genkey --secret /etc/openvpn/server/ta.key

# Initialise PKI
( cd /etc/easy-rsa || return
cat ./Configs/vars >./vars
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

firewall-cmd --permanent --zone=drop --add-service openvpn
firewall-cmd --permanent --zone=drop --add-masquerade
interface=$(ip route get 8.8.8.8 | awk 'NR==1 {print $(NF-2)}')
firewall-cmd --permanent --zone=drop --direct --passthrough ipv4 -t nat -A POSTROUTING -s 10.8.0.0/24 -o $interface -j MASQUERADE
firewall-cmd --permanent --zone=drop --direct --passthrough ipv4 -t nat -A POSTROUTING -s 10.8.1.0/24 -o $interface -j MASQUERADE
firewall-cmd --reload

# Openvpn conifguration
cat ./Configs/tcpserver.conf >/etc/openvpn/tcpserver.conf
cat ./Configs/udpserver.conf >/etc/openvpn/udpserver.conf

# Client .ovpn profile
mkdir -p /etc/openvpn/template-profiles
mkdir -p /etc/openvpn/client-profiles
cat ./Configs/profile.ovpn >/etc/openvpn/template-profiles/profile.ovpn
sed -i -e "s/\$domain/""$domain""/g" /etc/openvpn/template-profiles/profile.ovpn

# Copy cert & ovpn profile generator script
cat ./Configs/gen-ovpn >/usr/local/bin/gen-ovpn
chmod +x /usr/local/bin/gen-ovpn

# Start and enable openvpn
systemctl restart network
systemctl enable openvpn@server --now

# Truncate all log files
find /var/log/ -type f -name "*" -exec truncate -s 0 {} +

# TODO
# Create script for on-demand revocation
# cd /etc/easy-rsa
# ./easyrsa revoke $VPNCLIENT
# ./easyrsa gen-crl
# cp /etc/easy-rsa/pki /etc/openvpn/server/
# sed -i -e "s/.*crl-verify.*/crl-verify\ \/etc\/openvpn\/server\/crl.pem/g"/etc/openvpn/server/server.conf

printf "Setup complete.\n"
