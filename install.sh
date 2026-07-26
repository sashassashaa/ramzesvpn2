#!/bin/bash
set -e

# ═══════════════════════════════════════════════════════════
# 🚀 RAMZES VPN — ПОЛНАЯ УСТАНОВКА ПОД КЛЮЧ v2.0
# ═══════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[ℹ]${NC} $1"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

[ "$EUID" -ne 0 ] && err "Запусти от root: sudo bash install.sh"

IP=$(curl -s4 ifconfig.me)
START_TIME=$(date +%s)
GITHUB_RAW="https://raw.githubusercontent.com/sashassashaa/ramzesvpn2/main"

clear
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║     🚀 RAMZES VPN — УСТАНОВЩИК v2.0     ║"
echo "║     RemnaWave + Hysteria2 + Telegram     ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "🌍 IP: ${CYAN}$IP${NC}"
echo -e "📦 Debian 12 • 2 vCPU • 2+ GB RAM"
echo ""

# ═══════════════════════════════════════════════════════════
step "📋 ШАГ 1/7: СИСТЕМА"
# ═══════════════════════════════════════════════════════════
info "Обновление пакетов..."
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget git unzip nginx python3 python3-venv python3-pip openssl cron ufw sshpass certbot
log "Система готова"

# ═══════════════════════════════════════════════════════════
step "🐳 ШАГ 2/7: DOCKER"
# ═══════════════════════════════════════════════════════════
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi
apt install -y -qq docker-compose-plugin
log "Docker готов"

# ═══════════════════════════════════════════════════════════
step "🔐 ШАГ 3/7: ДОМЕН + SSL"
# ═══════════════════════════════════════════════════════════
echo ""
read -p "🌐 Домен (Enter для ramzesvpnbot.duckdns.org): " DOMAIN
DOMAIN=${DOMAIN:-ramzesvpnbot.duckdns.org}

if [[ "$DOMAIN" == *"duckdns"* ]]; then
    read -p "🔑 Токен DuckDNS: " DUCKDNS_TOKEN
    mkdir -p /opt/duckdns
    cat > /opt/duckdns/update.sh << EOF
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=${DOMAIN%%.*}&token=$DUCKDNS_TOKEN&ip=" | curl -k -o /opt/duckdns/duck.log -K -
EOF
    chmod +x /opt/duckdns/update.sh
    /opt/duckdns/update.sh
    (crontab -l 2>/dev/null; echo "*/5 * * * * /opt/duckdns/update.sh") | crontab -
    log "DuckDNS: $DOMAIN"
fi

info "SSL-сертификат..."
systemctl stop nginx 2>/dev/null
certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "admin@$DOMAIN" 2>/dev/null || {
    warn "Самоподписанный SSL..."
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/panel.key -out /etc/nginx/ssl/panel.crt -subj "/CN=$DOMAIN"
}
systemctl start nginx
log "SSL готов"

# ═══════════════════════════════════════════════════════════
step "🎛️ ШАГ 4/7: REMNAWAVE"
# ═══════════════════════════════════════════════════════════
mkdir -p /opt/remnawave && cd /opt/remnawave

DB_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
JWT_SECRET=$(openssl rand -base64 64 | tr -d '/+=' | head -c 64)
APP_SECRET=$(openssl rand -base64 64 | tr -d '/+=' | head -c 64)
METRICS_PASS=$(openssl rand -base64 12 | tr -d '/+=' | head -c 12)

cat <<COMPOSE > docker-compose.yml
services:
  postgres:
    image: postgres:16
    container_name: rw-db
    restart: always
    environment:
      POSTGRES_USER: remnawave
      POSTGRES_PASSWORD: $DB_PASS
      POSTGRES_DB: remnawave
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U remnawave"]
      interval: 5s; timeout: 5s; retries: 10

  redis:
    image: redis:7-alpine
    container_name: rw-redis
    restart: always
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s; timeout: 5s; retries: 10

  remnawave:
    image: ghcr.io/remnawave/backend:latest
    container_name: remnawave
    restart: always
    ports: ["127.0.0.1:3000:3000"]
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
    environment:
      NODE_ENV: production; PORT: 3000
      DATABASE_URL: "postgresql://remnawave:$DB_PASS@postgres:5432/remnawave"
      REDIS_HOST: redis; REDIS_PORT: 6379
      JWT_SECRET: "$JWT_SECRET"; APP_SECRET: "$APP_SECRET"
      FRONT_END_DOMAIN: "https://$DOMAIN"; SUB_PUBLIC_DOMAIN: "$DOMAIN"
      METRICS_USER: admin; METRICS_PASS: "$METRICS_PASS"
      NODE_TLS_REJECT_UNAUTHORIZED: "0"

volumes: {pgdata:}
COMPOSE

docker compose pull -q && docker compose up -d

for i in {1..60}; do
    curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000 2>/dev/null | grep -q "200\|302\|401" && { log "Панель запущена (${i}с)"; break; }
    sleep 1
done

cat <<NGINX > /etc/nginx/sites-available/remnawave
server { listen 80; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl http2; server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/remnawave /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
log "Панель: https://$DOMAIN"

# ═══════════════════════════════════════════════════════════
step "⚡ ШАГ 5/7: HYSTERIA2"
# ═══════════════════════════════════════════════════════════
mkdir -p /opt/hysteria2 && cd /opt/hysteria2
curl -sLO https://github.com/apernet/hysteria/releases/download/app/v2.6.1/hysteria-linux-amd64
mv hysteria-linux-amd64 hysteria2 && chmod +x hysteria2

HY_PASS=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)
openssl req -x509 -nodes -days 365 -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout private.key -out cert.crt -subj "/CN=www.google.com" 2>/dev/null

cat <<HY > config.yaml
listen: :443
tls: {cert: /opt/hysteria2/cert.crt, key: /opt/hysteria2/private.key}
auth: {type: password, password: $HY_PASS}
masquerade: {type: proxy, proxy: {url: https://www.google.com, rewriteHost: true}}
quic: {initStreamReceiveWindow: 8388608, maxStreamReceiveWindow: 8388608, initConnReceiveWindow: 20971520, maxConnReceiveWindow: 20971520}
HY

cat <<SVC > /etc/systemd/system/hysteria2.service
[Unit]
Description=Hysteria2
After=network.target
[Service]
Type=simple
ExecStart=/opt/hysteria2/hysteria2 server -c /opt/hysteria2/config.yaml
Restart=always
[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload && systemctl enable --now hysteria2
log "Hysteria2 запущен"

# ═══════════════════════════════════════════════════════════
step "🤖 ШАГ 6/7: ТЕЛЕГРАМ БОТ"
# ═══════════════════════════════════════════════════════════
mkdir -p /opt/RamzesVPN && cd /opt/RamzesVPN

# Скачиваем файлы из GitHub
curl -sO "$GITHUB_RAW/requirements.txt"
curl -sO "$GITHUB_RAW/remnawave.py"
curl -sO "$GITHUB_RAW/bot.py"

python3 -m venv venv
source venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt

echo ""
read -p "🤖 BOT_TOKEN (@BotFather): " BOT_TOKEN_INPUT
info "Открой https://$DOMAIN → Settings → API → Create Token"
read -p "🔑 API Token: " API_TOKEN_INPUT

cat <<ENV > .env
BOT_TOKEN=$BOT_TOKEN_INPUT
RW_API_URL=https://$DOMAIN
RW_API_TOKEN=$API_TOKEN_INPUT
ADMIN_ID=1759300139
ENV

cat <<SVC > /etc/systemd/system/vpn_bot.service
[Unit]
Description=VPN Bot
After=network.target
[Service]
User=root
WorkingDirectory=/opt/RamzesVPN
Environment="PATH=/opt/RamzesVPN/venv/bin"
ExecStart=/opt/RamzesVPN/venv/bin/python /opt/RamzesVPN/bot.py
Restart=always; RestartSec=5
[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload && systemctl enable vpn_bot
systemctl restart vpn_bot
sleep 2
systemctl is-active --quiet vpn_bot && log "Бот запущен!" || warn "Бот не запущен"

# ═══════════════════════════════════════════════════════════
step "📝 ШАГ 7/7: ПОДПИСКА"
# ═══════════════════════════════════════════════════════════
cat <<NGINX > /etc/nginx/sites-available/sub
server {
    listen 443 ssl http2; server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    location /sub {
        default_type text/plain;
        return 200 "hysteria2://$HY_PASS@$IP:443?sni=www.google.com&insecure=1&alpn=h3#Ramzes-VPN\n";
    }
}
NGINX
ln -sf /etc/nginx/sites-available/sub /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
log "Подписка: https://$DOMAIN/sub"

# ═══════════════════════════════════════════════════════════
# 🎉 ФИНАЛ
# ═══════════════════════════════════════════════════════════
ELAPSED=$(($(date +%s) - START_TIME))
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  🎉 ГОТОВО ЗА ${ELAPSED}с!${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${NC}"
echo ""
echo -e "🎛️  Панель: ${CYAN}https://$DOMAIN${NC}"
echo -e "⚡ Hysteria2: ${CYAN}$IP:443${NC}"
echo -e "🔑 Пароль HY: ${CYAN}$HY_PASS${NC}"
echo -e "📡 Подписка: ${CYAN}https://$DOMAIN/sub${NC}"
echo -e "🤖 Бот: @RamzesVPNBot"
echo ""
echo -e "${YELLOW}📝 Далее:${NC}"
echo -e "  1. Зарегистрируйся в панели"
echo -e "  2. Settings → API → Create Token"
echo -e "  3. Обнови .env: nano /opt/RamzesVPN/.env"
echo -e "  4. systemctl restart vpn_bot"
echo ""
