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
detect_arch() {
    local ARCH_RAW=$(uname -m)
    case $ARCH_RAW in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) echo -e "${RED}Unsupported architecture: $ARCH_RAW${PLAIN}"; exit 1 ;;
    esac
}
detect_arch

# ----------------- Utility Functions -----------------

# Optimize System (BBR + Network)
optimize_system() {
    echo -e "${YELLOW}Optimizing system parameters and enabling BBR...${PLAIN}"
    
    cat > /etc/sysctl.d/99-singbox-vps.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_slow_start_after_idle=0
EOF
    sysctl -p /etc/sysctl.d/99-singbox-vps.conf >/dev/null 2>&1
    
    # Firewall
    if command -v ufw >/dev/null; then
        ufw allow 80/tcp >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        ufw allow 443/udp >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1
        iptables -I INPUT -p udp --dport 443 -j ACCEPT >/dev/null 2>&1
        iptables -I INPUT -p udp --dport 10000:65535 -j ACCEPT >/dev/null 2>&1 # For Hy2 ports
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

# Version Control
get_latest_version() {
    local VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    [[ -z "$VERSION" || "$VERSION" == "null" ]] && VERSION="v1.12.17"
    echo $VERSION
}

get_current_version() {
    if command -v sing-box &> /dev/null; then
        sing-box version | head -n 1 | awk '{print $3}'
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
    [[ $? -ne 0 ]] && echo -e "${RED}Download failed!${PLAIN}" && exit 1
    
    tar -zxvf /tmp/sing-box.tar.gz -C /tmp >/dev/null
    mv /tmp/sing-box-*/sing-box "$BIN_PATH"
    chmod +x "$BIN_PATH"
    
    mkdir -p /etc/sing-box
    rm -rf /tmp/sing-box*
}

# Setup SSL (ACME)
setup_ssl() {
    echo -e "${YELLOW}Configuring SSL...${PLAIN}"
    
    if [[ -f $CONFIG_FILE ]]; then
        DOMAIN=$(jq -r '.inbounds[0].tls.server_name // empty' $CONFIG_FILE)
    fi
    
    if [[ -z "$DOMAIN" ]]; then
        read -p "Enter your domain: " DOMAIN
    else
        read -p "Use existing domain $DOMAIN? [y/N] " USE_EXIST
        [[ ! "$USE_EXIST" =~ ^[Yy]$ || -z "$USE_EXIST" ]] && read -p "Enter new domain: " DOMAIN
    fi

    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}Domain is required!${PLAIN}"
        exit 1
    fi

    echo -e "${CYAN}Cleaning port 80...${PLAIN}"
    systemctl stop sing-box 2>/dev/null
    systemctl stop nginx 2>/dev/null
    
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        source ~/.bashrc
    fi
    
    ACME_BIN=~/.acme.sh/acme.sh
    if [[ ! -f ~/.acme.sh/${DOMAIN}_ecc/fullchain.cer ]] && [[ ! -f ~/.acme.sh/${DOMAIN}/fullchain.cer ]]; then
        if ! $ACME_BIN --issue -d "$DOMAIN" --standalone --force; then
            echo -e "${RED}SSL failed! Check port 80.${PLAIN}"
            exit 1
        fi
    else
        echo -e "${GREEN}Using existing certificate...${PLAIN}"
    fi
    
    mkdir -p /etc/sing-box/certs
    $ACME_BIN --install-cert -d "$DOMAIN" \
        --fullchain-file /etc/sing-box/certs/fullchain.pem \
        --key-file /etc/sing-box/certs/private.key
}

# Generate Config (Naive + Hysteria2)
generate_config() {
    echo -e "${YELLOW}Generating configuration...${PLAIN}"
    
    # Credentials
    if [[ -f $CONFIG_FILE ]]; then
        NAIVE_USER=$(jq -r '.inbounds[] | select(.type=="naive") | .users[0].username // empty' $CONFIG_FILE)
        NAIVE_PASS=$(jq -r '.inbounds[] | select(.type=="naive") | .users[0].password // empty' $CONFIG_FILE)
        HY2_PASS=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password // empty' $CONFIG_FILE)
        HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' $CONFIG_FILE)
    fi
    
    [[ -z "$NAIVE_USER" ]] && NAIVE_USER=$(openssl rand -hex 4)
    [[ -z "$NAIVE_PASS" ]] && NAIVE_PASS=$(openssl rand -hex 8)
    [[ -z "$HY2_PASS" ]] && HY2_PASS=$(openssl rand -hex 8)
    [[ -z "$HY2_PORT" ]] && HY2_PORT=$(shuf -i 10000-65000 -n 1)
    
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
      "listen_port": 443,
      "users": [
        {
          "username": "$NAIVE_USER",
          "password": "$NAIVE_PASS"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/private.key"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "password": "$HY2_PASS"
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
}

# Display Info
show_config() {
    [[ ! -f $CONFIG_FILE ]] && echo -e "${RED}No config!${PLAIN}" && return
    
    DOMAIN=$(jq -r '.inbounds[] | select(.type=="naive") | .tls.server_name' $CONFIG_FILE)
    NAIVE_USER=$(jq -r '.inbounds[] | select(.type=="naive") | .users[0].username' $CONFIG_FILE)
    NAIVE_PASS=$(jq -r '.inbounds[] | select(.type=="naive") | .users[0].password' $CONFIG_FILE)
    
    HY2_PASS=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' $CONFIG_FILE)
    HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' $CONFIG_FILE)
    
    # Links
    LINK_NAIVE="naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443?padding=true#Naive_${DOMAIN}"
    LINK_HY2="hysteria2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}&insecure=0#Hy2_${DOMAIN}"
    
    clear
    echo -e "${BLUE}================ Configuration Info ================${PLAIN}"
    echo -e "${YELLOW}Domain:${PLAIN}   $DOMAIN"
    echo ""
    echo -e "${GREEN}1. NaiveProxy${PLAIN}"
    echo -e "   Port: 443 | User: $NAIVE_USER | Pass: $NAIVE_PASS"
    echo -e "   Link: ${CYAN}${LINK_NAIVE}${PLAIN}"
    echo ""
    echo -e "${GREEN}2. Hysteria2${PLAIN}"
    echo -e "   Port: $HY2_PORT | Pass: $HY2_PASS"
    echo -e "   Link: ${CYAN}${LINK_HY2}${PLAIN}"
    echo -e "${BLUE}====================================================${PLAIN}"
    echo ""
    echo -e "${YELLOW}Scan for NaiveProxy:${PLAIN}"
    qrencode -t ansiutf8 "${LINK_NAIVE}"
    echo ""
    echo -e "${YELLOW}Scan for Hysteria2:${PLAIN}"
    qrencode -t ansiutf8 "${LINK_HY2}"
}

# Others
setup_systemd() {
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
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
    cp "$0" $SHORTCUT_BIN && chmod +x $SHORTCUT_BIN
}

uninstall() {
    systemctl stop sing-box && systemctl disable sing-box
    rm -f $SERVICE_FILE $BIN_PATH $SHORTCUT_BIN /etc/sysctl.d/99-singbox-vps.conf
    rm -rf /etc/sing-box
    echo -e "${GREEN}Uninstalled!${PLAIN}"
}

# Get VPS Status
get_vps_status() {
    OS=$(grep -w "PRETTY_NAME" /etc/os-release | cut -d '"' -f 2)
    TCP_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    IP=$(curl -s4 --max-time 2 icanhazip.com || echo "N/A")
    ST="${RED}Stopped${PLAIN}"
    systemctl is-active --quiet sing-box && ST="${GREEN}Running${PLAIN}"
    
    echo -e "${BLUE}--- VPS Status ---${PLAIN}"
    echo -e "OS:     $OS"
    echo -e "IP:     $IP"
    echo -e "BBR:    $TCP_CC"
    echo -e "Status: $ST"
    echo -e "${BLUE}------------------${PLAIN}"
}

# Menu
show_menu() {
    clear
    get_vps_status
    echo -e "${CYAN}--- Management ---${PLAIN}"
    echo -e "1. Install / Repair (Naive + Hy2)"
    echo -e "2. Show Links & QR Codes"
    echo -e "3. Restart Service"
    echo -e "4. View Logs"
    echo -e "5. Uninstall"
    echo -e "0. Exit"
    echo ""
    read -p "Select: " choice
    case $choice in
        1) optimize_system; install_dependencies; install_singbox; setup_ssl; generate_config; setup_systemd; show_config ;;
        2) show_config ;;
        3) systemctl restart sing-box; echo "Restarted!" ;;
        4) journalctl -u sing-box -n 50 --no-pager; read -p "Enter to return..." ;;
        5) uninstall ;;
        *) exit 0 ;;
    esac
}

show_menu
