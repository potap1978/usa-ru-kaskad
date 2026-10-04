#!/bin/bash
# USA-RU-KASKAD v3 — Universal AmneziaWG Client Installer for Debian/Ubuntu
# Run: sudo ./usa-ru-kaskad.sh
#
# Installs: kernel module (latest master) + tools (latest master),
# wrapper (auto Table=off), systemd services, policy routing with SSH
# protection, Start/Stop scripts, empty config template.
# After install: fill /etc/amnezia/amneziawg/amneziawg.conf, run ~/Start-VPN.

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

# 1. Dependencies
log_info "Installing dependencies..."
apt-get update
apt-get install -y linux-headers-$(uname -r) build-essential dkms git curl ca-certificates pkg-config libmnl-dev libsystemd-dev

# 2. Kernel module (latest master)
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

# 4. Wrapper (auto Table=off for ANY config)
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

cat > /etc/systemd/system/amneziawg-client-routing@.service << 'CLIENTROUTING_EOF'
[Unit]
Description=AmneziaWG Client VPN Routing + SSH Protection for %I
After=awg-quick@%i.service
Wants=awg-quick@%i.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/amneziawg-client-routing %i
ExecStop=/usr/local/bin/amneziawg-client-teardown %i

[Install]
WantedBy=multi-user.target
CLIENTROUTING_EOF

# 6a. Client routing scripts (fwmark 51821 / table 51821)
log_info "Creating client routing scripts..."

cat > /usr/local/bin/amneziawg-client-routing << 'CLIENT_SETUP_EOF'
#!/bin/bash
# amneziawg-client-routing - IPv4 VPN routing + SSH protection (client)
# Lessons: MAIN_DEV server IP (never via tunnel), prio-900 endpoint bypass,
# no in-tunnel routes, no from-tunnel-IP rules, idempotent (-C checks)
set -euo pipefail
IFACE="amneziawg"
FWMARK=51821
TABLE=51821

for i in $(seq 1 10); do
    if ip link show "$IFACE" >/dev/null 2>&1; then break; fi
    sleep 1
done

MAIN_DEV=$(ip route show table main default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
SERVER_IP=$(ip -4 addr show scope global dev "$MAIN_DEV" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^10\.' | head -1)
fi

ENDPOINT=$(awg show "$IFACE" endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | head -1)
if [ -z "$ENDPOINT" ]; then
    ENDPOINT=$(grep -i '^Endpoint' "/etc/amnezia/amneziawg/${IFACE}.conf" 2>/dev/null | head -1 | sed 's/.*= *//' | cut -d: -f1)
fi

awg set "$IFACE" fwmark $FWMARK

sysctl -w net.ipv6.conf."$IFACE".disable_ipv6=1 >/dev/null 2>&1 || true
ip -6 addr flush dev "$IFACE" 2>/dev/null || true

ip rule add prio 10 from "$SERVER_IP" table main 2>/dev/null || true

iptables -t mangle -C OUTPUT -p tcp --sport 22 -j MARK --set-mark $FWMARK 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true
iptables -t mangle -C OUTPUT -p tcp --dport 22 -j MARK --set-mark $FWMARK 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true

if [ -n "$ENDPOINT" ]; then
    ip rule del prio 900 to "$ENDPOINT" table main 2>/dev/null || true
    ip rule add prio 900 to "$ENDPOINT" table main 2>/dev/null || true
fi

ip route del "${ENDPOINT}"/32 dev "$IFACE" table $TABLE 2>/dev/null || true
ip route add default dev "$IFACE" table $TABLE 2>/dev/null || true
ip rule add prio 1000 not fwmark $FWMARK table $TABLE 2>/dev/null || true

iptables -t mangle -C POSTROUTING -m mark --mark $FWMARK -p udp -j CONNMARK --save-mark 2>/dev/null || iptables -t mangle -A POSTROUTING -m mark --mark $FWMARK -p udp -j CONNMARK --save-mark 2>/dev/null || true
iptables -t mangle -C PREROUTING -p udp -j CONNMARK --restore-mark 2>/dev/null || iptables -t mangle -A PREROUTING -p udp -j CONNMARK --restore-mark 2>/dev/null || true

sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1 || true

echo "client routing ok: iface=$IFACE endpoint=$ENDPOINT"
CLIENT_SETUP_EOF
chmod +x /usr/local/bin/amneziawg-client-routing

cat > /usr/local/bin/amneziawg-client-teardown << 'CLIENT_TEARDOWN_EOF'
#!/bin/bash
set -euo pipefail
IFACE="amneziawg"
FWMARK=51821
TABLE=51821

CONF="/etc/amnezia/amneziawg/${IFACE}.conf"
ENDPOINT=$(grep -i '^Endpoint' "$CONF" 2>/dev/null | head -1 | sed 's/.*= *//' | cut -d: -f1)

ip rule del prio 1000 not fwmark $FWMARK table $TABLE 2>/dev/null || true
if [ -n "$ENDPOINT" ]; then
    ip rule del prio 900 to "$ENDPOINT" table main 2>/dev/null || true
fi
ip route flush table $TABLE 2>/dev/null || true

iptables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true
iptables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true
iptables -t mangle -D POSTROUTING -m mark --mark $FWMARK -p udp -j CONNMARK --save-mark 2>/dev/null || true
iptables -t mangle -D PREROUTING -p udp -j CONNMARK --restore-mark 2>/dev/null || true

echo "client routing cleaned"
CLIENT_TEARDOWN_EOF
chmod +x /usr/local/bin/amneziawg-client-teardown

# 6b. Server routing scripts (fwmark 51820 / table 51820, NO default in table)
log_info "Creating server routing scripts..."

cat > /usr/local/bin/amneziawg-setup-routing << 'SERVER_SETUP_EOF'
#!/bin/bash
# amneziawg-setup-routing - server side: fwmark + SSH marks, home subnet via VPN
set -euo pipefail
IFACE="$1"
FWMARK=51820
TABLE=51820

for i in $(seq 1 10); do
    if ip link show "$IFACE" >/dev/null 2>&1; then break; fi
    sleep 1
done

MAIN_DEV=$(ip route show table main default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
SERVER_IP=$(ip -4 addr show scope global dev "$MAIN_DEV" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^10\.' | head -1)
fi

SUBNET=$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
if [ -n "$SUBNET" ]; then
    NET=$(echo "$SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".0/24"}')
else
    NET="10.86.86.0/24"
fi

awg set "$IFACE" fwmark $FWMARK 2>/dev/null || true

ip rule add prio 10 from "$SERVER_IP" table main 2>/dev/null || true
ip rule add prio 20 to "$NET" table main 2>/dev/null || true

iptables -t mangle -C OUTPUT -p tcp --sport 22 -j MARK --set-mark $FWMARK 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true
iptables -t mangle -C OUTPUT -p tcp --dport 22 -j MARK --set-mark $FWMARK 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true

ip route flush table $TABLE 2>/dev/null || true
ip rule add prio 1000 not fwmark $FWMARK table $TABLE 2>/dev/null || true

iptables -t nat -C POSTROUTING -o amneziawg -s "$NET" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o amneziawg -s "$NET" -j MASQUERADE 2>/dev/null || true

iptables -t mangle -C POSTROUTING -m mark --mark $FWMARK -p udp -j CONNMARK --save-mark 2>/dev/null || iptables -t mangle -A POSTROUTING -m mark --mark $FWMARK -p udp -j CONNMARK --save-mark 2>/dev/null || true
iptables -t mangle -C PREROUTING -p udp -j CONNMARK --restore-mark 2>/dev/null || iptables -t mangle -A PREROUTING -p udp -j CONNMARK --restore-mark 2>/dev/null || true

sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1 || true

echo "server routing ok: iface=$IFACE subnet=$NET"
SERVER_SETUP_EOF
chmod +x /usr/local/bin/amneziawg-setup-routing

cat > /usr/local/bin/amneziawg-teardown-routing << 'SERVER_TEARDOWN_EOF'
#!/bin/bash
set -euo pipefail
IFACE="$1"
FWMARK=51820
TABLE=51820

SUBNET=$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
if [ -n "$SUBNET" ]; then
    NET=$(echo "$SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".0/24"}')
else
    NET="10.86.86.0/24"
fi

ip rule del prio 1000 not fwmark $FWMARK table $TABLE 2>/dev/null || true
ip rule del prio 20 to "$NET" table main 2>/dev/null || true
ip route flush table $TABLE 2>/dev/null || true

iptables -t nat -D POSTROUTING -o amneziawg -s "$NET" -j MASQUERADE 2>/dev/null || true
iptables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true
iptables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark $FWMARK 2>/dev/null || true
iptables -t mangle -D POSTROUTING -m mark --mark $FWMARK -p udp -j CONNMARK --save-mark 2>/dev/null || true
iptables -t mangle -D PREROUTING -p udp -j CONNMARK --restore-mark 2>/dev/null || true

echo "server routing cleaned"
SERVER_TEARDOWN_EOF
chmod +x /usr/local/bin/amneziawg-teardown-routing

# 7. Start/Stop scripts (both interfaces)
log_info "Creating Start/Stop scripts..."

cat > /usr/local/bin/Start-VPN << 'START_EOF'
#!/bin/bash
set -euo pipefail
echo "Starting VPN..."
systemctl start awg-quick@amneziawg
for i in $(seq 1 10); do
    if ip link show amneziawg >/dev/null 2>&1; then break; fi
    sleep 1
done
systemctl start amneziawg-client-routing@amneziawg
if systemctl list-unit-files awg-quick@awg0.service >/dev/null 2>&1 && [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
    systemctl start awg-quick@awg0
    for i in $(seq 1 10); do
        if ip link show awg0 >/dev/null 2>&1; then break; fi
        sleep 1
    done
    systemctl start amneziawg-routing@awg0
fi
echo "VPN started"
echo "External IP: $(curl -4 -s --max-time 10 ifconfig.me 2>/dev/null || echo 'unavailable')"
START_EOF
chmod +x /usr/local/bin/Start-VPN

cat > /usr/local/bin/Stop-VPN << 'STOP_EOF'
#!/bin/bash
set -euo pipefail
echo "Stopping VPN..."
systemctl stop amneziawg-client-routing@amneziawg 2>/dev/null || true
systemctl stop amneziawg-routing@awg0 2>/dev/null || true
systemctl stop awg-quick@amneziawg 2>/dev/null || true
systemctl stop awg-quick@awg0 2>/dev/null || true
echo "VPN stopped"
STOP_EOF
chmod +x /usr/local/bin/Stop-VPN

cp /usr/local/bin/Start-VPN /root/Start-VPN
cp /usr/local/bin/Stop-VPN /root/Stop-VPN
chmod +x /root/Start-VPN /root/Stop-VPN

# 8. Empty client config template (IPv4 only)
log_info "Creating empty config template..."
mkdir -p /etc/amnezia/amneziawg
cat > /etc/amnezia/amneziawg/amneziawg.conf << 'CONF_EOF'
# AmneziaWG Client Config
# FILL ALL FIELDS BELOW BEFORE RUNNING Start-VPN

[Interface]
PrivateKey = YOUR_PRIVATE_KEY_HERE
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
PublicKey = SERVER_PUBLIC_KEY_HERE
Endpoint = SERVER_IP:PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CONF_EOF

chmod 600 /etc/amnezia/amneziawg/amneziawg.conf

# 9. Enable client services for auto-start on boot
log_info "Enabling services for auto-start on boot..."
systemctl daemon-reload
systemctl enable awg-quick@amneziawg amneziawg-client-routing@amneziawg

log_info "Installation complete!"
echo ""
echo "=========================================="
echo "  USA-RU-KASKAD INSTALLED SUCCESSFULLY"
echo "=========================================="
echo ""
echo "Config template: /etc/amnezia/amneziawg/amneziawg.conf (EMPTY - fill it!)"
echo ""
echo "NEXT STEPS:"
echo "  1. Edit config:"
echo "     nano /etc/amnezia/amneziawg/amneziawg.conf"
echo "     Fill: PrivateKey, Address, DNS, Peer PublicKey, Endpoint"
echo ""
echo "  2. Start VPN:"
echo "     ~/Start-VPN"
echo ""
echo "  3. Verify:"
echo "     curl -4 ifconfig.me   # must show VPN IP"
echo "     ping -c 3 8.8.8.8"
echo ""
echo "After reboot the client tunnel starts automatically."
echo "(Server awg0, if configured later, is managed by amneziawg-server-install.sh)"
echo ""
echo "Manage:"
echo "  ~/Start-VPN / ~/Stop-VPN"
echo "=========================================="
