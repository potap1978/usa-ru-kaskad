#!/bin/bash
# USA-RU-KASKAD — Universal AmneziaWG Client Installer for Debian/Ubuntu
# Run: sudo ./usa-ru-kaskad.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
    log_error "Run as root"
    exit 1
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    log_error "Cannot detect OS"
    exit 1
fi

log_info "Detected OS: $OS $VERSION"

case $OS in
    ubuntu|debian) ;;
    *) log_error "Unsupported OS: $OS. Only Ubuntu/Debian supported"; exit 1 ;;
esac

log_info "Starting USA-RU-KASKAD installation..."

# 1. Установка зависимостей
log_info "Installing dependencies..."
apt-get update
apt-get install -y linux-headers-$(uname -r) build-essential dkms git curl ca-certificates pkg-config libmnl-dev libsystemd-dev

# 2. Kernel Module (latest master)
log_info "Building AmneziaWG kernel module (latest master)..."
cd /usr/src
if [[ -d amneziawg-1.0 ]]; then rm -rf amneziawg-1.0; fi
git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git amneziawg-1.0
cd amneziawg-1.0/src
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
make install
depmod -a
modprobe amneziawg

if ! lsmod | grep -q amneziawg; then
    log_error "Kernel module failed to load"
    exit 1
fi
log_info "Kernel module installed (latest master)"

# 3. Tools (latest master)
log_info "Building amneziawg-tools (latest master)..."
cd /usr/src
if [[ -d amneziawg-tools ]]; then rm -rf amneziawg-tools; fi
git clone https://github.com/amnezia-vpn/amneziawg-tools.git
cd amneziawg-tools/src
make -j$(nproc)
make install PREFIX=/usr
log_info "amneziawg-tools installed (latest master)"

# 4. Wrapper (auto Table=off)
log_info "Creating awg-quick wrapper..."
cat > /usr/local/bin/awg-quick-wrapper << 'WRAPPER_EOF'
#!/bin/bash
set -euo pipefail
ACTION="$1"
CONFIG="$2"
CONFIG_FILE="/etc/amnezia/amneziawg/${CONFIG}.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config not found: $CONFIG_FILE" >&2
    exit 1
fi
if [[ "$ACTION" == "up" ]]; then
    if ! awk '/^\[Interface\]/ { in_iface=1 } /^\[.*\]/ && !/^\[Interface\]/ { in_iface=0 } in_iface && /^Table[[:space:]]*=/ { found=1 } END { exit !found }' "$CONFIG_FILE"; then
        sed -i '/^\[Interface\]/a Table = off' "$CONFIG_FILE"
    fi
fi
exec /usr/local/bin/awg-quick "$ACTION" "$CONFIG"
WRAPPER_EOF
chmod +x /usr/local/bin/awg-quick-wrapper

# 5. Systemd services
log_info "Creating systemd services..."

cat > /etc/systemd/system/awg-quick@.service << 'SERVICE_EOF'
[Unit]
Description=AmneziaWG via awg-quick(8) for %I (with auto Table=off)
After=network-online.target
Wants=network-online.target
Documentation=man:awg-quick(8)
Documentation=man:awg(8)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/awg-quick-wrapper up %i
ExecStop=/usr/local/bin/awg-quick-wrapper down %i

[Install]
WantedBy=multi-user.target
SERVICE_EOF

cat > /etc/systemd/system/amneziawg-routing@.service << 'ROUTING_EOF'
[Unit]
Description=AmneziaWG VPN Routing + SSH Protection for %I
After=awg-quick@%i.service
Wants=awg-quick@%i.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/amneziawg-setup-routing %i
ExecStop=/usr/local/bin/amneziawg-teardown-routing %i

[Install]
WantedBy=multi-user.target
ROUTING_EOF

# 6. Routing scripts
log_info "Creating routing scripts..."

cat > /usr/local/bin/amneziawg-setup-routing << 'SETUP_EOF'
#!/bin/bash
set -euo pipefail
IFACE="$1"
FWMARK=51820
TABLE=51820

for i in {1..10}; do
    if ip link show "$IFACE" >/dev/null 2>&1; then break; fi
    sleep 1
done

SERVER_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
fi

read -r GW DEV <<< $(ip route show default | awk '/default/ {print $3, $5; exit}')

ENDPOINT=$(awg show "$IFACE" endpoints | awk '{print $2}' | cut -d: -f1 | head -1)
if [[ -z "$ENDPOINT" ]]; then
    CONF="/etc/amnezia/amneziawg/${IFACE}.conf"
    ENDPOINT=$(grep -i '^Endpoint' "$CONF" 2>/dev/null | head -1 | sed 's/.*= *//' | cut -d: -f1)
fi

awg set "$IFACE" fwmark $FWMARK

sysctl -w net.ipv6.conf."$IFACE".disable_ipv6=1 >/dev/null 2>&1 || true
ip -6 addr flush dev "$IFACE" 2>/dev/null || true

ip rule add prio 10 from "$SERVER_IP" table main 2>/dev/null || true

iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true
iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true

if [[ -n "$ENDPOINT" && -n "$GW" && -n "$DEV" ]]; then
    ip route add "$ENDPOINT/32" via "$GW" dev "$DEV" 2>/dev/null || true
fi

ip rule add not fwmark $FWMARK table $TABLE 2>/dev/null || true
ip route add default dev "$IFACE" table $TABLE 2>/dev/null || true

iptables -t mangle -A POSTROUTING -m mark --mark $FWMARK -p udp -j CONNMARK --save-mark 2>/dev/null || true
iptables -t mangle -A PREROUTING -p udp -j CONNMARK --restore-mark 2>/dev/null || true

sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1 || true

echo "VPN routing configured for $IFACE (IPv4 only, fwmark=$FWMARK, table=$TABLE)"
SETUP_EOF
chmod +x /usr/local/bin/amneziawg-setup-routing

cat > /usr/local/bin/amneziawg-teardown-routing << 'TEARDOWN_EOF'
#!/bin/bash
set -euo pipefail
IFACE="$1"
FWMARK=51820
TABLE=51820

ip rule del not fwmark $FWMARK table $TABLE 2>/dev/null || true
ip route flush table $TABLE 2>/dev/null || true

SERVER_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
if [[ -n "$SERVER_IP" ]]; then
    ip rule del prio 10 from "$SERVER_IP" table main 2>/dev/null || true
fi

iptables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true
iptables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true
iptables -t mangle -D POSTROUTING -m mark --mark $FWMARK -p udp -j CONNMARK --save-mark 2>/dev/null || true
iptables -t mangle -D PREROUTING -p udp -j CONNMARK --restore-mark 2>/dev/null || true

echo "VPN routing cleaned for $IFACE"
TEARDOWN_EOF
chmod +x /usr/local/bin/amneziawg-teardown-routing

# 7. Start/Stop scripts
log_info "Creating Start/Stop scripts..."

cat > /usr/local/bin/Start-VPN << 'START_EOF'
#!/bin/bash
set -euo pipefail
echo "Starting VPN..."
systemctl start awg-quick@amneziawg
for i in {1..10}; do
    if ip link show amneziawg >/dev/null 2>&1; then break; fi
    sleep 1
done
systemctl start amneziawg-routing@amneziawg
echo "VPN started"
echo "External IP: $(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo 'unavailable')"
START_EOF
chmod +x /usr/local/bin/Start-VPN

cat > /usr/local/bin/Stop-VPN << 'STOP_EOF'
#!/bin/bash
set -euo pipefail
echo "Stopping VPN..."
systemctl stop amneziawg-routing@amneziawg 2>/dev/null || true
systemctl stop awg-quick@amneziawg 2>/dev/null || true
echo "VPN stopped"
STOP_EOF
chmod +x /usr/local/bin/Stop-VPN

cp /usr/local/bin/Start-VPN /root/Start-VPN
cp /usr/local/bin/Stop-VPN /root/Stop-VPN
chmod +x /root/Start-VPN /root/Stop-VPN

# 8. Пустой конфиг-шаблон
log_info "Creating empty config template..."
mkdir -p /etc/amnezia/amneziawg
cat > /etc/amnezia/amneziawg/amneziawg.conf << 'CONF_EOF'
# AmneziaWG Client Config
# ЗАПОЛНИТЕ ВСЕ ПОЛЯ НИЖЕ ПЕРЕД ЗАПУСКОМ Start-VPN

[Interface]
PrivateKey = ВАШ_PRIVATE_KEY_ЗДЕСЬ
Address = 10.2.0.2/32
DNS = 10.2.0.1, 8.8.8.8
MTU = 1420
S1 = 0
S2 = 0
S3 = 0
S4 = 0
Jc = 3
Jmin = 1
Jmax = 3
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = PUBLIC_KEY_СЕРВЕРА_ЗДЕСЬ
Endpoint = IP_СЕРВЕРА:ПОРТ
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CONF_EOF

chmod 600 /etc/amnezia/amneziawg/amneziawg.conf

# 9. Enable services for auto-start on boot
log_info "Enabling services for auto-start on boot..."
systemctl daemon-reload
systemctl enable awg-quick@amneziawg amneziawg-routing@amneziawg

# 10. Не запускаем VPN автоматически — конфиг пустой
log_info "Installation complete!"
echo ""
echo "=========================================="
echo "  USA-RU-KASKAD УСТАНОВЛЕН УСПЕШНО"
echo "=========================================="
echo ""
echo "⚠️  ВАЖНО: Конфиг создан пустым (шаблон)."
echo ""
echo "📝 СЛЕДУЮЩИЕ ШАГИ:"
echo "  1. Отредактируйте конфиг:"
echo "     nano /etc/amnezia/amneziawg/amneziawg.conf"
echo ""
echo "     Заполните ВСЕ поля:"
echo "       - PrivateKey = ваш приватный ключ"
echo "       - Address = ваш IP в VPN (например 10.2.0.2/32)"
echo "       - DNS = DNS серверы"
echo "       - PublicKey = публичный ключ сервера"
echo "       - Endpoint = IP:ПОРТ сервера AmneziaWG"
echo ""
echo "  2. Запустите VPN:"
echo "     ~/Start-VPN"
echo ""
echo "  3. Проверьте:"
echo "     ip link show amneziawg"
echo "     awg show"
echo "     curl ifconfig.me"
echo ""
echo "🔄 ПОСЛЕ ПЕРЕЗАГРУЗКИ СЕРВЕРА ТУННЕЛЬ ПОДНИМЕТСЯ АВТОМАТИЧЕСКИ"
echo "   (сервисы awg-quick@amneziawg и amneziawg-routing@amneziawg добавлены в автозагрузку)"
echo ""
echo "📁 Управление:"
echo "  ~/Start-VPN   — запустить VPN"
echo "  ~/Stop-VPN    — остановить VPN"
echo "  Конфиг: /etc/amnezia/amneziawg/amneziawg.conf"
echo ""
echo "=========================================="