#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Запускай скрипт от root"
    exit 1
fi

########################################
# SETTINGS
########################################

read -rp "Введите домен (пример: test.root.ru): " DOMAIN

read -rp "Введите имя пользователя: " USERNAME

TIMEZONE="Europe/Moscow"

if [ -z "$DOMAIN" ]; then
    echo "Домен не указан"
    exit 1
fi

if [ -z "$USERNAME" ]; then
    echo "Имя пользователя не указано"
    exit 1
fi

########################################
# RANDOM PASSWORD
########################################

USERPASS=$(openssl rand -base64 18)

########################################
# UPDATE
########################################

apt update
apt -y upgrade
apt -y autoremove

########################################
# TIMEZONE
########################################

timedatectl set-timezone ${TIMEZONE}

########################################
# PACKAGES
########################################

apt install -y \
curl \
wget \
nano \
mc \
htop \
git \
sudo \
ufw \
socat \
dnsutils \
ca-certificates \
openssl \
libpam-google-authenticator

########################################
# USER
########################################

if ! id "${USERNAME}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${USERNAME}"
fi

echo "${USERNAME}:${USERPASS}" | chpasswd

usermod -aG sudo "${USERNAME}"

########################################
# DIRECTORIES
########################################

mkdir -p /opt/stacks
mkdir -p /opt/3x-ui
mkdir -p /opt/3x-ui/backup
mkdir -p /opt/portainer-cert

########################################
# DOCKER
########################################

for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt remove -y $pkg 2>/dev/null || true
done

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
-o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
> /etc/apt/sources.list.d/docker.list

apt update

apt install -y \
docker-ce \
docker-ce-cli \
containerd.io \
docker-buildx-plugin \
docker-compose-plugin

systemctl enable docker
systemctl start docker

usermod -aG docker "${USERNAME}"

########################################
# BBR
########################################

grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || cat >> /etc/sysctl.conf << EOF

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl -p

########################################
# SSH SOCKET
########################################

# Создаём drop-in директорию для переопределения порта
mkdir -p /etc/systemd/system/ssh.socket.d

cat > /etc/systemd/system/ssh.socket.d/port.conf << 'EOF'
[Socket]
ListenStream=
ListenStream=0.0.0.0:2233
ListenStream=[::]:2233
EOF

# Отключаем стандартный ssh.service, включаем сокет
systemctl stop ssh 2>/dev/null || true
systemctl disable ssh 2>/dev/null || true

systemctl daemon-reload
systemctl enable ssh.socket
systemctl restart ssh.socket

########################################
# PAM
########################################

cat > /etc/pam.d/sshd << 'EOF'
@include common-auth
auth required pam_google_authenticator.so
account required pam_nologin.so
@include common-account
@include common-session
@include common-password
EOF

########################################
# SSHD
########################################

cat > /etc/ssh/sshd_config << 'EOF'
Include /etc/ssh/sshd_config.d/*.conf

PermitRootLogin no
PasswordAuthentication yes

KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
UsePAM yes

AuthenticationMethods keyboard-interactive

X11Forwarding yes
PrintMotd no

AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

########################################
# UFW
########################################

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

ufw allow 2233/tcp comment 'SSH'
ufw allow 3322/tcp comment '3x-ui'
ufw allow 3333/tcp comment 'Subscription'
ufw allow 443/tcp comment 'VLESS'
ufw allow 9443/tcp comment 'Portainer'

ufw deny 80/tcp comment 'ACME'

ufw --force enable

########################################
# SSH RESTART (дополнительная проверка)
########################################

mkdir -p /run/sshd
chmod 755 /run/sshd

sshd -t || {
    echo "Ошибка в sshd_config"
    exit 1
}

# Перезапускаем сокет ещё раз на всякий случай
systemctl restart ssh.socket

########################################
# DNS CHECK
########################################

echo "Проверка DNS..."

SERVER_IP=$(curl -4 -s ifconfig.me)
DNS_IP=$(dig +short A ${DOMAIN} @8.8.8.8 | head -1)

if [ -z "$DNS_IP" ]; then
    echo "Не найдена A-запись для ${DOMAIN}"
    exit 1
fi

if [ "$SERVER_IP" != "$DNS_IP" ]; then
    echo "DNS указывает на $DNS_IP"
    echo "А сервер имеет IP $SERVER_IP"
    exit 1
fi

echo "DNS настроен корректно"

########################################
# ACME.SH
########################################

curl -fsSL https://get.acme.sh | sh

export PATH=$PATH:/root/.acme.sh

ufw allow 80/tcp

/root/.acme.sh/acme.sh \
--set-default-ca \
--server letsencrypt

/root/.acme.sh/acme.sh \
--issue \
-d ${DOMAIN} \
--standalone \
--keylength ec-256

/root/.acme.sh/acme.sh \
--install-cert \
-d ${DOMAIN} \
--ecc \
--key-file /opt/portainer-cert/privkey.pem \
--fullchain-file /opt/portainer-cert/fullchain.pem

ufw deny 80/tcp

########################################
# PORTAINER
########################################

mkdir -p /opt/stacks/portainer

cat > /opt/stacks/portainer/docker-compose.yml << 'EOF'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped

    command:
      - --sslcert
      - /certs/fullchain.pem
      - --sslkey
      - /certs/privkey.pem

    ports:
      - "9443:9443"

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
      - /opt/portainer-cert/fullchain.pem:/certs/fullchain.pem:ro
      - /opt/portainer-cert/privkey.pem:/certs/privkey.pem:ro

volumes:
  portainer_data:
EOF

cd /opt/stacks/portainer
docker compose up -d

########################################
# WATCHTOWER
########################################

mkdir -p /opt/stacks/watchtower

cat > /opt/stacks/watchtower/docker-compose.yml << 'EOF'
services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower

    restart: unless-stopped

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

    environment:
      - DOCKER_API_VERSION=1.47

    command:
      - --cleanup
      - --interval
      - "86400"
EOF

cd /opt/stacks/watchtower
docker compose up -d

########################################
# 3x-ui
########################################

mkdir -p /opt/stacks/3x-ui

cat > /opt/stacks/3x-ui/docker-compose.yml << 'EOF'
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    restart: unless-stopped

    network_mode: host

    environment:
      - TZ=Europe/Moscow
      - ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
      - ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true

    volumes:
      - /opt/3x-ui/db:/etc/x-ui
      - /opt/portainer-cert/fullchain.pem:/root/cert/fullchain.pem:ro
      - /opt/portainer-cert/privkey.pem:/root/cert/privkey.pem:ro

EOF

cd /opt/stacks/3x-ui
docker compose up -d

########################################
# BACKUP
########################################

cat > /opt/3x-ui/backup.sh << 'EOF'
#!/bin/bash

DATE=$(date +%F-%H-%M)

mkdir -p /opt/3x-ui/backup

tar \
--exclude='/opt/3x-ui/backup' \
-czf /opt/3x-ui/backup/3x-ui-${DATE}.tar.gz \
/opt/3x-ui \
/opt/portainer-cert \
/opt/stacks \
/etc/ssh

find /opt/3x-ui/backup -type f -name "*.tar.gz" -mtime +14 -delete
EOF

chmod +x /opt/3x-ui/backup.sh

########################################
# SSL RENEW
########################################

cat > /usr/local/bin/ssl-renew.sh << 'EOF'
#!/bin/bash

ufw allow 80/tcp

/root/.acme.sh/acme.sh \
  --cron \
  --home /root/.acme.sh

ufw deny 80/tcp

NEWCERT=$(find /opt/portainer-cert/fullchain.pem -mtime -1)

if [ -n "$NEWCERT" ]; then
    docker restart portainer >/dev/null 2>&1
    docker restart 3x-ui >/dev/null 2>&1
fi
EOF

chmod +x /usr/local/bin/ssl-renew.sh

########################################
# CRON
########################################

(
crontab -l 2>/dev/null | grep -v 'backup.sh' | grep -v 'ssl-renew.sh'

echo '15 4 * * * /opt/3x-ui/backup.sh'
echo '58 3 * * * /usr/local/bin/ssl-renew.sh >/dev/null 2>&1'

) | crontab -

########################################
# INFO
########################################

echo
echo "BBR:"
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_available_congestion_control
echo
echo
echo
echo "===================================="
echo "Установка завершена"
echo "Выполнять по шагам"
echo "https://github.com/vanuska/3x-UI-auto-install"
echo "===================================="
echo
echo "Backup здесь: /opt/3x-ui/backup"
echo
echo "Пользователь: ${USERNAME}"
echo "Пароль: ${USERPASS}"
echo
echo "Проверь вход по SSH в отдельном окне:"
echo "ssh -p 2233 ${USERNAME}@SERVER_IP"
echo
echo "Настройка Portainer:"
echo "https://${DOMAIN}:9443"
echo "Выполни перезапуск docker restart portainer"
echo
echo "Смени пароль:"
echo "su ${USERNAME}" 
echo "passwd ${USERPASS}"
echo
echo "Включи 2FA от имени ${USERNAME}:"
echo "google-authenticator"
echo
echo "Начальная настройка 3x-ui:"
echo "docker exec -it 3x-ui sh"
echo "x-ui"
echo "Пункты меню:" 
echo "6. Reset Username & Password"
echo "7. Reset Web Base Path"                       
echo "10. Change port"
echo
echo "Первый раз заходим но http и IP"
echo "http://SERVER_IP:3322/из п.7. Reset Web Base Path"
echo
echo "Устанавливаем сертификаты панели и подписки:"
echo "Certificate: /root/cert/fullchain.pem"
echo "Private Key: /root/cert/privkey.pem"
echo
echo "Меняем порт подписки на 3333 и URI-путь на свой"
echo 
echo "После выбора нажать СОХРАНИТЬ и Перезапустить панель"
echo "https://${DOMAIN}:2233/из п.7. Reset Web Base Path"
echo
echo "Stack 3x-ui создан скриптом у него control Limited т.е. через SSH"
echo "Для control Total нужно удалить и передобаить Stacks, данные сохранятся" 
echo "cat /opt/stacks/3x-ui/docker-compose.yml копируем содержимое"
echo "cd /opt/stacks/3x-ui docker compose down"
echo "Stacks → Add stack → 3x-ui"
echo "со Stack Watchtower по аналогии," 
echo "можно отключить для контролируемого обновления"
echo
echo
