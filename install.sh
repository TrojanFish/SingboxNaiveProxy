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

# Detect Architecture correctly
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
    
    cat > /etc/sysctl.d/99-singbox.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_adv_win_scale=1
EOF
    sysctl -p /etc/sysctl.d/99-singbox.conf >/dev/null 2>&1
    
    echo -e "${GREEN}System optimized!${PLAIN}"
}

check_ports() {
    local ports=(80 443)
    for port in "${ports[@]}"; do
        if command -v lsof >/dev/null 2>&1; then
            if lsof -i:"$port" >/dev/null 2>&1; then
                local PID=$(lsof -i:"$port" -t | head -n 1)
                local PNAME=$(ps -p "$PID" -o comm= 2>/dev/null)
                if [[ "$PNAME" != "sing-box" && -n "$PNAME" ]]; then
                    echo -e "${YELLOW}Warning: Port $port is used by $PNAME (PID: $PID).${PLAIN}"
                    read -p "Do you want to kill this process and continue? [y/N]: " kill_it
                    if [[ "$kill_it" =~ ^[Yy]$ ]]; then
                        kill -9 "$PID"
                        echo -e "${GREEN}Process $PNAME killed.${PLAIN}"
                    else
                        echo -e "${RED}Installation aborted by user.${PLAIN}"
                        exit 1
                    fi
                fi
            fi
        fi
    done
}

# Firewall Configuration
setup_firewall() {
    echo -e "${YELLOW}Configuring firewalls (ufw/iptables)...${PLAIN}"
    
    # Standard ports
    if command -v ufw >/dev/null; then
        ufw allow 80/tcp >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        ufw allow 443/udp >/dev/null 2>&1
    fi
    
    if command -v iptables >/dev/null; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1
        iptables -I INPUT -p udp --dport 443 -j ACCEPT >/dev/null 2>&1
    fi

    # Dynamic ports (Hy2)
    if [[ -f $CONFIG_FILE ]]; then
        local HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' $CONFIG_FILE)
        if [[ -n "$HY2_PORT" ]]; then
            command -v ufw >/dev/null && ufw allow $HY2_PORT/udp >/dev/null 2>&1
            command -v iptables >/dev/null && iptables -I INPUT -p udp --dport $HY2_PORT -j ACCEPT >/dev/null 2>&1
        fi
    fi

    # Persist iptables
    if command -v iptables >/dev/null && [[ -f /etc/debian_version ]]; then
        apt-get install -y iptables-persistent >/dev/null 2>&1
        netfilter-persistent save >/dev/null 2>&1
    fi
    
    echo -e "${GREEN}Firewall configured!${PLAIN}"
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

# Version Management
get_latest_version() {
    # Using a more robust API call
    local VERSION=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    [[ -z "$VERSION" || "$VERSION" == "null" ]] && VERSION="v1.12.17"
    echo $VERSION
}

get_current_version() {
    if [[ -f "$BIN_PATH" ]]; then
        "$BIN_PATH" version | head -n 1 | awk '{print $3}'
    else
        echo "None"
    fi
}

# Install Core
install_singbox() {
    detect_arch # Ensure ARCH is correct before download
    LATEST=$(get_latest_version)
    echo -e "${YELLOW}Installing Sing-box ${LATEST} for ${ARCH}...${PLAIN}"
    
    local FILENAME="sing-box-${LATEST#v}-linux-${ARCH}.tar.gz"
    local URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST}/${FILENAME}"
    
    wget -O /tmp/sing-box.tar.gz "$URL"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Download failed! Please check your network or try again.${PLAIN}"
        exit 1
    fi
    
    tar -zxvf /tmp/sing-box.tar.gz -C /tmp >/dev/null
    
    # Move binary and libcronet (required for NaiveProxy)
    cp /tmp/sing-box-*/sing-box "$BIN_PATH"
    if [[ -f /tmp/sing-box-*/libcronet.so ]]; then
        cp /tmp/sing-box-*/libcronet.so /usr/lib/
        cp /tmp/sing-box-*/libcronet.so /usr/local/lib/
        ldconfig
        echo -e "${GREEN}Detected and installed libcronet.so to system paths.${PLAIN}"
    fi

    chmod +x "$BIN_PATH"
    
    mkdir -p /etc/sing-box
    rm -rf /tmp/sing-box*
}

# SSL Management
setup_ssl() {
    echo -e "${YELLOW}Checking SSL Certificate...${PLAIN}"
    
    if [[ -f $CONFIG_FILE ]]; then
        DOMAIN=$(jq -r '.inbounds[0].tls.server_name // empty' $CONFIG_FILE)
    fi
    
    if [[ -z "$DOMAIN" ]]; then
        read -p "Enter your domain: " DOMAIN
    else
        echo -e "${CYAN}Current domain: $DOMAIN${PLAIN}"
        read -p "Keep using this domain? [Y/n]: " KEEP_DOMAIN
        [[ "$KEEP_DOMAIN" =~ ^[Nn]$ ]] && read -p "Enter new domain: " DOMAIN
    fi

    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}Error: Domain cannot be empty!${PLAIN}"
        exit 1
    fi

    # Free port 80
    systemctl stop sing-box 2>/dev/null
    systemctl stop nginx 2>/dev/null
    systemctl stop apache2 2>/dev/null
    
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        source ~/.bashrc
    fi
    
    ACME_BIN=~/.acme.sh/acme.sh
    # Robust certificate detection
    if [[ ! -f ~/.acme.sh/${DOMAIN}_ecc/fullchain.cer ]] && [[ ! -f ~/.acme.sh/${DOMAIN}/fullchain.cer ]]; then
        echo -e "${YELLOW}Issuing new certificate for ${DOMAIN}...${PLAIN}"
        if ! $ACME_BIN --issue -d "$DOMAIN" --standalone --force; then
            echo -e "${RED}Failed to issue SSL! Please ensure port 80 is open and domain points to this IP.${PLAIN}"
            exit 1
        fi
    else
        echo -e "${GREEN}Found existing valid certificate.${PLAIN}"
    fi
    
    mkdir -p /etc/sing-box/certs
    $ACME_BIN --install-cert -d "$DOMAIN" \
        --fullchain-file /etc/sing-box/certs/fullchain.pem \
        --key-file /etc/sing-box/certs/private.key \
        --reloadcmd "systemctl restart sing-box" >> /dev/null 2>&1
}

generate_reality_pair() {
    echo -e "${YELLOW}Generating REALITY keypair...${PLAIN}"
    local KEYS=$($BIN_PATH generate reality-keypair)
    REALITY_PRIV=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
    REALITY_PUB=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')
    REALITY_SID=$(openssl rand -hex 4)
    REALITY_UUID=$(cat /proc/sys/kernel/random/uuid)
    # Persist keys for later display
    echo "$REALITY_PUB" > /etc/sing-box/reality_public.key
}

# WARP Management
setup_warp() {
    echo -e "${YELLOW}--- Cloudflare WARP Management ---${PLAIN}"
    
    # Ensure dependencies are available
    if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}Installing required dependencies (curl, jq)...${PLAIN}"
        install_dependencies >/dev/null 2>&1
    fi

    # Check if sing-box is installed
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "${RED}Error: Sing-box is not installed! Please run Option 1 first.${PLAIN}"
        read -p "Press Enter to return..."
        return
    fi
    
    local WARP_CONF="/etc/sing-box/warp.json"
    
    if [[ -f "$WARP_CONF" ]]; then
        echo -e "${GREEN}WARP is already configured.${PLAIN}"
        read -p "Do you want to re-register or update WARP? [y/N]: " re_warp
        [[ ! "$re_warp" =~ ^[Yy]$ ]] && return
    fi

    echo -e "${YELLOW}Registering WARP account via API (this may take 10-20s)...${PLAIN}"
    # Use a more reliable endpoint or local retry
    local resp=$(curl --retry 3 --connect-timeout 10 -sL "https://api.zeroteam.top/warp?format=json")
    
    if [[ -z "$resp" ]]; then
        echo -e "${RED}Error: Network timeout or API unreachable. Cannot register WARP.${PLAIN}"
        read -p "Press Enter to return..."
        return
    fi

    if [[ $(echo "$resp" | jq -r '.code') != "200" ]]; then
        echo -e "${RED}Error: API returned an error: $(echo "$resp" | jq -r '.msg')${PLAIN}"
        read -p "Press Enter to return..."
        return
    fi

    echo "$resp" | jq '.data' > "$WARP_CONF"
    if [[ ! -s "$WARP_CONF" ]]; then
        echo -e "${RED}Error: Failed to write WARP data to $WARP_CONF${PLAIN}"
        return
    fi

    echo -e "${GREEN}WARP account registered and saved to $WARP_CONF${PLAIN}"
    
    # Reload existing variables for config generation
    if [[ -f $CONFIG_FILE ]]; then
        DOMAIN=$(jq -r '.inbounds[] | select(.type=="naive") | .tls.server_name // empty' $CONFIG_FILE)
    fi
    
    generate_config
    systemctl restart sing-box
    echo -e "${GREEN}WARP has been integrated into Sing-box and service restarted!${PLAIN}"
    echo -e "${CYAN}ChatGPT/Netflix should be unlocked now.${PLAIN}"
    sleep 3
}

# Configuration Generation
generate_config() {
    echo -e "${YELLOW}Building Sing-box configuration...${PLAIN}"
    
    # Load or generate credentials
    if [[ -f $CONFIG_FILE ]]; then
        NAIVE_USER=$(jq -r '.inbounds[] | select(.type=="naive") | .users[0].username // empty' $CONFIG_FILE)
        NAIVE_PASS=$(jq -r '.inbounds[] | select(.type=="naive") | .users[0].password // empty' $CONFIG_FILE)
        HY2_PASS=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password // empty' $CONFIG_FILE)
        HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' $CONFIG_FILE)
        HY2_MASK=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .masquerade // empty' $CONFIG_FILE)
        # Reality persistence
        REALITY_PRIV=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.private_key // empty' $CONFIG_FILE)
        REALITY_PUB=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.short_id // empty' $CONFIG_FILE) # We reuse SID storage for simple scripts
        [[ -n "$REALITY_PRIV" ]] && REALITY_SID=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.short_id[0] // empty' $CONFIG_FILE)
        REALITY_UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // empty' $CONFIG_FILE)
    fi
    
    [[ -z "$NAIVE_USER" ]] && NAIVE_USER=$(openssl rand -hex 4)
    [[ -z "$NAIVE_PASS" ]] && NAIVE_PASS=$(openssl rand -hex 8)
    [[ -z "$HY2_PASS" ]] && HY2_PASS=$(openssl rand -hex 12)
    [[ -z "$HY2_PORT" ]] && HY2_PORT=$(shuf -i 15000-60000 -n 1)
    [[ -z "$HY2_MASK" ]] && HY2_MASK="https://www.xiaohongshu.com/"
    
    # Generate Reality if not exist
    if [[ -z "$REALITY_PRIV" ]]; then
        generate_reality_pair
    fi
    REALITY_PORT=$(shuf -i 15000-60000 -n 1)

    # WARP Integration Check
    local WARP_OUTBOUND=""
    local WARP_RULE=""
    if [[ -f "/etc/sing-box/warp.json" ]]; then
        local W_PRIV=$(jq -r '.private_key' /etc/sing-box/warp.json)
        local W_ADDR=$(jq -r '.v6' /etc/sing-box/warp.json)
        local W_RESV=$(jq -r '.reserved' /etc/sing-box/warp.json)
        
        WARP_OUTBOUND=',
    {
      "type": "wireguard",
      "tag": "warp-out",
      "server": "engage.cloudflareclient.com",
      "server_port": 2408,
      "local_address": [
        "172.16.0.2/32",
        "'$W_ADDR'/128"
      ],
      "private_key": "'$W_PRIV'",
      "mtu": 1280,
      "reserved": '$W_RESV',
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0T7ncGA5S2NoKLU="
    }'
        
        WARP_RULE='{
          "domain_suffix": [
            "openai.com",
            "chatgpt.com",
            "netflix.com",
            "netflix.net",
            "nflximg.net",
            "nflxvideo.net",
            "nflxso.net",
            "nflxext.com",
            "disneyplus.com",
            "hf.co",
            "anthropic.com",
            "claude.ai"
          ],
          "outbound": "warp-out"
        },'
    fi

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
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [
        {
          "uuid": "$REALITY_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "dl.google.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "dl.google.com",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIV",
          "short_id": ["$REALITY_SID"]
        }
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
      },
      "ignore_client_bandwidth": true,
      "masquerade": "$HY2_MASK"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }${WARP_OUTBOUND}
  ],
  "route": {
    "rules": [
      ${WARP_RULE}
      {
        "outbound": "direct"
      }
    ]
  }
}
EOF
    chmod 600 $CONFIG_FILE
}

# Display Configuration
show_config() {
    [[ ! -f $CONFIG_FILE ]] && echo -e "${RED}Error: Config file not found!${PLAIN}" && return
    
    local DOMAIN=$(jq -r '.inbounds[] | select(.type=="naive") | .tls.server_name' $CONFIG_FILE)
    local N_USER=$(jq -r '.inbounds[] | select(.type=="naive") | .users[0].username' $CONFIG_FILE)
    local N_PASS=$(jq -r '.inbounds[] | select(.type=="naive") | .users[0].password' $CONFIG_FILE)
    local H_PASS=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' $CONFIG_FILE)
    local H_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' $CONFIG_FILE)
    # Reality config
    local R_PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port' $CONFIG_FILE)
    local R_UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid' $CONFIG_FILE)
    local R_SID=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.short_id[0]' $CONFIG_FILE)
    local R_PUB=$(cat /etc/sing-box/reality_public.key 2>/dev/null || echo "STILL_NEED_MANUAL_CHECK")
    local IPV4=$(curl -s4 --max-time 2 icanhazip.com || echo "your_ip")
    
    local LINK_NAV="https://${N_USER}:${N_PASS}@${DOMAIN}:443?padding=true#Naive_${DOMAIN}"
    local LINK_ROC="naive+https://${N_USER}:${N_PASS}@${DOMAIN}:443?padding=true#Naive_${DOMAIN}"
    local LINK_HY2="hysteria2://${H_PASS}@${DOMAIN}:${H_PORT}/?sni=${DOMAIN}&insecure=0#Hy2_${DOMAIN}"
    local LINK_REA="vless://${R_UUID}@${IPV4}:${R_PORT}?security=reality&sni=dl.google.com&fp=chrome&pbk=${R_PUB}&sid=${R_SID}&type=tcp&flow=xtls-rprx-vision#Reality_${DOMAIN}"
    
    clear
    echo -e "${PURPLE}=============================================================${PLAIN}"
    echo -e "${PURPLE}#               CONFIGURATIONS & IMPORT LINKS               #${PLAIN}"
    echo -e "${PURPLE}#############################################################${PLAIN}"
    echo -e "${YELLOW}Server Domain:${PLAIN}  ${DOMAIN}"
    echo -e "${YELLOW}Server IP:${PLAIN}      ${IPV4}"
    echo ""
    echo -e "${GREEN}[1] NaiveProxy (Port: 443)${PLAIN}"
    echo -e "  - v2rayN Link: ${CYAN}${LINK_NAV}${PLAIN}"
    echo -e "  - Rocket Link:  ${CYAN}${LINK_ROC}${PLAIN}"
    echo ""
    echo -e "${GREEN}[2] Hysteria2 (Port: ${H_PORT})${PLAIN}"
    echo -e "  - Global Link: ${CYAN}${LINK_HY2}${PLAIN}"
    echo ""
    echo -e "${GREEN}[3] VLESS-REALITY (Port: ${R_PORT})${PLAIN}"
    echo -e "  - Basic Link: ${CYAN}${LINK_REA}${PLAIN}"
    echo -e "${PURPLE}=============================================================${PLAIN}"
    echo ""
    echo -e "${YELLOW}QR Code for NaiveProxy (Rocket compatible):${PLAIN}"
    qrencode -t ansiutf8 "${LINK_ROC}"
    echo ""
    echo -e "${YELLOW}QR Code for Hysteria2:${PLAIN}"
    qrencode -t ansiutf8 "${LINK_HY2}"
    echo ""
    echo -e "${RED}NOTE: If you are using Oracle Cloud, ensure ports 443 (TCP/UDP) ${PLAIN}"
    echo -e "${RED}and $H_PORT (UDP) are opened in the Oracle Security List.${PLAIN}"
}

# Service Management
setup_systemd() {
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
Environment=LD_LIBRARY_PATH=/usr/lib:/usr/local/lib
ExecStart=$BIN_PATH run -c $CONFIG_FILE
Restart=always
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null
    systemctl restart sing-box
    
    # Setup alias
    cp "$0" $SHORTCUT_BIN && chmod +x $SHORTCUT_BIN
}

# Uninstall
uninstall() {
    echo -e "${RED}Uninstalling Sing-box and all configurations...${PLAIN}"
    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    rm -f $SERVICE_FILE $BIN_PATH $SHORTCUT_BIN /etc/sysctl.d/99-singbox.conf
    rm -rf /etc/sing-box
    echo -e "${GREEN}Uninstallation completed.${PLAIN}"
}

# VPS Status Display
get_vps_status() {
    local OS=$(grep -w "PRETTY_NAME" /etc/os-release | cut -d '"' -f 2)
    local KERNEL=$(uname -r)
    local ARCH_M=$(uname -m)
    local IPV4=$(curl -s4 --max-time 2 icanhazip.com || echo "N/A")
    local BBR_S=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    local RUN_S="${RED}Stopped${PLAIN}"
    [[ $(systemctl is-active sing-box) == "active" ]] && RUN_S="${GREEN}Running${PLAIN}"
    
    echo -e "${BLUE}---------------- VPS Status ----------------${PLAIN}"
    echo -e "${CYAN}OS:${PLAIN}       $OS"
    echo -e "${CYAN}Kernel:${PLAIN}   $KERNEL"
    echo -e "${CYAN}Arch:${PLAIN}     $ARCH_M"
    echo -e "${CYAN}BBR:${PLAIN}      $BBR_S"
    echo -e "${CYAN}IPv4:${PLAIN}     $IPV4"
    echo -e "${CYAN}Service:${PLAIN}  $RUN_S"
    echo -e "${BLUE}--------------------------------------------${PLAIN}"
}

# Main Menu
show_menu() {
    clear
    local CUR_V=$(get_current_version)
    local LAT_V=$(get_latest_version)
    
    echo -e "${PURPLE}#############################################################${PLAIN}"
    echo -e "${PURPLE}#          Sing-box + NaiveProxy Ultimate Manager           #${PLAIN}"
    echo -e "${PURPLE}#############################################################${PLAIN}"
    
    get_vps_status
    
    echo -e " Sing-box: ${YELLOW}${CUR_V}${PLAIN} (Latest: ${LAT_V})"
    echo ""
    echo -e "${YELLOW}1.${PLAIN} Install / Repair (Naive+Hy2+Reality)"
    echo -e "${YELLOW}2.${PLAIN} Display Config Links & QR Codes"
    echo -e "${YELLOW}3.${PLAIN} Restart Services"
    echo -e "${YELLOW}4.${PLAIN} View Runtime Logs (20 lines)"
    echo -e "${YELLOW}5.${PLAIN} Enable BBR & Net Optimization"
    echo -e "${YELLOW}6.${PLAIN} Uninstall"
    echo -e "${YELLOW}7.${PLAIN} Modify Credentials (Users/Pass)"
    echo -e "${YELLOW}8.${PLAIN} Modify Masquerade Domain"
    echo -e "${YELLOW}9.${PLAIN} Manage Cloudflare WARP (Unlock Netflix/AI)"
    echo -e "${YELLOW}0.${PLAIN} Exit"
    echo ""
    read -p "Choose an option [0-9]: " choice
    case $choice in
        1) check_ports; optimize_system; install_dependencies; install_singbox; setup_ssl; generate_config; setup_firewall; setup_systemd; show_config ;;
        2) show_config ;;
        3) systemctl restart sing-box; echo -e "${GREEN}Service restarted!${PLAIN}"; sleep 1; show_menu ;;
        4) journalctl -u sing-box -n 20 --no-pager; read -p "Press Enter to return..."; show_menu ;;
        5) optimize_system; read -p "Optimization complete! Press Enter..."; show_menu ;;
        6) uninstall ;;
        7) modify_credentials ;;
        8) modify_masquerade ;;
        9) setup_warp; show_menu ;;
        *) exit 0 ;;
    esac
}

# ----------------- Modification Functions -----------------

modify_credentials() {
    [[ ! -f $CONFIG_FILE ]] && echo -e "${RED}Error: Config file not found!${PLAIN}" && return
    
    echo -e "${YELLOW}--- Modify Credentials ---${PLAIN}"
    read -p "Enter NaiveProxy Username (current: $NAIVE_USER): " NEW_N_USER
    read -p "Enter NaiveProxy Password (current: $NAIVE_PASS): " NEW_N_PASS
    read -p "Enter Hysteria2 Password (current: $HY2_PASS): " NEW_H_PASS
    
    [[ -n "$NEW_N_USER" ]] && NAIVE_USER=$NEW_N_USER
    [[ -n "$NEW_N_PASS" ]] && NAIVE_PASS=$NEW_N_PASS
    [[ -n "$NEW_H_PASS" ]] && HY2_PASS=$NEW_H_PASS
    
    generate_config
    systemctl restart sing-box
    echo -e "${GREEN}Credentials updated and service restarted!${PLAIN}"
    sleep 2
    show_menu
}

modify_masquerade() {
    [[ ! -f $CONFIG_FILE ]] && echo -e "${RED}Error: Config file not found!${PLAIN}" && return
    
    echo -e "${YELLOW}--- Modify Masquerade Domain ---${PLAIN}"
    echo -e "Current: $HY2_MASK"
    read -p "Enter new masquerade URL (e.g., https://www.xiaohongshu.com/): " NEW_MASK
    
    [[ -n "$NEW_MASK" ]] && HY2_MASK=$NEW_MASK
    
    generate_config
    systemctl restart sing-box
    echo -e "${GREEN}Masquerade domain updated and service restarted!${PLAIN}"
    sleep 2
    show_menu
}

# Start
show_menu
