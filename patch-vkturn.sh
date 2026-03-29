#!/bin/bash

# ============================================================
#  patch-vkturn.sh
#  Добавляет vk-turn-proxy поверх уже установленного autoXRAY
#  Использует Xray встроенный WireGuard вместо WG-демона
# ============================================================

GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
NC='\033[0m'

VK_LINK="https://vk.com/call/join/7mCiI07V5QESzAVch7eVXqYq2r0wnEg0JS2_1kO4fnY"

# Порты
WG_XRAY_PORT=51820   # Xray WireGuard inbound (локальный, слушает vk-turn server)
VKTURN_PORT=56000    # vk-turn-proxy server слушает снаружи

XRAY_CONFIG="/usr/local/etc/xray/config.json"
VKTURN_BIN="/usr/local/bin/vk-turn-server"
VKTURN_SERVICE="/etc/systemd/system/vk-turn.service"

# ── Проверки ────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || { echo -e "${RED}❌ Нужны root права${NC}"; exit 1; }

if [ ! -f "$XRAY_CONFIG" ]; then
    echo -e "${RED}❌ Не найден $XRAY_CONFIG — сначала запусти autoXRAY1.sh${NC}"
    exit 1
fi

command -v xray >/dev/null 2>&1 || { echo -e "${RED}❌ xray не установлен${NC}"; exit 1; }
command -v jq   >/dev/null 2>&1 || { apt-get install -y jq; }

echo -e "${YEL}=== patch-vkturn: установка vk-turn-proxy ===${NC}"

# ── Бэкап конфига ───────────────────────────────────────────

cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
echo -e "${GRN}✅ Бэкап конфига сохранён${NC}"

# ── Генерация WireGuard ключей через Xray ───────────────────

echo -e "${YEL}Генерация WireGuard ключей...${NC}"

SERVER_KEYS=$(xray x25519)
SERVER_PRIVATE=$(echo "$SERVER_KEYS" | grep -i 'Private' | awk '{print $NF}')
SERVER_PUBLIC=$(echo  "$SERVER_KEYS" | grep -i 'Public'  | awk '{print $NF}')

CLIENT_KEYS=$(xray x25519)
CLIENT_PRIVATE=$(echo "$CLIENT_KEYS" | grep -i 'Private' | awk '{print $NF}')
CLIENT_PUBLIC=$(echo  "$CLIENT_KEYS" | grep -i 'Public'  | awk '{print $NF}')

echo -e "${GRN}✅ Ключи сгенерированы${NC}"

# ── Проверяем: уже добавлен WG inbound? ─────────────────────

if jq -e '.inbounds[] | select(.tag == "wg-vkturn")' "$XRAY_CONFIG" > /dev/null 2>&1; then
    echo -e "${YEL}⚠️  WireGuard inbound уже есть в конфиге. Пропускаем патч конфига.${NC}"
else
    # ── Патч config.json: добавляем WG inbound ──────────────

    NEW_INBOUND=$(cat <<EOF
{
  "tag": "wg-vkturn",
  "protocol": "wireguard",
  "listen": "127.0.0.1",
  "port": $WG_XRAY_PORT,
  "settings": {
    "secretKey": "$SERVER_PRIVATE",
    "peers": [
      {
        "publicKey": "$CLIENT_PUBLIC"
      }
    ],
    "mtu": 1280
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  }
}
EOF
)

    # Добавляем новый inbound в массив inbounds
    jq --argjson nb "$NEW_INBOUND" '.inbounds += [$nb]' "$XRAY_CONFIG" > /tmp/xray_patched.json

    if jq empty /tmp/xray_patched.json 2>/dev/null; then
        mv /tmp/xray_patched.json "$XRAY_CONFIG"
        echo -e "${GRN}✅ WireGuard inbound добавлен в config.json${NC}"
    else
        echo -e "${RED}❌ Ошибка JSON после патча — откат${NC}"
        cp "${XRAY_CONFIG}.bak."* "$XRAY_CONFIG" 2>/dev/null
        exit 1
    fi
fi

# ── Скачиваем vk-turn-proxy server ─────────────────────────

echo -e "${YEL}Скачиваем vk-turn-proxy server...${NC}"

LATEST_URL=$(curl -s https://api.github.com/repos/cacggghp/vk-turn-proxy/releases/latest \
    | grep "browser_download_url" \
    | grep "server-linux" \
    | grep -v "\.sha256" \
    | head -1 \
    | cut -d '"' -f 4)

if [ -z "$LATEST_URL" ]; then
    echo -e "${RED}❌ Не удалось получить ссылку на релиз. Проверь интернет или GitHub.${NC}"
    exit 1
fi

curl -L "$LATEST_URL" -o "$VKTURN_BIN"
chmod +x "$VKTURN_BIN"
echo -e "${GRN}✅ Бинарник загружен: $VKTURN_BIN${NC}"

# ── Создаём systemd сервис ───────────────────────────────────

cat > "$VKTURN_SERVICE" <<EOF
[Unit]
Description=vk-turn-proxy server (VK TURN tunnel for Xray WireGuard)
After=network.target xray.service

[Service]
ExecStart=$VKTURN_BIN -listen 0.0.0.0:$VKTURN_PORT -connect 127.0.0.1:$WG_XRAY_PORT
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vk-turn
echo -e "${GRN}✅ Сервис vk-turn запущен${NC}"

# ── Открываем порт в ufw (если есть) ────────────────────────

if command -v ufw >/dev/null 2>&1; then
    ufw allow $VKTURN_PORT/tcp
    ufw allow $VKTURN_PORT/udp
    echo -e "${GRN}✅ Порт $VKTURN_PORT открыт в ufw${NC}"
fi

# ── Перезапускаем Xray ──────────────────────────────────────

systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    echo -e "${GRN}✅ Xray перезапущен успешно${NC}"
else
    echo -e "${RED}❌ Xray не запустился! Смотри: journalctl -u xray -n 30${NC}"
    exit 1
fi

# ── Итог ────────────────────────────────────────────────────

SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "
${GRN}========================================================
  ✅  vk-turn-proxy успешно интегрирован в autoXRAY
========================================================${NC}

${YEL}=== Конфиг Xray-клиента (замени в своём v2rayN/Happ) ===${NC}

Серверная часть настроена. На клиенте запусти vk-turn-proxy client:

  ./client-linux \\
    -peer ${SERVER_IP}:${VKTURN_PORT} \\
    -link '${VK_LINK}' \\
    -listen 127.0.0.1:9000 | sudo bash routes.sh

${YEL}=== Клиентский Xray конфиг (outbound WireGuard) ===${NC}
Замени свой outbound в клиентском конфиге Xray на:

{
  \"protocol\": \"wireguard\",
  \"tag\": \"proxy\",
  \"settings\": {
    \"secretKey\": \"${CLIENT_PRIVATE}\",
    \"peers\": [
      {
        \"endpoint\": \"127.0.0.1:9000\",
        \"publicKey\": \"${SERVER_PUBLIC}\"
      }
    ],
    \"domainStrategy\": \"ForceIPv4\",
    \"mtu\": 1280
  }
}

${YEL}=== Ключи (сохрани!) ===${NC}
Сервер приватный : ${SERVER_PRIVATE}
Сервер публичный : ${SERVER_PUBLIC}
Клиент приватный : ${CLIENT_PRIVATE}
Клиент публичный : ${CLIENT_PUBLIC}

${YEL}=== Статус сервисов ===${NC}"

systemctl is-active --quiet xray     && echo -e "XRAY:     ${GRN}RUNNING${NC}" || echo -e "XRAY:     ${RED}STOPPED${NC}"
systemctl is-active --quiet vk-turn  && echo -e "VK-TURN:  ${GRN}RUNNING${NC}" || echo -e "VK-TURN:  ${RED}STOPPED${NC}"
