#!/bin/bash

# Configuration and Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
BIN_PATH="/usr/local/bin/sing-box"
SHORTCUT_BIN="/usr/local/bin/nb"

# Check root
[[ $EUID -ne 0 ]] && echo -e "${RED}Error: This script must be run as root!${PLAIN}" && exit 1

# Detect Arch
ARCH=$(uname -m)
case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *) echo -e "${RED}Unsupported architecture: $ARCH${PLAIN}"; exit 1 ;;
esac

# ----------------- Utility Functions -----------------

# Optimize System (BBR + Network)
optimize_system() {
    echo -e "${YELLOW}Optimizing system parameters and enabling BBR...${PLAIN}"
    
    # Enable BBR using sysctl.d to avoid polluting main config
    cat > /etc/sysctl.d/99-singbox-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_slow_start_after_idle=0
EOF
    sysctl -p /etc/sysctl.d/99-singbox-bbr.conf >/dev/null 2>&1
    
    # Configure Firewall (Basic)
    if command -v ufw >/dev/null; then
        ufw allow 80/tcp >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        ufw allow 443/udp >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1
        iptables -I INPUT -p udp --dport 443 -j ACCEPT >/dev/null 2>&1
        # Try to persist
        if command -v netfilter-persistent >/dev/null; then
            netfilter-persistent save >/dev/null 2>&1
        fi
    fi
    
    echo -e "${GREEN}System optimized!${PLAIN}"
}

# Install Dependencies
install_dependencies() {
    echo -e "${YELLOW}Installing dependencies...${PLAIN}"
    PM="apt-get"
    [[ -f /etc/redhat-release ]] && PM="yum"
    
    $PM update -y
    $PM install -y curl wget jq tar openssl socat cron qrencode
    
    if [[ "$PM" == "yum" ]]; then
        $PM install -y epel-release
        $PM install -y qrencode
    fi
}

# Get Version Info
get_latest_version() {
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
        VERSION="v1.12.17" # Stable fallback
    fi
    echo $VERSION
}

get_current_version() {
    if command -v sing-box &> /dev/null; then
        V=$(sing-box version | head -n 1 | awk '{print $3}')
        echo "${V}"
    else
        echo "None"
    fi
}

# Install Core
install_singbox() {
    LATEST=$(get_latest_version)
    echo -e "${YELLOW}Installing Sing-box ${LATEST} for ${ARCH}...${PLAIN}"
    
    FILENAME="sing-box-${LATEST#v}-linux-${ARCH}.tar.gz"
    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST}/${FILENAME}"
    
    wget -O /tmp/sing-box.tar.gz "$URL"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Download failed! Check your network.${PLAIN}"
        exit 1
    fi
    
    tar -zxvf /tmp/sing-box.tar.gz -C /tmp >/dev/null
    mv /tmp/sing-box-*/sing-box "$BIN_PATH"
    chmod +x "$BIN_PATH"
    
    mkdir -p /etc/sing-box
    rm -rf /tmp/sing-box*
}

# Setup SSL (ACME)
setup_ssl() {
    echo -e "${YELLOW}Configuring SSL...${PLAIN}"
    
    # Try to reuse existing valid domain
    if [[ -f $CONFIG_FILE ]]; then
        DOMAIN=$(jq -r '.inbounds[0].tls.server_name // empty' $CONFIG_FILE)
    fi
    
    if [[ -z "$DOMAIN" ]]; then
        read -p "Enter your domain: " DOMAIN
    else
        read -p "Use existing domain $DOMAIN? [y/N] " USE_EXIST
        if [[ ! "$USE_EXIST" =~ ^[Yy]$ ]]; then
            read -p "Enter new domain: " DOMAIN
        fi
    fi

    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}Domain is required!${PLAIN}"
        exit 1
    fi

    echo -e "${CYAN}Stopping conflicting services to free port 80...${PLAIN}"
    systemctl stop sing-box 2>/dev/null
    systemctl stop nginx 2>/dev/null
    
    # Install acme.sh if missing
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        source ~/.bashrc
    fi
    
    # Issue Checks
    ACME_BIN=~/.acme.sh/acme.sh
    if [[ -f ~/.acme.sh/${DOMAIN}_ecc/fullchain.cer ]] || [[ -f ~/.acme.sh/${DOMAIN}/fullchain.cer ]]; then
        echo -e "${GREEN}Valid certificate found, skipping issuance.${PLAIN}"
    else
        if ! $ACME_BIN --issue -d "$DOMAIN" --standalone --force; then
            echo -e "${RED}SSL issuance failed! Check if port 80 is open and domain $DOMAIN resolves to $(curl -s4 icanhazip.com).${PLAIN}"
            exit 1
        fi
    fi
    
    mkdir -p /etc/sing-box/certs
    $ACME_BIN --install-cert -d "$DOMAIN" \
        --fullchain-file /etc/sing-box/certs/fullchain.pem \
        --key-file /etc/sing-box/certs/private.key \
        --reloadcmd "systemctl restart sing-box"
        
    chmod 644 /etc/sing-box/certs/fullchain.pem
    chmod 644 /etc/sing-box/certs/private.key
}

# Generate Config
generate_config() {
    echo -e "${YELLOW}Generating configuration...${PLAIN}"
    
    # Preserve credentials if exist
    if [[ -f $CONFIG_FILE ]]; then
        USERNAME=$(jq -r '.inbounds[0].users[0].username // empty' $CONFIG_FILE)
        PASSWORD=$(jq -r '.inbounds[0].users[0].password // empty' $CONFIG_FILE)
    fi
    
    [[ -z "$USERNAME" ]] && USERNAME=$(openssl rand -hex 4)
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 8)
    PORT=443
    
    cat > $CONFIG_FILE <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "username": "$USERNAME",
          "password": "$PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/private.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    chmod 600 $CONFIG_FILE
}

# Systemd Service
setup_systemd() {
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$BIN_PATH run -c $CONFIG_FILE
Restart=always
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null
    systemctl restart sing-box
    
    # Create Shortcut
    cp "$0" $SHORTCUT_BIN 2>/dev/null
    chmod +x $SHORTCUT_BIN
}

# Display Info (QR & Links)
show_config() {
    if [[ ! -f $CONFIG_FILE ]]; then
        echo -e "${RED}Config not found!${PLAIN}"
        return
    fi
    
    DOMAIN=$(jq -r '.inbounds[0].tls.server_name' $CONFIG_FILE)
    USERNAME=$(jq -r '.inbounds[0].users[0].username' $CONFIG_FILE)
    PASSWORD=$(jq -r '.inbounds[0].users[0].password' $CONFIG_FILE)
    PORT=443
    
    URL_STD="https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}?padding=true#Naive_${DOMAIN}"
    URL_ROCKET="naive+https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}?padding=true#Naive_${DOMAIN}"
    
    clear
    echo -e "${BLUE}================ Client Configuration ================${PLAIN}"
    echo -e "${YELLOW}Protocol:${PLAIN} NaiveProxy (HTTPS)"
    echo -e "${YELLOW}Host/SNI:${PLAIN} ${DOMAIN}"
    echo -e "${YELLOW}Port:${PLAIN}     ${PORT}"
    echo -e "${YELLOW}Username:${PLAIN} ${USERNAME}"
    echo -e "${YELLOW}Password:${PLAIN} ${PASSWORD}"
    echo -e "${BLUE}======================================================${PLAIN}"
    echo ""
    echo -e "${GREEN}1. Standard Link (v2rayN):${PLAIN}"
    echo -e "${URL_STD}"
    echo ""
    echo -e "${GREEN}2. Shadowrocket Link:${PLAIN}"
    echo -e "${URL_ROCKET}"
    echo ""
    echo -e "${CYAN}Scan QR Code for Shadowrocket / v2rayN:${PLAIN}"
    qrencode -t ansiutf8 "${URL_ROCKET}"
}

# Uninstall
uninstall() {
    echo -e "${RED}Uninstalling Sing-box...${PLAIN}"
    systemctl stop sing-box
    systemctl disable sing-box
    rm -f $SERVICE_FILE
    systemctl daemon-reload
    rm -rf /etc/sing-box
    rm -f $BIN_PATH
    rm -f $SHORTCUT_BIN
    
    # Remove BBR config if added by us
    rm -f /etc/sysctl.d/99-singbox-bbr.conf
    
    echo -e "${GREEN}Uninstalled successfully!${PLAIN}"
}

# Get VPS Info
get_vps_info() {
    OS=$(grep -w "PRETTY_NAME" /etc/os-release | cut -d '"' -f 2)
    KERNEL=$(uname -r)
    ARCH=$(uname -m)
    IPV4=$(curl -s4 --max-time 2 icanhazip.com || echo "N/A")
    IPV6=$(curl -s6 --max-time 2 icanhazip.com || echo "N/A")
    
    # Check BBR
    TCP_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    
    # Check Service
    if systemctl is-active --quiet sing-box; then
        STATUS="${GREEN}Running${PLAIN}"
        PORT=$(jq -r '.inbounds[0].listen_port' $CONFIG_FILE 2>/dev/null || echo "443")
    else
        STATUS="${RED}Stopped${PLAIN}"
        PORT="N/A"
    fi
    
    echo -e "${BLUE}---------------- VPS Status ----------------${PLAIN}"
    echo -e "${YELLOW}System:${PLAIN}   ${OS}"
    echo -e "${YELLOW}Kernel:${PLAIN}   ${KERNEL}"
    echo -e "${YELLOW}Arch:${PLAIN}     ${ARCH}"
    echo -e "${YELLOW}BBR:${PLAIN}      ${TCP_CC}"
    echo -e "${YELLOW}IPv4:${PLAIN}     ${IPV4}"
    echo -e "${YELLOW}IPv6:${PLAIN}     ${IPV6}"
    echo -e "${YELLOW}Service:${PLAIN}  ${STATUS} (Port: ${PORT})"
    echo -e "${BLUE}--------------------------------------------${PLAIN}"
}

# Menu System
show_menu() {
    clear
    
    # Collect Info
    CURRENT_VER=$(get_current_version)
    LATEST_VER=$(get_latest_version)
    
    echo -e "${PURPLE}#############################################################${PLAIN}"
    echo -e "${PURPLE}#          Sing-box + NaiveProxy Ultimate Manager           #${PLAIN}"
    echo -e "${PURPLE}#############################################################${PLAIN}"
    
    # Display Status
    get_vps_info
    
    echo -e " ${YELLOW}Sing-box Ver:${PLAIN} ${CURRENT_VER} (Latest: ${LATEST_VER})"
    echo ""
    echo -e "${CYAN}--- Management ---${PLAIN}"
    echo -e "${YELLOW}1.${PLAIN} Install / Repair (Force Update)"
    echo -e "${YELLOW}2.${PLAIN} View Config & QR Code"
    echo -e "${YELLOW}3.${PLAIN} Restart Service"
    echo -e "${YELLOW}4.${PLAIN} View Runtime Logs"
    echo ""
    echo -e "${CYAN}--- System ---${PLAIN}"
    echo -e "${YELLOW}5.${PLAIN} Enable BBR Acceleration"
    echo -e "${YELLOW}6.${PLAIN} Uninstall"
    echo -e "${YELLOW}0.${PLAIN} Exit"
    echo ""
    
    read -p "Select [0-6]: " choice
    case $choice in
        1)
            optimize_system
            install_dependencies
            install_singbox
            setup_ssl
            generate_config
            setup_systemd
            show_config
            ;;
        2) show_config ;;
        3) 
            systemctl restart sing-box
            echo -e "${GREEN}Service restarted!${PLAIN}"
            sleep 1
            show_menu
            ;;
        4)
            journalctl -u sing-box -n 50 --no-pager
            read -p "Press Enter to return..."
            show_menu
            ;;
        5) 
            optimize_system
            read -p "Press Enter to return..."
            show_menu
            ;;
        6) uninstall ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

# Entry Point
if [[ $# > 0 ]]; then
    case $1 in
        install)
            optimize_system
            install_dependencies
            install_singbox
            setup_ssl
            generate_config
            setup_systemd
            ;;
        uninstall) uninstall ;;
        *) echo "Usage: $0 [install|uninstall]" ;;
    esac
else
    show_menu
fi
