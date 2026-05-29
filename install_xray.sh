#!/bin/bash

# Установка Xray с настраиваемым SNI для REALITY

set -e

# ============ НАСТРОЙКИ ============
# Можешь изменить SNI здесь
SNI="www.amd.com"
# ===================================

echo "=== Начало установки Xray ==="

# Получаем последнюю версию Xray
echo "Получаем последнюю версию Xray..."
LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep 'tag_name' | cut -d '"' -f 4)
if [ -z "$LATEST_VERSION" ]; then
  echo "Ошибка: не удалось получить последнюю версию Xray"
  exit 1
fi

echo "Найдена последняя версия: $LATEST_VERSION"

# Скачиваем Xray
ARCHIVE="Xray-linux-64.zip"
# Убираем лишний пробел после download/
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/${ARCHIVE}"

echo "Скачиваем Xray: $DOWNLOAD_URL"
wget -q "$DOWNLOAD_URL" -O "$ARCHIVE"

# Устанавливаем unzip если не установлен
if ! command -v unzip &> /dev/null; then
  echo "Устанавливаем unzip..."
  apt-get update && apt-get install -y unzip
fi

# Создаём директорию и распаковываем
echo "Распаковываем Xray в /opt/xray..."
mkdir -p /opt/xray
unzip -q "$ARCHIVE" -d /opt/xray
chmod +x /opt/xray/xray

# Удаляем архив
rm -f "$ARCHIVE"

# Создаём юнит для systemd
SERVICE_FILE="/usr/lib/systemd/system/xray.service"
echo "Создаём файл сервиса: $SERVICE_FILE"

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls 
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/opt/xray/xray run -config /opt/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# Включаем сервис
systemctl daemon-reload
systemctl enable xray

# Генерируем данные
echo "Генерируем UUID..."
ID=$(/opt/xray/xray uuid)
echo "Сгенерирован ID: $ID"

echo "Генерируем X25519 ключи..."
X25519_KEYS=$(/opt/xray/xray x25519)
PRIVATE_KEY=$(echo "$X25519_KEYS" | grep "Private key:" | awk '{print $3}')
# Новый вывод: "Password (PublicKey): <ключ>" или старый "Public key: <ключ>"
PUBLIC_KEY=$(echo "$X25519_KEYS" | grep -E "Password \(PublicKey\):|Public key:" | awk '{print $NF}')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
  echo "Ошибка: не удалось сгенерировать X25519 ключи"
  echo "Вывод команды x25519:"
  echo "$X25519_KEYS"
  exit 1
fi

echo "Сгенерирован private key: $PRIVATE_KEY"
echo "Сгенерирован public key: $PUBLIC_KEY"

echo "Генерируем пароль для Shadowsocks..."
SS_PASS=$(openssl rand -base64 16)
echo "Сгенерирован ss_pass: $SS_PASS"

echo "Генерируем shortId..."
SHORT_ID=$(openssl rand -hex 8)
echo "Сгенерирован short_id: $SHORT_ID"

# Определяем внешний IP сервера
echo "Определяем внешний IP-адрес сервера..."
IP_SRV=$(curl -s https://api.ipify.org)
if [ -z "$IP_SRV" ]; then
  IP_SRV=$(hostname -I | awk '{print $1}')
fi
echo "Внешний IP сервера: $IP_SRV"

# ============ Создаём конфиг с динамическим SNI ============
CONFIG_FILE="/opt/xray/config.json"
echo "Создаём конфигурационный файл: $CONFIG_FILE"

cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "loglevel": "info"
  },
  "routing": {
    "rules": [],
    "domainStrategy": "AsIs"
  },
  "inbounds": [
    {
      "port": 23,
      "tag": "ss",
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "$SS_PASS",
        "network": "tcp,udp"
      }
    },
    {
      "port": 443,
      "protocol": "vless",
      "tag": "vless_tls",
      "settings": {
        "clients": [
          {
            "id": "$ID",
            "email": "user1@myserver",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

# Запускаем Xray
echo "Запускаем сервис xray..."
systemctl start xray

# Проверяем статус
if systemctl is-active --quiet xray; then
  echo "✅ Xray успешно запущен"
else
  echo "❌ Ошибка: Xray не запустился. Проверь статус: systemctl status xray"
  exit 1
fi

# ============ Формируем VLESS ссылку ============

PBK_ENCODED=$(echo "$PUBLIC_KEY" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g')

VLESS_LINK="vless://$ID@$IP_SRV:443?flow=xtls-rprx-vision&security=reality&encryption=none&type=tcp&sni=$SNI&sid=$SHORT_ID&fp=qq&pbk=$PBK_ENCODED&spx=%2F&headerType=none#N_xray"

# ============ Вывод всех данных ============

echo
echo "========================================"
echo "===       Установка завершена        ==="
echo "========================================"
echo "SNI (serverName): $SNI"
echo "ID (UUID клиента): $ID"
echo "Private Key (X25519): $PRIVATE_KEY"
echo "Public Key (X25519): $PUBLIC_KEY"
echo "Shadowsocks Password (ss_pass): $SS_PASS"
echo "Short ID (для Reality): $SHORT_ID"
echo "IP сервера: $IP_SRV"
echo
echo "🔗 VLESS ссылка (для клиентов):"
echo "$VLESS_LINK"
echo
echo "💡 Подсказка: скопируй ссылку и вставь в клиент (Nekoray, v2rayNG и др.)"
echo "========================================"
echo "Конфигурация сохранена в /opt/xray/config.json"
echo "Сервис запущен: systemctl status xray"
echo "Для перезапуска: systemctl restart xray"
