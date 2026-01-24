#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

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

# Function to install dependencies
install_dependencies() {
    echo -e "${YELLOW}Installing dependencies...${PLAIN}"
    if [[ -f /etc/debian_version ]]; then
        apt-get update
        apt-get install -y curl wget jq tar openssl socat qrencode
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y curl wget jq tar openssl socat
        # Install qrencode for CentOS
        if ! command -v qrencode &> /dev/null; then
            yum install -y epel-release
            yum install -y qrencode
        fi
    else
        echo -e "${RED}Unsupported OS!${PLAIN}"
        exit 1
    fi
}

# Function to get latest sing-box version
get_latest_version() {
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
        VERSION="v1.8.10" # Fallback
    fi
    echo $VERSION
}

# Function to install sing-box
install_singbox() {
    VERSION=$(get_latest_version)
    echo -e "${YELLOW}Installing Sing-box ${VERSION} for ${ARCH}...${PLAIN}"
    
    FILENAME="sing-box-${VERSION#v}-linux-${ARCH}.tar.gz"
    URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/${FILENAME}"
    
    wget -O /tmp/sing-box.tar.gz "$URL"
    tar -zxvf /tmp/sing-box.tar.gz -C /tmp
    mv /tmp/sing-box-*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    
    mkdir -p /etc/sing-box
    rm -rf /tmp/sing-box*
}

# Function to setup SSL
setup_ssl() {
    echo -e "${YELLOW}Setting up SSL with acme.sh...${PLAIN}"
    read -p "Enter your domain: " DOMAIN
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
    
    # Check if certificate already exists and is valid
    if [[ -f ~/.acme.sh/${DOMAIN}_ecc/fullchain.cer ]]; then
        echo -e "${GREEN}Certificate for ${DOMAIN} already exists, skipping issuance.${PLAIN}"
    else
        if ! ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone; then
            echo -e "${RED}SSL issue failed! Please check if port 80 is open and domain is pointing to this IP.${PLAIN}"
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
    
    # Generate Links
    # NaiveProxy URL format: https://user:pass@host:port
    NAIVE_URL="https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}?padding=true#Naive_${DOMAIN}"
    
    echo -e "${GREEN}Config generated successfully!${PLAIN}"
    echo -e "${YELLOW}--- Client Configuration Info ---${PLAIN}"
    echo -e "Domain:   ${DOMAIN}"
    echo -e "Port:     ${PORT}"
    echo -e "Username: ${USERNAME}"
    echo -e "Password: ${PASSWORD}"
    echo -e "Protocol: naive"
    echo -e "----------------------------------"
    echo ""
    echo -e "${YELLOW}--- Client Import Link ---${PLAIN}"
    echo -e "${NAIVE_URL}"
    echo ""
    echo -e "${YELLOW}--- Scan for Shadowrocket (Scan the QR Code below) ---${PLAIN}"
    qrencode -t ansiutf8 "${NAIVE_URL}"
    echo ""
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
    echo -e "${GREEN}Sing-box service started!${PLAIN}"
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
    
    echo -e "${GREEN}Sing-box has been successfully uninstalled!${PLAIN}"
}

# Menu
show_menu() {
    clear
    echo -e "${GREEN}#############################################################${PLAIN}"
    echo -e "${GREEN}#                                                           #${PLAIN}"
    echo -e "${GREEN}#          Sing-box + NaiveProxy Auto Deployment            #${PLAIN}"
    echo -e "${GREEN}#                                                           #${PLAIN}"
    echo -e "${GREEN}#############################################################${PLAIN}"
    echo ""
    echo -e "${YELLOW}1.${PLAIN} Install Sing-box + NaiveProxy"
    echo -e "${YELLOW}2.${PLAIN} Uninstall Sing-box"
    echo -e "${YELLOW}0.${PLAIN} Exit"
    echo ""
    read -p "Please enter a number [0-2]: " choice
    case $choice in
        1)
            install_dependencies
            install_singbox
            setup_ssl
            generate_config
            setup_systemd
            echo -e "${GREEN}Deployment completed!${PLAIN}"
            ;;
        2)
            uninstall_singbox
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid input!${PLAIN}"
            ;;
    esac
}

show_menu
