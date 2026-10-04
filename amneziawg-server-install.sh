#!/bin/bash

# AmneziaWG server installer (modified for existing kernel module + tools)
# Based on: https://github.com/potap1978/amneziawg-install-SRC.sh

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

AMNEZIAWG_DIR="/etc/amnezia/amneziawg"

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script as root"
		exit 1
	fi
}

function checkVirt() {
	if [ "$(systemd-detect-virt)" == "openvz" ]; then
		echo "OpenVZ is not supported"
		exit 1
	fi

	if [ "$(systemd-detect-virt)" == "lxc" ]; then
		echo "LXC is not supported (yet)."
		echo "WireGuard can technically run in an LXC container,"
		echo "but the kernel module has to be installed on the host,"
		echo "the container has to be run with some specific parameters"
		echo "and only the tools need to be installed in the container."
		exit 1
	fi
}

function checkOS() {
	source /etc/os-release
	OS="${ID}"
	if [[ ${OS} == "debian" || ${OS} == "raspbian" ]]; then
		if [[ ${VERSION_ID} -lt 11 ]]; then
			echo "Your version of Debian (${VERSION_ID}) is not supported. Please use Debian 11 Bullseye or later"
			exit 1
		fi
		OS=debian
	elif [[ ${OS} == "ubuntu" ]]; then
		RELEASE_YEAR=$(echo "${VERSION_ID}" | cut -d'.' -f1)
		if [[ ${RELEASE_YEAR} -lt 20 ]]; then
			echo "Your version of Ubuntu (${VERSION_ID}) is not supported. Please use Ubuntu 20.04 or later"
			exit 1
		fi
	elif [[ ${OS} == "fedora" ]]; then
		if [[ ${VERSION_ID} -lt 39 ]]; then
			echo "Your version of Fedora (${VERSION_ID}) is not supported. Please use Fedora 39 or later"
			exit 1
		fi
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 7* ]] || [[ ${VERSION_ID} == 8* ]]; then
			echo "Your version of CentOS (${VERSION_ID}) is not supported. Please use CentOS 9 or later"
			exit 1
		fi
	else
		echo "Looks like you aren't running this installer on a Debian, Ubuntu, Fedora, CentOS, AlmaLinux or Rocky Linux system"
		exit 1
	fi
}

function getHomeDirForClient() {
	local CLIENT_NAME=$1

	if [ -z "${CLIENT_NAME}" ]; then
		echo "Error: getHomeDirForClient() requires a client name as argument"
		exit 1
	fi

	if [ -e "/home/${CLIENT_NAME}" ]; then
		HOME_DIR="/home/${CLIENT_NAME}"
	elif [ "${SUDO_USER}" ]; then
		if [ "${SUDO_USER}" == "root" ]; then
			HOME_DIR="/root"
		else
			HOME_DIR="/home/${SUDO_USER}"
		fi
	else
		HOME_DIR="/root"
	fi

	echo "$HOME_DIR"
}

function initialCheck() {
	isRoot
	checkVirt
	checkOS
}

function checkExistingInstallation() {
	# Check if kernel module is loaded
	if lsmod | grep -q "amneziawg"; then
		echo -e "${GREEN}AmneziaWG kernel module already loaded${NC}"
		KERNEL_MODULE_EXISTS=1
	else
		KERNEL_MODULE_EXISTS=0
	fi

	# Check if tools are installed
	if command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1; then
		echo -e "${GREEN}AmneziaWG tools already installed${NC}"
		TOOLS_EXIST=1
	else
		TOOLS_EXIST=0
	fi
}

function installKernelModuleAndTools() {
	echo "=== Installing AmneziaWG kernel module and tools ==="

	# Install dependencies
	apt update -y
	CURRENT_KERNEL=$(uname -r)
	apt install -y git curl mc zip unzip resolvconf build-essential ncurses-dev xz-utils libssl-dev bc flex libelf-dev bison make mokutil sbsigntool shim-signed secureboot-db dkms qrencode iptables linux-headers-${CURRENT_KERNEL}

	# Build kernel module
	mkdir -p ~/awg-src
	cd ~/awg-src || exit

	echo "Cloning amneziawg-linux-kernel-module..."
	if [ -d amneziawg-linux-kernel-module ]; then
		rm -rf amneziawg-linux-kernel-module
	fi
	git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git

	cd ~/awg-src/amneziawg-linux-kernel-module/src/ || exit
	make dkms-install
	dkms add -m amneziawg -v 1.0.0
	dkms build -m amneziawg -v 1.0.0
	dkms install -m amneziawg -v 1.0.0

	modprobe amneziawg
	if ! lsmod | grep -q "amneziawg"; then
		echo -e "${RED}Kernel module failed to load${NC}"
		exit 1
	fi

	# Build tools
	cd ~/awg-src || exit
	if [ -d amneziawg-tools ]; then
		rm -rf amneziawg-tools
	fi
	git clone https://github.com/amnezia-vpn/amneziawg-tools.git
	cd amneziawg-tools/src/ || exit
	make -j$(nproc)
	make install PREFIX=/usr

	log_info "Kernel module and tools installed successfully"
}

function installQuestions() {
	echo "AmneziaWG server installer"
	echo ""
	echo "I need to ask you a few questions before starting the setup."
	echo "You can keep the default options and just press enter if you are ok with them."
	echo ""

	SERVER_PUB_IP=$(curl -s ipv4.icanhazip.com)
	if [[ -z ${SERVER_PUB_IP} ]]; then
		SERVER_PUB_IP=$(curl -s ipv6.icanhazip.com)
	fi
	read -rp "Public IPv4 or IPv6 address or domain: " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP

	SERVER_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
	until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_]+$ ]]; do
		read -rp "Public interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC
	done

	until [[ ${SERVER_AWG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_AWG_NIC} -lt 16 ]]; do
		read -rp "AmneziaWG interface name: " -e -i awg0 SERVER_AWG_NIC
	done

	until [[ ${SERVER_AWG_IPV4} =~ ^([0-9]{1,3}\.){3} ]]; do
		read -rp "Server AmneziaWG IPv4: " -e -i 10.66.66.1 SERVER_AWG_IPV4
	done

	until [[ ${SERVER_AWG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
		read -rp "Server AmneziaWG IPv6: " -e -i fd42:42:42::1 SERVER_AWG_IPV6
	done

	RANDOM_PORT=$(shuf -i49152-65535 -n1)
	until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 1 ] && [ "${SERVER_PORT}" -le 65535 ]; do
		read -rp "Server AmneziaWG port [1-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT
	done

	until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "First DNS resolver to use for the clients: " -e -i 1.1.1.1 CLIENT_DNS_1
	done
	until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "Second DNS resolver to use for the clients (optional): " -e -i 1.0.0.1 CLIENT_DNS_2
		if [[ ${CLIENT_DNS_2} == "" ]]; then
			CLIENT_DNS_2="${CLIENT_DNS_1}"
		fi
	done

	until [[ ${ALLOWED_IPS} =~ ^.+$ ]]; do
		echo -e "\nAmneziaWG uses a parameter called AllowedIPs to determine what is routed over the VPN."
		read -rp "Allowed IPs list for generated clients (leave default to route everything): " -e -i '0.0.0.0/0,::/0' ALLOWED_IPS
		if [[ ${ALLOWED_IPS} == "" ]]; then
			ALLOWED_IPS="0.0.0.0/0,::/0"
		fi
	done

	until [[ ${KEEPALIVE} =~ ^[0-9]+$ ]] && [ "${KEEPALIVE}" -ge 0 ] && [ "${KEEPALIVE}" -le 65535 ]; do
		read -rp "$(echo -e "${GREEN}Keepalive interval${NC}") [0-65535]: " -e -i 15 KEEPALIVE
	done

	RANDOM_AWG_JC=$(shuf -i3-10 -n1)
	until [[ ${SERVER_AWG_JC} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_JC} >= 1 )) && (( ${SERVER_AWG_JC} <= 128 )); do
		read -rp "Server AmneziaWG Jc [1-128]: " -e -i ${RANDOM_AWG_JC} SERVER_AWG_JC
	done

	readJminAndJmax
	until [ "${SERVER_AWG_JMIN}" -le "${SERVER_AWG_JMAX}" ]; do
		echo "AmneziaWG require Jmin < Jmax"
		readJminAndJmax
	done

	generateS1AndS2
	while (( ${RANDOM_AWG_S1} + 56 == ${RANDOM_AWG_S2} )); do
		generateS1AndS2
	done
	readS1AndS2
	while (( ${SERVER_AWG_S1} + 56 == ${SERVER_AWG_S2} )); do
		echo "AmneziaWG require S1 + 56 <> S2"
		readS1AndS2
	done

	generateH1AndH2AndH3AndH4
	while (( ${RANDOM_AWG_H1} == ${RANDOM_AWG_H2} )) || (( ${RANDOM_AWG_H1} == ${RANDOM_AWG_H3} )) || (( ${RANDOM_AWG_H1} == ${RANDOM_AWG_H4} )) || (( ${RANDOM_AWG_H2} == ${RANDOM_AWG_H3} )) || (( ${RANDOM_AWG_H2} == ${RANDOM_AWG_H4} )) || (( ${RANDOM_AWG_H3} == ${RANDOM_AWG_H4} )); do
		generateH1AndH2AndH3AndH4
	done
	readH1AndH2AndH3AndH4
	while (( ${SERVER_AWG_H1} == ${SERVER_AWG_H2} )) || (( ${SERVER_AWG_H1} == ${SERVER_AWG_H3} )) || (( ${SERVER_AWG_H1} == ${SERVER_AWG_H4} )) || (( ${SERVER_AWG_H2} == ${SERVER_AWG_H3} )) || (( ${SERVER_AWG_H2} == ${SERVER_AWG_H4} )) || (( ${SERVER_AWG_H3} == ${SERVER_AWG_H4} )); do
		echo "AmneziaWG require H1 and H2 and H3 and H4 be different"
		readH1AndH2AndH3AndH4
	done

	echo ""
	echo "Okay, that was all I needed. We are ready to setup your AmneziaWG server now."
	echo "You will be able to generate a client at the end of the installation."
	read -n1 -r -p "Press any key to continue..."
}

function readJminAndJmax() {
	SERVER_AWG_JMIN=0
	SERVER_AWG_JMAX=0
	until [[ ${SERVER_AWG_JMIN} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_JMIN} >= 1 )) && (( ${SERVER_AWG_JMIN} <= 1280 )); do
		read -rp "Server AmneziaWG Jmin [1-1280]: " -e -i 50 SERVER_AWG_JMIN
	done
	until [[ ${SERVER_AWG_JMAX} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_JMAX} >= 1 )) && (( ${SERVER_AWG_JMAX} <= 1280 )); do
		read -rp "Server AmneziaWG Jmax [1-1280]: " -e -i 1000 SERVER_AWG_JMAX
	done
}

function generateS1AndS2() {
	RANDOM_AWG_S1=$(shuf -i15-150 -n1)
	RANDOM_AWG_S2=$(shuf -i15-150 -n1)
}

function readS1AndS2() {
	SERVER_AWG_S1=0
	SERVER_AWG_S2=0
	until [[ ${SERVER_AWG_S1} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_S1} >= 15 )) && (( ${SERVER_AWG_S1} <= 150 )); do
		read -rp "Server AmneziaWG S1 [15-150]: " -e -i ${RANDOM_AWG_S1} SERVER_AWG_S1
	done
	until [[ ${SERVER_AWG_S2} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_S2} >= 15 )) && (( ${SERVER_AWG_S2} <= 150 )); do
		read -rp "Server AmneziaWG S2 [15-150]: " -e -i ${RANDOM_AWG_S2} SERVER_AWG_S2
	done
}

function generateH1AndH2AndH3AndH4() {
	RANDOM_AWG_H1=$(shuf -i5-2147483647 -n1)
	RANDOM_AWG_H2=$(shuf -i5-2147483647 -n1)
	RANDOM_AWG_H3=$(shuf -i5-2147483647 -n1)
	RANDOM_AWG_H4=$(shuf -i5-2147483647 -n1)
}

function readH1AndH2AndH3AndH4() {
	SERVER_AWG_H1=0
	SERVER_AWG_H2=0
	SERVER_AWG_H3=0
	SERVER_AWG_H4=0
	until [[ ${SERVER_AWG_H1} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_H1} >= 5 )) && (( ${SERVER_AWG_H1} <= 2147483647 )); do
		read -rp "Server AmneziaWG H1 [5-2147483647]: " -e -i ${RANDOM_AWG_H1} SERVER_AWG_H1
	done
	until [[ ${SERVER_AWG_H2} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_H2} >= 5 )) && (( ${SERVER_AWG_H2} <= 2147483647 )); do
		read -rp "Server AmneziaWG H2 [5-2147483647]: " -e -i ${RANDOM_AWG_H2} SERVER_AWG_H2
	done
	until [[ ${SERVER_AWG_H3} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_H3} >= 5 )) && (( ${SERVER_AWG_H3} <= 2147483647 )); do
		read -rp "Server AmneziaWG H3 [5-2147483647]: " -e -i ${RANDOM_AWG_H3} SERVER_AWG_H3
	done
	until [[ ${SERVER_AWG_H4} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_H4} >= 5 )) && (( ${SERVER_AWG_H4} <= 2147483647 )); do
		read -rp "Server AmneziaWG H4 [5-2147483647]: " -e -i ${RANDOM_AWG_H4} SERVER_AWG_H4
	done
}

function installAmneziaWG() {
	# Check existing installation first
	checkExistingInstallation

	# Install kernel module and tools only if needed
	if [[ ${KERNEL_MODULE_EXISTS} -eq 0 || ${TOOLS_EXIST} -eq 0 ]]; then
		installKernelModuleAndTools
	else
		echo -e "${GREEN}Kernel module and tools already installed, skipping...${NC}"
	fi

	# Run setup questions
	installQuestions

	# Setup server config
	setupServerConfig
}

function setupServerConfig() {
	SERVER_AWG_CONF="${AMNEZIAWG_DIR}/${SERVER_AWG_NIC}.conf"

	SERVER_PRIV_KEY=$(awg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | awg pubkey)

	# Save WireGuard settings
	echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_AWG_NIC=${SERVER_AWG_NIC}
SERVER_AWG_IPV4=${SERVER_AWG_IPV4}
SERVER_AWG_IPV6=${SERVER_AWG_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}
KEEPALIVE=${KEEPALIVE}
SERVER_AWG_JC=${SERVER_AWG_JC}
SERVER_AWG_JMIN=${SERVER_AWG_JMIN}
SERVER_AWG_JMAX=${SERVER_AWG_JMAX}
SERVER_AWG_S1=${SERVER_AWG_S1}
SERVER_AWG_S2=${SERVER_AWG_S2}
SERVER_AWG_H1=${SERVER_AWG_H1}
SERVER_AWG_H2=${SERVER_AWG_H2}
SERVER_AWG_H3=${SERVER_AWG_H3}
SERVER_AWG_H4=${SERVER_AWG_H4}" >"${AMNEZIAWG_DIR}/params"

	# Add server interface
	echo "[Interface]
Address = ${SERVER_AWG_IPV4}/24,${SERVER_AWG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
Jc = ${SERVER_AWG_JC}
Jmin = ${SERVER_AWG_JMIN}
Jmax = ${SERVER_AWG_JMAX}
S1 = ${SERVER_AWG_S1}
S2 = ${SERVER_AWG_S2}
H1 = ${SERVER_AWG_H1}
H2 = ${SERVER_AWG_H2}
H3 = ${SERVER_AWG_H3}
H4 = ${SERVER_AWG_H4}" >"${SERVER_AWG_CONF}"

	if pgrep firewalld; then
		FIREWALLD_IPV4_ADDRESS=$(echo "${SERVER_AWG_IPV4}" | cut -d"." -f1-3)".0"
		FIREWALLD_IPV6_ADDRESS=$(echo "${SERVER_AWG_IPV6}" | sed 's/:[^:]*$/:0/')
		echo "PostUp = firewall-cmd --add-port ${SERVER_PORT}/udp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --add-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --remove-port ${SERVER_PORT}/udp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --remove-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'" >>"${SERVER_AWG_CONF}"
	else
		echo "PostUp = iptables -A FORWARD -i ${SERVER_AWG_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_AWG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostUp = ip6tables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = ip6tables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostUp = ip6tables -I FORWARD -i ${SERVER_AWG_NIC} -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${SERVER_AWG_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_AWG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = ip6tables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = ip6tables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostDown = ip6tables -D FORWARD -i ${SERVER_AWG_NIC} -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"${SERVER_AWG_CONF}"
	fi

	# Enable routing on the server
	echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" >/etc/sysctl.d/awg.conf

	sysctl --system

	systemctl start "awg-quick@${SERVER_AWG_NIC}"
	systemctl enable "awg-quick@${SERVER_AWG_NIC}"

	newClient
	echo -e "${GREEN}If you want to add more clients, you simply need to run this script another time!${NC}"

	# Check if AmneziaWG is running
	systemctl is-active --quiet "awg-quick@${SERVER_AWG_NIC}"
	AWG_RUNNING=$?

	if [[ ${AWG_RUNNING} -ne 0 ]]; then
		echo -e "\n${RED}WARNING: AmneziaWG does not seem to be running.${NC}"
		echo -e "${ORANGE}You can check if AmneziaWG is running with: systemctl status awg-quick@${SERVER_AWG_NIC}${NC}"
		echo -e "${ORANGE}If you get something like \"Cannot find device ${SERVER_AWG_NIC}\", please reboot!${NC}"
	else
		echo -e "\n${GREEN}AmneziaWG is running.${NC}"
		echo -e "${GREEN}You can check the status of AmneziaWG with: systemctl status awg-quick@${SERVER_AWG_NIC}\n\n${NC}"
		echo -e "${ORANGE}If you don't have internet connectivity from your client, try to reboot the server.${NC}"
	fi
}

function newClient() {
	if [[ ${SERVER_PUB_IP} =~ .*:.* ]]; then
		if [[ ${SERVER_PUB_IP} != *"["* ]] || [[ ${SERVER_PUB_IP} != *"]"* ]]; then
			SERVER_PUB_IP="[${SERVER_PUB_IP}]"
		fi
	fi
	ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

	echo ""
	echo "Client configuration"
	echo ""

	until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
		read -rp "Client name: " -e CLIENT_NAME
		CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}\$" "${SERVER_AWG_CONF}")

		if [[ ${CLIENT_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified name was already created, please choose another name.${NC}"
			echo ""
		fi
	done

	for DOT_IP in {2..254}; do
		DOT_EXISTS=$(grep -c "${SERVER_AWG_IPV4::-1}${DOT_IP}" "${SERVER_AWG_CONF}")
		if [[ ${DOT_EXISTS} == '0' ]]; then
			break
		fi
	done

	if [[ ${DOT_EXISTS} == '1' ]]; then
		echo ""
		echo "The subnet configured supports only 253 clients."
		exit 1
	fi

	BASE_IP=$(echo "$SERVER_AWG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
	until [[ ${IPV4_EXISTS} == '0' ]]; do
		read -rp "Client AmneziaWG IPv4: ${BASE_IP}." -e -i "${DOT_IP}" DOT_IP
		CLIENT_AWG_IPV4="${BASE_IP}.${DOT_IP}"
		IPV4_EXISTS=$(grep -c "$CLIENT_AWG_IPV4/32" "${SERVER_AWG_CONF}")

		if [[ ${IPV4_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified IPv4 was already created, please choose another IPv4.${NC}"
			echo ""
		fi
	done

	BASE_IP=$(echo "$SERVER_AWG_IPV6" | awk -F '::' '{ print $1 }')
	until [[ ${IPV6_EXISTS} == '0' ]]; do
		read -rp "Client AmneziaWG IPv6: ${BASE_IP}::" -e -i "${DOT_IP}" DOT_IP
		CLIENT_AWG_IPV6="${BASE_IP}::${DOT_IP}"
		IPV6_EXISTS=$(grep -c "${CLIENT_AWG_IPV6}/128" "${SERVER_AWG_CONF}")

		if [[ ${IPV6_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified IPv6 was already created, please choose another IPv6.${NC}"
			echo ""
		fi
	done

	CLIENT_PRIV_KEY=$(awg genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | awg pubkey)
	CLIENT_PRE_SHARED_KEY=$(awg genpsk)

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")

	echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_AWG_IPV4}/32,${CLIENT_AWG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}
Jc = ${SERVER_AWG_JC}
Jmin = ${SERVER_AWG_JMIN}
Jmax = ${SERVER_AWG_JMAX}
S1 = ${SERVER_AWG_S1}
S2 = ${SERVER_AWG_S2}
H1 = ${SERVER_AWG_H1}
H2 = ${SERVER_AWG_H2}
H3 = ${SERVER_AWG_H3}
H4 = ${SERVER_AWG_H4}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}" >"${HOME_DIR}/${SERVER_AWG_NIC}-client-${CLIENT_NAME}.conf"

	if [[ ${KEEPALIVE} -ne 0 ]]; then
		echo "PersistentKeepalive = ${KEEPALIVE}" >>"${HOME_DIR}/${SERVER_AWG_NIC}-client-${CLIENT_NAME}.conf"
	fi

	echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_AWG_IPV4}/32,${CLIENT_AWG_IPV6}/128" >>"${SERVER_AWG_CONF}"

	awg syncconf "${SERVER_AWG_NIC}" <(awg-quick strip "${SERVER_AWG_NIC}")

	if command -v qrencode &>/dev/null; then
		echo -e "${GREEN}\nHere is your client config file as a QR Code:\n${NC}"
		qrencode -t ansiutf8 -l L <"${HOME_DIR}/${SERVER_AWG_NIC}-client-${CLIENT_NAME}.conf"
		echo ""
	fi

	echo -e "${GREEN}Your client config file is in ${HOME_DIR}/${SERVER_AWG_NIC}-client-${CLIENT_NAME}.conf${NC}"
}

function listClients() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${SERVER_AWG_CONF}")
	if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
		echo ""
		echo "You have no existing clients!"
		exit 1
	fi

	grep -E "^### Client" "${SERVER_AWG_CONF}" | cut -d ' ' -f 3 | nl -s ') '
}

function revokeClient() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${SERVER_AWG_CONF}")
	if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
		echo ""
		echo "You have no existing clients!"
		exit 1
	fi

	echo ""
	echo "Select the existing client you want to revoke"
	grep -E "^### Client" "${SERVER_AWG_CONF}" | cut -d ' ' -f 3 | nl -s ') '
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
		if [[ ${CLIENT_NUMBER} == '1' ]]; then
			read -rp "Select one client [1]: " CLIENT_NUMBER
		else
			read -rp "Select one client [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
		fi
	done

	CLIENT_NAME=$(grep -E "^### Client" "${SERVER_AWG_CONF}" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

	sed -i "/^### Client ${CLIENT_NAME}\$/,/^$/d" "${SERVER_AWG_CONF}"

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	rm -f "${HOME_DIR}/${SERVER_AWG_NIC}-client-${CLIENT_NAME}.conf"

	awg syncconf "${SERVER_AWG_NIC}" <(awg-quick strip "${SERVER_AWG_NIC}")
}

function uninstallAmneziaWG() {
    echo ""
    echo -e "\n${RED}WARNING: This will completely uninstall AmneziaWG and remove ALL configuration files!${NC}"
    echo -e "${ORANGE}Including all server and client configurations!${NC}"
    echo -e "${ORANGE}Please make sure you have backups if needed.\n${NC}"
    read -rp "Do you really want to completely remove AmneziaWG? [y/n]: " -e REMOVE
    REMOVE=${REMOVE:-n}
    if [[ $REMOVE == 'y' ]]; then
        checkOS

        systemctl stop "awg-quick@${SERVER_AWG_NIC}" 2>/dev/null
        systemctl disable "awg-quick@${SERVER_AWG_NIC}" 2>/dev/null

        rm -f /etc/sysctl.d/awg.conf 2>/dev/null
        sysctl --system 2>/dev/null

        if [ -f "${SERVER_AWG_CONF}" ]; then
            CLIENTS=$(grep -E "^### Client" "${SERVER_AWG_CONF}" | cut -d ' ' -f 3)
            for CLIENT in $CLIENTS; do
                HOME_DIR=$(getHomeDirForClient "${CLIENT}")
                CLIENT_FILE="${HOME_DIR}/${SERVER_AWG_NIC}-client-${CLIENT}.conf"
                if [ -f "${CLIENT_FILE}" ]; then
                    echo "Removing client config: ${CLIENT_FILE}"
                    rm -f "${CLIENT_FILE}"
                fi
            done
        fi

        rm -rf "${AMNEZIAWG_DIR}"/* 2>/dev/null

        rm -f /usr/bin/awg 2>/dev/null
        rm -f /usr/bin/awg-quick 2>/dev/null
        rm -f /usr/local/bin/awg 2>/dev/null
        rm -f /usr/local/bin/awg-quick 2>/dev/null

        dkms remove -m amneziawg -v 1.0.0 --all 2>/dev/null
        rm -rf /usr/src/amneziawg-1.0.0 2>/dev/null
        rm -rf ~/awg-src 2>/dev/null

        apt-get remove --purge -y amneziawg amneziawg-tools 2>/dev/null
        apt-get autoremove -y 2>/dev/null
        
        if [[ -e /etc/apt/sources.list.d/ubuntu.sources ]]; then
            rm -f /etc/apt/sources.list.d/amneziawg.sources 2>/dev/null
        else
            rm -f /etc/apt/sources.list.d/amneziawg.list 2>/dev/null
        fi
        
        apt-get update -y 2>/dev/null

        REMNANTS=0
        if [ -f "/usr/bin/awg" ] || [ -f "/usr/bin/awg-quick" ] || \
           [ -f "/usr/local/bin/awg" ] || [ -f "/usr/local/bin/awg-quick" ]; then
            echo -e "${ORANGE}Warning: Some binaries were not removed${NC}"
            REMNANTS=1
        fi
        
        if systemctl is-active --quiet "awg-quick@${SERVER_AWG_NIC}" 2>/dev/null; then
            echo -e "${ORANGE}Warning: Service still appears to be running${NC}"
            REMNANTS=1
        fi
        
        if [ "$REMNANTS" -eq 0 ]; then
            echo -e "${GREEN}AmneziaWG has been completely removed from your system.${NC}"
            exit 0
        else
            echo -e "${ORANGE}Some components might remain. You may need to remove them manually.${NC}"
            exit 1
        fi
    else
        echo ""
        echo "Uninstallation cancelled."
    fi
}

function loadParams() {
	source "${AMNEZIAWG_DIR}/params"
	SERVER_AWG_CONF="${AMNEZIAWG_DIR}/${SERVER_AWG_NIC}.conf"
}

function showClientQR() {
    NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${SERVER_AWG_CONF}")
    if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
        echo ""
        echo "You have no existing clients!"
        exit 1
    fi

    echo ""
    echo "Select the client to show QR code"
    grep -E "^### Client" "${SERVER_AWG_CONF}" | cut -d ' ' -f 3 | nl -s ') '
    until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
        if [[ ${CLIENT_NUMBER} == '1' ]]; then
            read -rp "Select one client [1]: " CLIENT_NUMBER
        else
            read -rp "Select one client [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
        fi
    done

    CLIENT_NAME=$(grep -E "^### Client" "${SERVER_AWG_CONF}" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

    HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")

    if [[ -f "${HOME_DIR}/${SERVER_AWG_NIC}-client-${CLIENT_NAME}.conf" ]]; then
        echo -e "${GREEN}\nHere is your client config file as a QR Code:\n${NC}"
        qrencode -t ansiutf8 -l L <"${HOME_DIR}/${SERVER_AWG_NIC}-client-${CLIENT_NAME}.conf"
        echo ""
    else
        echo -e "${RED}Client config file not found!${NC}"
    fi
}

function backupSettings() {
    echo ""
    echo "Creating a backup of all AmneziaWG settings..."

    BACKUP_DIR="/etc/amnezia/backups"
    mkdir -p "${BACKUP_DIR}"

    BACKUP_FILE="${BACKUP_DIR}/amneziawg_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "${BACKUP_FILE}" -C "${AMNEZIAWG_DIR}" .

    echo -e "${GREEN}Backup created successfully: ${BACKUP_FILE}${NC}"
}

function restoreSettings() {
    echo ""
	echo "Положи ФАЙЛ БЭКАПА в /etc/amnezia/backups/"
	echo ""
    echo "Restoring AmneziaWG settings from a backup..."

    BACKUP_DIR="/etc/amnezia/backups"
    if [[ ! -d "${BACKUP_DIR}" ]]; then
        echo -e "${RED}No backups found in ${BACKUP_DIR}${NC}"
        return
    fi

    local backups=($(ls "${BACKUP_DIR}"/*.tar.gz 2>/dev/null))
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo -e "${RED}No backups found in ${BACKUP_DIR}${NC}"
        return
    fi

    for i in "${!backups[@]}"; do
        echo "  $((i+1))) ${backups[$i]}"
    done

    until [[ ${BACKUP_INDEX} =~ ^[0-9]+$ && ${BACKUP_INDEX} -ge 1 && ${BACKUP_INDEX} -le ${#backups[@]} ]]; do
        read -rp "Select a backup to restore [1-${#backups[@]}]: " BACKUP_INDEX
    done

    SELECTED_BACKUP="${backups[$((BACKUP_INDEX-1))]}"

    echo "Restoring from ${SELECTED_BACKUP}..."
    tar -xzf "${SELECTED_BACKUP}" -C "${AMNEZIAWG_DIR}" --overwrite

    echo -e "${GREEN}Settings restored successfully from ${SELECTED_BACKUP}${NC}"
}

function manageMenu() {
    echo "AmneziaWG server installer"
    echo ""
    echo "It looks like AmneziaWG is already installed."
    echo ""
    echo "What do you want to do?"
    echo "   1) Add a new user"
    echo "   2) List all users"
    echo "   3) Revoke existing user"
    echo "   4) Show client QR code"
    echo "   5) Uninstall AmneziaWG"
    echo "   6) Backup settings"
    echo "   7) Restore settings"
    echo "   8) Exit"
    until [[ ${MENU_OPTION} =~ ^[1-8]$ ]]; do
        read -rp "Select an option [1-8]: " MENU_OPTION
    done
    case "${MENU_OPTION}" in
    1)
        newClient
        ;;
    2)
        listClients
        ;;
    3)
        revokeClient
        ;;
    4)
        showClientQR
        ;;
    5)
        uninstallAmneziaWG
        ;;
    6)
        backupSettings
        ;;
    7)
        restoreSettings
        ;;
    8)
        exit 0
        ;;
    esac
}

initialCheck

# Check existing installation
checkExistingInstallation

if [[ -e "${AMNEZIAWG_DIR}/params" ]]; then
	loadParams
	manageMenu
else
	installAmneziaWG
fi