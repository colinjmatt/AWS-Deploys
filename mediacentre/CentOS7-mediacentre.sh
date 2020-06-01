#!/bin/bash
# Media server deployment using Digital Ocean CentOS 7
# Also tested on Amazon Linux 2

# FQDN of the server
domain="example.com"
# Password for transmission rpc
transmissionpass="password"
# Location of completed downloads
downcomplete="\/downloads\/complete"
downcompletesed=$(echo $downcomplete | sed 's/\//\\\//g')
#Location of incomplete downloads
downincomplete="\/downloads\/incomplete"
downincompletesed=$(echo $downincomplete | sed 's/\//\\\//g')

# Create download directories
mkdir -p $downcomplete
chmod -R 0777 $downcomplete
mkdir -p $downincomplete
chmod -R 0777 $downincomplete

# Create service users
users="sonarr radarr jackett"
for name in $users ; do
    groupadd -r "$name"
    useradd -m -r -g "$name" -d /var/lib/"$name" "$name"
    chown -R "$name":"$name" /var/lib/"$name"
done

# Use Cloudflare DNS
sed -i -e "s/dns-nameservers.*/dns-nameservers\ \ 1.1.1.1\ 1.0.0.1/g" /etc/network/interfaces

# Add firewall rules & configure selinux
ports="80 443 9091 32400 55369" # port 9091 only if a client is to be used to access transmission
for port in $ports; do
    firewall-cmd --permanent --zone=drop --add-port="$port"/tcp
done
firewall-cmd --reload

setsebool -P httpd_can_network_connect 1

# Enable epel
yum install wget -y
( cd /tmp || return
wget http://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
yum install /tmp/epel-release-latest-7.noarch.rpm -y

# Install rar/unrar
wget  https://rarlab.com/rar/rarlinux-x64-5.7.1.tar.gz
tar -zxf rarlinux-x64-5.7.1.tar.gz )
cp /tmp/rar/rar /tmp/rar/unrar /usr/local/bin

# Install & configure nginx with certbot certs
yum install nginx certbot -y
mkdir -p /usr/share/nginx/html/.well-known
mkdir -p /etc/nginx/sites
cat ./Configs/nginx.conf >/etc/nginx/nginx.conf
cat ./Configs/pre-certbot.conf >/etc/nginx/sites/download.conf
sed -i -e "s/\$domain/""$domain""/g" /etc/nginx/sites/download.conf
systemctl enable nginx --now
certbot certonly --agree-tos --register-unsafely-without-email --webroot -w /usr/share/nginx/html -d "$domain"
cat ./Configs/post-certbot.conf >/etc/nginx/sites/download.conf
sed -i -e "s/\$domain/""$domain""/g" /etc/nginx/sites/download.conf
cat ./Configs/certbot-auto >/usr/local/bin/certbot-auto
echo "@daily root /usr/local/bin/certbot-auto >/dev/null 2>&1" >/etc/cron.d/certbot

# Install & configure transmission-daemon
yum install transmission-daemon -y
mkdir -p /var/lib/transmission/.config/transmission-daemon/
cat ./Configs/settings.json >/var/lib/transmission/.config/transmission-daemon/settings.json
sed -i -e " s/\$downcompletesed/""$downcompletesed""/g
            s/\$downincompletesed/""$downincompletesed""/g
            s/\$transmissionpass/""$transmissionpass""/g" \
            /var/lib/transmission/.config/transmission-daemon/settings.json
chown -R transmission:transmission /var/lib/transmission/
cat ./Configs/download-unrar.sh >/usr/local/bin/download-unrar.sh

# Setup cleanup of transmission downloads
cat ./Configs/download-cleanup.sh >/usr/local/bin/download-cleanup.sh
echo "@daily root /usr/local/bin/download-cleanup.sh >/dev/null 2>&1" >/etc/cron.d/download-cleanup

# Get required packages with a more recent version of mono
rpm --import "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF"
curl https://download.mono-project.com/repo/centos7-stable.repo | tee /etc/yum.repos.d/mono-centos7-stable.repo
yum install mono-complete mediainfo libicu libcurl-devel bzip2 -y

# Install Plex
bash -c "$(wget -qO - https://raw.githubusercontent.com/mrworf/plexupdate/master/extras/installer.sh)"

# Install & configure sonarr
( cd /tmp || return
wget http://download.sonarr.tv/v2/master/mono/NzbDrone.master.tar.gz
tar -zxf /tmp/NzbDrone.master.tar.gz -C /opt/ )
mv /opt/NzbDrone /opt/nzbdrone
cat ./Configs/sonarr.service >/etc/systemd/system/sonarr.service
mkdir -p /var/lib/sonarr/.config/NzbDrone/
echo -e "<Config>\n  <UrlBase>/sonarr</UrlBase>\n</Config>" >/var/lib/sonarr/.config/NzbDrone/config.xml
chown -R sonarr:sonarr /opt/nzbdrone /var/lib/sonarr

# Install and configure radarr
( cd /tmp || return
curl -s https://api.github.com/repos/Radarr/Radarr/releases | grep "browser_download_url".*Radarr.develop.*linux.tar.gz | head -1 | cut -d : -f 2,3 | tr -d \" | wget -i-
tar -zxf Radarr.develop.0.2.0.1344.linux.tar.gz -C /opt/ )
mv /opt/Radarr /opt/radarr
cat ./Configs/radarr.service >/etc/systemd/system/radarr.service
mkdir -p /var/lib/radarr/.config/Radarr
echo -e "<Config>\n  <UrlBase>/radarr</UrlBase>\n</Config>" >/var/lib/radarr/.config/Radarr/config.xml
chown -R radarr:radarr /opt/radarr /var/lib/radarr

# Install & configure jackett
( cd /tmp || return
curl -s https://api.github.com/repos/Jackett/Jackett/releases | grep "browser_download_url".*Jackett.Binaries.LinuxAMDx64.tar.gz | head -1 | cut -d : -f 2,3 | tr -d \" | wget -i-
tar -zxf Jackett.Binaries.LinuxAMDx64.tar.gz -C /opt/ )
mv /opt/Jackett /opt/jackett
cat ./Configs/jackett.service >/etc/systemd/system/jackett.service
mkdir -p /var/lib/jackett/.config/Jackett
echo -e "{\n  \"BasePathOverride\": \"/jackett\"\n}" >/var/lib/jackett/.config/Jackett/ServerConfig.json
chown -R jackett:jackett /opt/jackett /var/lib/jackett

# Everything in /usr/local/bin made to be executable
chmod +x /usr/local/bin/*

# Start services
systemctl restart network \
                  nginx
systemctl enable  transmission-daemon \
                  sonarr \
                  radarr \
                  jackett --now

printf "Setup complete.\n"
