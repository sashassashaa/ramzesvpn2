cat > /opt/install_full.sh << 'INSTALL_EOF'
#!/bin/bash
set -e

# ═══════════════════════════════════════════════════════════
# 🚀 RAMZES VPN — ПОЛНАЯ УСТАНОВКА ПОД КЛЮЧ
# ═══════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[ℹ]${NC} $1"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

[ "$EUID" -ne 0 ] && err "Запусти от root: sudo bash install_full.sh"

IP=$(curl -s4 ifconfig.me)
START_TIME=$(date +%s)

clear
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║     🚀 RAMZES VPN — УСТАНОВЩИК          ║"
echo "║     RemnaWave + Hysteria2 + Telegram     ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "🌍 IP сервера: ${CYAN}$IP${NC}"
echo -e "📦 Debian 12 • 2 vCPU • 2+ GB RAM"
echo ""

# ═══════════════════════════════════════════════════════════
step "📋 ШАГ 1/7: СИСТЕМНЫЕ ПАКЕТЫ"
# ═══════════════════════════════════════════════════════════

info "Обновление системы..."
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
apt update -qq && apt upgrade -y -qq
log "Система обновлена"

info "Установка зависимостей..."
apt install -y -qq curl wget git unzip nginx python3 python3-venv python3-pip \
    openssl cron ufw sshpass certbot
log "Зависимости установлены"

# ═══════════════════════════════════════════════════════════
step "🐳 ШАГ 2/7: DOCKER + CERTBOT"
# ═══════════════════════════════════════════════════════════

if ! command -v docker &> /dev/null; then
    info "Установка Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi
apt install -y -qq docker-compose-plugin
log "Docker готов"

info "Настройка Certbot..."
mkdir -p /opt/certbot/certs /opt/certbot/var-lib-letsencrypt
log "Certbot готов"

# ═══════════════════════════════════════════════════════════
step "🔐 ШАГ 3/7: ДОМЕН И SSL"
# ═══════════════════════════════════════════════════════════

echo ""
info "Для работы нужен домен. Есть 2 варианта:"
echo "  1. duckdns.org — бесплатный (например, ramzes.duckdns.org)"
echo "  2. Свой домен"
echo ""
read -p "Введи домен (или нажми Enter для ramzesvpnbot.duckdns.org): " DOMAIN
DOMAIN=${DOMAIN:-ramzesvpnbot.duckdns.org}

# Если duckdns — запросим токен
if [[ "$DOMAIN" == *"duckdns"* ]]; then
    read -p "Токен DuckDNS: " DUCKDNS_TOKEN
    mkdir -p /opt/duckdns
    cat > /opt/duckdns/update.sh << EOF
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=${DOMAIN%%.*}&token=$DUCKDNS_TOKEN&ip=" | curl -k -o /opt/duckdns/duck.log -K -
EOF
    chmod +x /opt/duckdns/update.sh
    /opt/duckdns/update.sh
    (crontab -l 2>/dev/null; echo "*/5 * * * * /opt/duckdns/update.sh") | crontab -
    log "DuckDNS настроен: $DOMAIN"
fi

info "Выпуск SSL-сертификата..."
systemctl stop nginx 2>/dev/null
certbot certonly --standalone \
    -d "$DOMAIN" \
    --non-interactive --agree-tos \
    --email "admin@$DOMAIN" 2>/dev/null || {
    warn "Сертификат не выпущен. Продолжаем с самоподписанным..."
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/panel.key \
        -out /etc/nginx/ssl/panel.crt \
        -subj "/CN=$DOMAIN"
}
systemctl start nginx
log "SSL готов"

# ═══════════════════════════════════════════════════════════
step "🎛️ ШАГ 4/7: REMNAWAVE ПАНЕЛЬ"
# ═══════════════════════════════════════════════════════════

info "Развёртывание RemnaWave + PostgreSQL + Redis..."
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
    volumes:
      - pgdata:/var/lib/postgresql/data
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
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
    environment:
      NODE_ENV: production
      PORT: 3000
      DATABASE_URL: "postgresql://remnawave:$DB_PASS@postgres:5432/remnawave"
      REDIS_HOST: redis; REDIS_PORT: 6379
      JWT_SECRET: "$JWT_SECRET"
      APP_SECRET: "$APP_SECRET"
      FRONT_END_DOMAIN: "https://$DOMAIN"
      SUB_PUBLIC_DOMAIN: "$DOMAIN"
      METRICS_USER: admin; METRICS_PASS: "$METRICS_PASS"
      NODE_TLS_REJECT_UNAUTHORIZED: "0"

volumes:
  pgdata:
COMPOSE

docker compose pull -q
docker compose up -d

info "Ожидание запуска панели..."
for i in {1..60}; do
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000 2>/dev/null | grep -q "200\|302\|401"; then
        log "Панель запущена (${i}с)"
        break
    fi
    sleep 1
done

# Nginx для панели
cat <<NGINX > /etc/nginx/sites-available/remnawave
server {
    listen 80; server_name $DOMAIN; return 301 https://\$host\$request_uri;
}
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
log "Nginx настроен: https://$DOMAIN"

# ═══════════════════════════════════════════════════════════
step "⚡ ШАГ 5/7: HYSTERIA2"
# ═══════════════════════════════════════════════════════════

info "Установка Hysteria2..."
mkdir -p /opt/hysteria2 && cd /opt/hysteria2

curl -sLO https://github.com/apernet/hysteria/releases/download/app/v2.6.1/hysteria-linux-amd64
mv hysteria-linux-amd64 hysteria2 && chmod +x hysteria2

HY_PASS=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)

openssl req -x509 -nodes -days 365 -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout private.key -out cert.crt -subj "/CN=www.google.com" 2>/dev/null

cat <<HY > config.yaml
listen: :443
tls:
  cert: /opt/hysteria2/cert.crt
  key: /opt/hysteria2/private.key
auth:
  type: password
  password: $HY_PASS
masquerade:
  type: proxy
  proxy:
    url: https://www.google.com
    rewriteHost: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
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
log "Hysteria2 запущен (пароль: $HY_PASS)"

# ═══════════════════════════════════════════════════════════
step "🤖 ШАГ 6/7: TELEGRAM БОТ"
# ═══════════════════════════════════════════════════════════

info "Установка бота..."
mkdir -p /opt/RamzesVPN && cd /opt/RamzesVPN

# Клонируем файлы бота
cat > requirements.txt << 'REQ'
aiogram>=3.4.0
aiohttp>=3.9.3
python-dotenv>=1.0.1
REQ

python3 -m venv venv
source venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt

# Спрашиваем токены
echo ""
read -p "🤖 BOT_TOKEN (@BotFather): " BOT_TOKEN_INPUT

# Создаём API токен в панели
info "Открой https://$DOMAIN → зарегистрируйся → Settings → API → Create Token"
read -p "🔑 API Token панели: " API_TOKEN_INPUT

cat <<ENV > .env
BOT_TOKEN=$BOT_TOKEN_INPUT
RW_API_URL=https://$DOMAIN
RW_API_TOKEN=$API_TOKEN_INPUT
ENV

# Системная служба
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

systemctl daemon-reload
systemctl enable vpn_bot
log "Бот настроен"

# ═══════════════════════════════════════════════════════════
step "📝 ШАГ 7/7: СОЗДАНИЕ BOT.PY + REMNAWAVE.PY"
# ═══════════════════════════════════════════════════════════

info "Генерация файлов бота..."

# remnawave.py
cat > remnawave.py << 'RWEOF'
import aiohttp, logging, asyncio, json
from datetime import datetime, timedelta, timezone
from typing import Optional, Tuple

logger = logging.getLogger(__name__)

class RemnaWaveClient:
    def __init__(self, api_url: str, api_token: str):
        self.api_url = api_url.rstrip('/')
        self.headers = {"Authorization": f"Bearer {api_token}", "Content-Type": "application/json"}

    async def health_check(self) -> bool:
        try:
            async with aiohttp.ClientSession(headers=self.headers) as s:
                async with s.get(f"{self.api_url}/api/health", timeout=5, ssl=False) as r:
                    return r.status in (200, 401, 302, 404)
        except: return False

    async def create_user(self, username: str, expire_days: int) -> Tuple[Optional[str], str]:
        expire_at = (datetime.now(timezone.utc) + timedelta(days=expire_days)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        payload = {"username": username, "status": "ACTIVE", "expireAt": expire_at, "dataLimit": 0, "trafficLimitStrategy": "NO_RESET"}
        
        async with aiohttp.ClientSession(headers=self.headers) as s:
            try:
                async with s.post(f"{self.api_url}/api/users", json=payload, timeout=15, ssl=False) as r:
                    if r.status in (200, 201):
                        data = await r.json()
                        return data.get("response", data).get("subscriptionUrl", ""), ""
                    if r.status == 409:
                        return None, "Ключ уже существует"
                    return None, f"Ошибка {r.status}"
            except Exception as e:
                return None, str(e)[:100]
RWEOF

# bot.py — упрощённая версия
cat > bot.py << 'BOTEOF'
import asyncio, os, logging, json
from datetime import datetime, timedelta
from dotenv import load_dotenv
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from aiogram.types import ReplyKeyboardMarkup, KeyboardButton, InlineKeyboardButton
from aiogram.client.default import DefaultBotProperties
from aiogram.utils.keyboard import InlineKeyboardBuilder
from remnawave import RemnaWaveClient

logging.basicConfig(level=logging.INFO)
load_dotenv()

bot = Bot(token=os.getenv("BOT_TOKEN"), default=DefaultBotProperties(parse_mode="HTML"))
dp = Dispatcher()
rw = RemnaWaveClient(os.getenv("RW_API_URL"), os.getenv("RW_API_TOKEN"))
ADMIN_ID = int(os.getenv("ADMIN_ID", 0))

USERS_FILE = "/opt/RamzesVPN/users.json"

def load_users():
    try: return json.load(open(USERS_FILE))
    except: return {}

def save_users(u):
    json.dump(u, open(USERS_FILE, "w"), indent=2)

@dp.message(Command("start"))
async def start(msg: types.Message):
    kb = ReplyKeyboardMarkup(keyboard=[[KeyboardButton(text="👤 Профиль")]], resize_keyboard=True)
    await msg.answer("👋 <b>Ramzes VPN</b>\n\nНажми <b>Профиль</b> для получения подписки", reply_markup=kb)

@dp.message(F.text == "👤 Профиль")
async def profile(msg: types.Message):
    uid = str(msg.from_user.id)
    users = load_users()
    
    if uid not in users or not users[uid].get("sub_link"):
        link, err = await rw.create_user(f"tg_{uid}", 30)
        if link:
            users[uid] = {"name": msg.from_user.full_name, "sub_link": link, "expire": (datetime.now() + timedelta(days=30)).isoformat()}
            save_users(users)
        else:
            await msg.answer(f"❌ {err}"); return
    
    u = users[uid]
    days = max(0, (datetime.fromisoformat(u["expire"]) - datetime.now()).days)
    
    builder = InlineKeyboardBuilder()
    builder.row(InlineKeyboardButton(text="🔄 Обновить", callback_data="refresh"))
    
    await msg.answer(
        f"👤 <b>Профиль</b>\n\n"
        f"🔑 Подписка:\n<code>{u['sub_link']}</code>\n\n"
        f"📅 Срок: {days} дн.\n\n"
        f"<i>Добавь ссылку в Inci/Hiddify/Streisand</i>",
        reply_markup=builder.as_markup()
    )

@dp.callback_query(F.data == "refresh")
async def refresh(call: types.CallbackQuery):
    uid = str(call.from_user.id)
    link, _ = await rw.create_user(f"tg_{uid}", 30)
    if link:
        users = load_users()
        users[uid] = {"name": call.from_user.full_name, "sub_link": link, "expire": (datetime.now() + timedelta(days=30)).isoformat()}
        save_users(users)
        await call.answer("✅ Обновлено!")
    await call.message.delete()
    await profile(call.message)

async def main():
    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
BOTEOF

log "Файлы бота созданы"

# Запускаем бота
systemctl restart vpn_bot
sleep 2
systemctl is-active --quiet vpn_bot && log "Бот запущен!" || warn "Бот не запустился. Проверь: systemctl status vpn_bot"

# ═══════════════════════════════════════════════════════════
# 🎉 ФИНАЛ
# ═══════════════════════════════════════════════════════════

ELAPSED=$(($(date +%s) - START_TIME))
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  🎉 УСТАНОВКА ЗАВЕРШЕНА ЗА ${ELAPSED}с!${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${NC}"
echo ""
echo -e "🎛️  Панель RemnaWave: ${CYAN}https://$DOMAIN${NC}"
echo -e "⚡ Hysteria2:       ${CYAN}$IP:443${NC} (пароль: $HY_PASS)"
echo -e "🤖 Бот:             ${CYAN}@RamzesVPNBot${NC}"
echo ""
echo -e "${YELLOW}📝 Дальнейшие шаги:${NC}"
echo -e "  1. Открой панель, зарегистрируй админа"
echo -e "  2. Настрой Config Profile (VLESS/Trojan)"
echo -e "  3. Добавь серверы через бота: /start → Профиль"
echo ""
echo -e "${YELLOW}📜 Полезные команды:${NC}"
echo -e "  systemctl status vpn_bot     — статус бота"
echo -e "  systemctl status hysteria2   — статус Hysteria2"
echo -e "  docker ps                    — контейнеры панели"
echo -e "  docker logs remnawave -f     — логи панели"
echo ""
INSTALL_EOF

chmod +x /opt/install_full.sh
echo "✅ Скрипт создан: /opt/install_full.sh"
echo "📦 Для установки на чистом сервере: bash /opt/install_full.sh"