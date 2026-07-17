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
# ВЫБОР ТИПА УСТАНОВКИ PORTAINER
########################################

echo
echo "Выберите тип установки Portainer:"
echo "  1) Полноценный сервер (Portainer CE с веб-интерфейсом)"
echo "  2) Edge Agent Standard (постоянный туннель)"
echo "  3) Edge Agent Async (периодическая синхронизация)"
echo "  4) Agent (legacy, подключение по HTTP/HTTPS)"
echo "  5) API (подключение через Docker API, без агента)"
echo "  6) Socket (подключение через локальный Docker-сокет, без агента)"
read -rp "Введите номер (1-6): " PORTAINER_TYPE

case $PORTAINER_TYPE in
    1)
        PORTAINER_MODE="server"
        ;;
    2)
        PORTAINER_MODE="edge_standard"
        ;;
    3)
        PORTAINER_MODE="edge_async"
        ;;
    4)
        PORTAINER_MODE="agent_legacy"
        ;;
    5)
        PORTAINER_MODE="api"
        ;;
    6)
        PORTAINER_MODE="socket"
        ;;
    *)
        echo "Неверный выбор, установка по умолчанию: полноценный сервер"
        PORTAINER_MODE="server"
        ;;
esac

# Для агентов запрашиваем дополнительные параметры
if [[ "$PORTAINER_MODE" == "edge_standard" || "$PORTAINER_MODE" == "edge_async" || "$PORTAINER_MODE" == "agent_legacy" ]]; then
    read -rp "Введите адрес Portainer-сервера (например, portainer.example.com или IP): " PORTAINER_SERVER
    read -rp "Введите ключ/токен для агента: " PORTAINER_TOKEN
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
# SSH SOCKET (исправлено: используем drop-in)
########################################

mkdir -p /etc/systemd/system/ssh.socket.d

cat > /etc/systemd/system/ssh.socket.d/port.conf << 'EOF'
[Socket]
ListenStream=
ListenStream=0.0.0.0:2233
ListenStream=[::]:2233
EOF

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
# SSH RESTART
########################################

mkdir -p /run/sshd
chmod 755 /run/sshd

sshd -t || {
    echo "Ошибка в sshd_config"
    exit 1
}

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
# ACME.SH (сертификаты для 3x-ui и Portainer)
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
# УСТАНОВКА PORTAINER (в зависимости от выбора)
########################################

case $PORTAINER_MODE in
    server)
        echo "Устанавливаем полноценный Portainer CE (сервер)..."

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

        PORTAINER_URL="https://${DOMAIN}:9443"
        ;;

    edge_standard|edge_async)
        echo "Устанавливаем Edge Agent..."

        # Для edge-агентов используем образ portainer/agent:latest
        # Дополнительные параметры: --edge-server-url и --edge-key
        # Для async добавляем --edge-async
        EDGE_FLAGS="--edge-server-url wss://${PORTAINER_SERVER} --edge-key ${PORTAINER_TOKEN}"
        if [ "$PORTAINER_MODE" = "edge_async" ]; then
            EDGE_FLAGS="$EDGE_FLAGS --edge-async"
        fi

        docker run -d \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v /var/lib/docker/volumes:/var/lib/docker/volumes \
            -v /:/host \
            -v portainer_agent_data:/data \
            --restart always \
            --name portainer_edge_agent \
            portainer/agent:latest \
            $EDGE_FLAGS

        PORTAINER_URL="Edge Agent (${PORTAINER_MODE}) подключен к ${PORTAINER_SERVER}"
        ;;

    agent_legacy)
        echo "Устанавливаем классический Agent (legacy)..."

        # Для legacy агента используем порт 9001 (если нужно, можно открыть в UFW)
        # Команда запуска: docker run -d -p 9001:9001 -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker/volumes:/var/lib/docker/volumes --restart always --name portainer_agent portainer/agent:latest --portainer-server-url http://${PORTAINER_SERVER}:9000
        # Но так как сервер может быть на HTTPS, лучше спросить протокол, но для простоты оставим как есть.
        docker run -d \
            -p 9001:9001 \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v /var/lib/docker/volumes:/var/lib/docker/volumes \
            --restart always \
            --name portainer_agent \
            portainer/agent:latest \
            --portainer-server-url http://${PORTAINER_SERVER}:9000

        # Если нужно открыть порт 9001 в UFW:
        ufw allow 9001/tcp comment 'Portainer Agent'

        PORTAINER_URL="Legacy Agent подключен к ${PORTAINER_SERVER}:9000"
        ;;

    api)
        echo "Выбран режим API. Установка агента не требуется."
        echo "Для подключения к этой среде через Portainer используйте Docker API."
        echo "Убедитесь, что Docker API доступен (обычно tcp://<IP>:2375) и защищён."
        PORTAINER_URL="Подключение через API (инструкция выше)"
        ;;

    socket)
        echo "Выбран режим Socket. Установка агента не требуется."
        echo "Для подключения к этой среде через Portainer используйте локальный Docker-сокет."
        echo "Этот метод подходит, если Portainer запущен на том же хосте."
        PORTAINER_URL="Подключение через локальный сокет"
        ;;

    *)
        echo "Неизвестный режим, пропускаем установку Portainer"
        PORTAINER_URL="Не установлен"
        ;;
esac

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
# SSL RENEW SCRIPT
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
    docker restart portainer 2>/dev/null || true
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
echo "===================================="
echo
echo "Пользователь: ${USERNAME}"
echo "Пароль: ${USERPASS}"
echo
echo "Portainer:"
echo "${PORTAINER_URL}"
if [ "$PORTAINER_MODE" = "server" ]; then
    echo "Выполни перезапуск docker restart portainer (если нужно)"
fi
echo
echo "Проверь вход по SSH в отдельном окне:"
echo "ssh -p 2233 ${USERNAME}@SERVER_IP"
echo
echo "Смени пароль:"
echo "su ${USERNAME}"
echo "passwd - см. сгенерированный выше пароль"
echo
echo "Включи 2FA от Яндекс, Google, MS:"
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
echo "3x-ui:"
echo "Первый раз заходим по http и IP"
echo "http://SERVER_IP:3322/из п.7. Reset Web Base Path"
echo
echo "Устанавливаем сертификаты панели и подписки:"
echo "Certificate: /root/cert/fullchain.pem"
echo "Private Key: /root/cert/privkey.pem"
echo
echo "Меняем порт подписки на 3333 и URI-путь на свой"
echo
echo "После выбора нажать СОХРАНИТЬ и Перезапустить панель"
echo "https://${DOMAIN}:9443/из п.7. Reset Web Base Path"
echo
echo "Stack 3x-ui создан скриптом у него control Limited т.е. через SSH"
echo "Для control Total нужно удалить и передобаить Stacks, данные сохранятся"
echo "cat /opt/stacks/3x-ui/docker-compose.yml копируем содержимое"
echo "cd /opt/stacks/3x-ui docker compose down"
echo "Stacks → Add stack → 3x-ui"
echo "со Stack Watchtower по аналогии"
echo
echo
