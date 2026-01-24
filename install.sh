#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root!${PLAIN}"
   exit 1
fi

# Detect architecture
ARCH=$(uname -m)
case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *) echo -e "${RED}Unsupported architecture: $ARCH${PLAIN}"; exit 1 ;;
esac

# Function to get VPS info
get_vps_info() {
    IS_BBR=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    VIRT=$(systemd-detect-virt)
    IPV4=$(curl -s4 icanhazip.com || echo "None")
    IPV6=$(curl -s6 icanhazip.com || echo "None")
    OS=$(grep -w "PRETTY_NAME" /etc/os-release | cut -d '"' -f 2)
    KERNEL=$(uname -r)
    
    echo -e "${BLUE}---------------- VPS Status ----------------${PLAIN}"
    echo -e "System:   ${OS}"
    echo -e "Kernel:   ${KERNEL}"
    echo -e "Platform: ${ARCH}"
    echo -e "Virt:     ${VIRT}"
    echo -e "BBR:      ${IS_BBR}"
    echo -e "IPv4:     ${IPV4}"
    echo -e "IPv6:     ${IPV6}"
    
    if systemctl is-active --quiet sing-box; then
        PORT=$(jq -r '.inbounds[0].listen_port' /etc/sing-box/config.json 2>/dev/null || echo "443")
        echo -e "Status:   ${GREEN}Running${PLAIN}"
        echo -e "Port:     ${PORT}"
    else
        echo -e "Status:   ${RED}Stopped${PLAIN}"
    fi
    echo -e "${BLUE}--------------------------------------------${PLAIN}"
}

# Function to get latest sing-box version
get_latest_version() {
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
        VERSION="v1.12.17" # Fallback
    fi
    echo $VERSION
}

# Function to get current sing-box version
get_current_version() {
    if command -v sing-box &> /dev/null; then
        sing-box version | head -n 1 | awk '{print $3}'
    else
        echo "None"
    fi
}

# Function to install/update dependencies
install_dependencies() {
    echo -e "${YELLOW}Installing dependencies...${PLAIN}"
    if [[ -f /etc/debian_version ]]; then
        apt-get update
        apt-get install -y curl wget jq tar openssl socat qrencode
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y curl wget jq tar openssl socat
        if ! command -v qrencode &> /dev/null; then
            yum install -y epel-release
            yum install -y qrencode
        fi
    fi
}

# Function to install sing-box
install_singbox() {
    LATEST=$(get_latest_version)
    echo -e "${YELLOW}Installing Sing-box ${LATEST} for ${ARCH}...${PLAIN}"
    
    FILENAME="sing-box-${LATEST#v}-linux-${ARCH}.tar.gz"
    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST}/${FILENAME}"
    
    wget -O /tmp/sing-box.tar.gz "$URL"
    tar -zxvf /tmp/sing-box.tar.gz -C /tmp
    mv /tmp/sing-box-*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    
    mkdir -p /etc/sing-box
    rm -rf /tmp/sing-box*
}

# Function to setup SSL
setup_ssl() {
    echo -e "${YELLOW}Setting up SSL...${PLAIN}"
    if [[ -f /etc/sing-box/config.json ]]; then
        DOMAIN=$(jq -r '.inbounds[0].tls.server_name' /etc/sing-box/config.json)
    fi
    
    if [[ -z "$DOMAIN" || "$DOMAIN" == "null" ]]; then
        read -p "Enter your domain: " DOMAIN
    fi
    
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}Domain cannot be empty!${PLAIN}"
        exit 1
    fi

    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        source ~/.bashrc
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    fi
    
    systemctl stop sing-box 2>/dev/null
    
    # Check both ECC and RSA paths
    if [[ -f ~/.acme.sh/${DOMAIN}_ecc/fullchain.cer ]] || [[ -f ~/.acme.sh/${DOMAIN}/fullchain.cer ]]; then
        echo -e "${GREEN}Certificate for ${DOMAIN} already exists, skipping issuance.${PLAIN}"
    else
        if ! ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone; then
            echo -e "${RED}SSL issue failed! Please check if port 80 is open.${PLAIN}"
            exit 1
        fi
    fi
    
    mkdir -p /etc/sing-box/certs
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --fullchain-file /etc/sing-box/certs/fullchain.pem \
        --key-file /etc/sing-box/certs/private.key
}

# Function to generate config
generate_config() {
    USERNAME=$(openssl rand -hex 4)
    PASSWORD=$(openssl rand -hex 8)
    PORT=443
    
    cat > /etc/sing-box/config.json <<EOF
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
      },
      "destination": "www.bing.com:443"
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

# Function to show config links and QR
show_config() {
    if [[ ! -f /etc/sing-box/config.json ]]; then
        echo -e "${RED}No config found! Please install first.${PLAIN}"
        return
    fi
    
    DOMAIN=$(jq -r '.inbounds[0].tls.server_name' /etc/sing-box/config.json)
    USERNAME=$(jq -r '.inbounds[0].users[0].username' /etc/sing-box/config.json)
    PASSWORD=$(jq -r '.inbounds[0].users[0].password' /etc/sing-box/config.json)
    PORT=$(jq -r '.inbounds[0].listen_port' /etc/sing-box/config.json)
    
    URL="https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}?padding=true#Naive_${DOMAIN}"
    
    echo -e "${GREEN}--- Current Configuration ---${PLAIN}"
    echo -e "Domain:   ${DOMAIN}"
    echo -e "Port:     ${PORT}"
    echo -e "Username: ${USERNAME}"
    echo -e "Password: ${PASSWORD}"
    echo -e "Link:     ${URL}"
    echo -e "${YELLOW}Scan for Shadowrocket:${PLAIN}"
    qrencode -t ansiutf8 "${URL}"
}

# Function to setup systemd
setup_systemd() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=18s
LimitNOFILE= infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box

    # Add shortcut
    cp "$0" /usr/local/bin/nb
    chmod +x /usr/local/bin/nb
}

# Function to uninstall
uninstall_singbox() {
    echo -e "${YELLOW}Uninstalling Sing-box...${PLAIN}"
    systemctl stop sing-box
    systemctl disable sing-box
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    rm -rf /etc/sing-box
    rm -f /usr/local/bin/sing-box
    echo -e "${GREEN}Uninstalled successfully!${PLAIN}"
}

# Menu
show_menu() {
    CURRENT=$(get_current_version)
    LATEST=$(get_latest_version)
    
    clear
    echo -e "${PURPLE}#############################################################${PLAIN}"
    echo -e "${PURPLE}#          Sing-box + NaiveProxy Admin Menu                 #${PLAIN}"
    echo -e "${PURPLE}#############################################################${PLAIN}"
    
    get_vps_info
    
    echo -e "Current Version: ${YELLOW}${CURRENT}${PLAIN}"
    echo -e "Latest Version:  ${GREEN}${LATEST}${PLAIN}"
    echo ""
    echo -e "${YELLOW}1.${PLAIN} Install Sing-box + NaiveProxy"
    echo -e "${YELLOW}2.${PLAIN} Uninstall Sing-box"
    echo -e "${YELLOW}3.${PLAIN} Show Current Config & QR Code"
    echo -e "${YELLOW}4.${PLAIN} Update Sing-box (Manual)"
    echo -e "${YELLOW}5.${PLAIN} Start / Stop / Restart Service"
    echo -e "${YELLOW}0.${PLAIN} Exit"
    echo ""
    read -p "Please enter a number [0-5]: " choice
    case $choice in
        1)
            install_dependencies
            setup_ssl
            install_singbox
            generate_config
            setup_systemd
            show_config
            ;;
        2)
            uninstall_singbox
            ;;
        3)
            show_config
            ;;
        4)
            install_singbox
            systemctl restart sing-box
            echo -e "${GREEN}Updated to ${LATEST}!${PLAIN}"
            ;;
        5)
            echo -e "1. Start  2. Stop  3. Restart"
            read -p "Select action: " act
            case $act in
                1) systemctl start sing-box ;;
                2) systemctl stop sing-box ;;
                3) systemctl restart sing-box ;;
            esac
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid input!${PLAIN}" ;;
    esac
}

show_menu
