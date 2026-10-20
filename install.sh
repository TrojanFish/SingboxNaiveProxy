#!/bin/bash
# ==============================================================================
# Sing-box (NaiveProxy + Hysteria2 + WARP) Ultimate Manager (Optimized Edition)
# ==============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# Paths & Globals
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
WARP_CONF="${CONFIG_DIR}/warp.json"
CERT_DIR="${CONFIG_DIR}/certs"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
BIN_PATH="/usr/local/bin/sing-box"
SHORTCUT_BIN="/usr/local/bin/nb"
SYSCTL_FILE="/etc/sysctl.d/99-singbox.conf"
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/TrojanFish/SingboxNaiveProxy/main/install.sh"

# Cached Runtime Variables
CACHED_IPV4=""
CACHED_IPV6=""
CACHED_LAT_V=""
ARCH=""
PM=""

# Check Root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root!${PLAIN}"
    exit 1
fi

# ----------------- Environment & Cache Initialization -----------------

detect_env() {
    local arch_raw
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) echo -e "${RED}Unsupported architecture: $arch_raw${PLAIN}"; exit 1 ;;
    esac

    if command -v apt-get >/dev/null 2>&1; then
        PM="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PM="yum"
    else
        echo -e "${RED}Unsupported Linux distribution package manager!${PLAIN}"
        exit 1
    fi
}

# Fetch latest release without consuming GitHub API rate limits
fetch_latest_version() {
    local tag=""
    # Method 1: Follow HTTP redirect on release/latest (immune to API rate-limit)
    tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --connect-timeout 5 -m 8 "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null | grep -oP 'tag/\K[^/]+')
    # Method 2: GitHub API fallback
    if [[ -z "$tag" ]]; then
        tag=$(curl -sLm 5 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+')
    fi
    # Method 3: Fallback default
    [[ -z "$tag" || "$tag" == "null" ]] && tag="v1.11.4"
    echo "$tag"
}

refresh_cache() {
    CACHED_IPV4=$(curl -s4m 3 https://icanhazip.com || curl -s4m 3 https://api.ipify.org || echo "N/A")
    CACHED_IPV6=$(curl -s6m 3 https://icanhazip.com || echo "N/A")
    CACHED_LAT_V=$(fetch_latest_version)
}

get_current_version() {
    if [[ -x "$BIN_PATH" ]]; then
        "$BIN_PATH" version 2>/dev/null | head -n 1 | awk '{print $3}'
    else
        echo "Not Installed"
    fi
}

# Load existing configuration into memory safely
load_existing_config() {
    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
        DOMAIN=$(jq -r '.inbounds[] | select(.type=="naive") | .tls.server_name // empty' "$CONFIG_FILE" 2>/dev/null)
        NAIVE_USER=$(jq -r '.inbounds[] | select(.type=="naive") | .users[0].username // empty' "$CONFIG_FILE" 2>/dev/null)
        NAIVE_PASS=$(jq -r '.inbounds[] | select(.type=="naive") | .users[0].password // empty' "$CONFIG_FILE" 2>/dev/null)
        HY2_PASS=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password // empty' "$CONFIG_FILE" 2>/dev/null)
        HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' "$CONFIG_FILE" 2>/dev/null)
        HY2_MASK=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .masquerade // empty' "$CONFIG_FILE" 2>/dev/null)
        HY2_UP_MBPS=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .up_mbps // empty' "$CONFIG_FILE" 2>/dev/null)
        HY2_DOWN_MBPS=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .down_mbps // empty' "$CONFIG_FILE" 2>/dev/null)
    fi

    # Reset hopping ports safely and parse numeric values
    HY2_HOP_START=""
    HY2_HOP_END=""
    if [[ -f "${CONFIG_DIR}/hop.conf" ]]; then
        HY2_HOP_START=$(grep -oP '^HY2_HOP_START=\K[0-9]+$' "${CONFIG_DIR}/hop.conf" 2>/dev/null || true)
        HY2_HOP_END=$(grep -oP '^HY2_HOP_END=\K[0-9]+$' "${CONFIG_DIR}/hop.conf" 2>/dev/null || true)
    fi
}

# Validate that a port range is numerically safe and within bounds
validate_port_range() {
    local start="$1"
    local end="$2"
    if [[ ! "$start" =~ ^[0-9]+$ || ! "$end" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: Ports must be pure numbers!${PLAIN}"
        return 1
    fi
    if (( start < 1024 || end > 65535 || start >= end )); then
        echo -e "${RED}Error: Invalid port range! Must satisfy 1024 <= Start < End <= 65535.${PLAIN}"
        return 1
    fi
    return 0
}

# ----------------- System & Dependency Setup -----------------

install_dependencies() {
    echo -e "${YELLOW}Installing system dependencies...${PLAIN}"
    if [[ "$PM" == "apt" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget jq tar openssl socat cron qrencode lsof iproute2 ca-certificates >/dev/null 2>&1
        systemctl enable --now cron >/dev/null 2>&1
    else
        $PM install -y epel-release >/dev/null 2>&1
        $PM install -y curl wget jq tar openssl socat cronie qrencode lsof iproute ca-certificates >/dev/null 2>&1
        systemctl enable --now crond >/dev/null 2>&1
    fi
    echo -e "${GREEN}Dependencies installed.${PLAIN}"
}

check_ports() {
    local ports=(80 443)
    for port in "${ports[@]}"; do
        local pid=""
        if command -v ss >/dev/null 2>&1; then
            pid=$(ss -tulpn | grep -E ":${port}\b" | grep -oP 'pid=\K[0-9]+' | head -n 1)
        elif command -v lsof >/dev/null 2>&1; then
            pid=$(lsof -i:"$port" -t 2>/dev/null | head -n 1)
        fi

        if [[ -n "$pid" ]]; then
            local pname
            pname=$(ps -p "$pid" -o comm= 2>/dev/null)
            if [[ "$pname" != "sing-box" && -n "$pname" ]]; then
                echo -e "${YELLOW}Warning: Port $port is currently occupied by $pname (PID: $pid).${PLAIN}"
                read -rp "Do you want to terminate this process and continue? [y/N]: " kill_it
                if [[ "$kill_it" =~ ^[Yy]$ ]]; then
                    kill -9 "$pid" 2>/dev/null
                    sleep 1
                    echo -e "${GREEN}Process $pname (PID: $pid) terminated.${PLAIN}"
                else
                    echo -e "${RED}Operation aborted by user.${PLAIN}"
                    return 1
                fi
            fi
        fi
    done
    return 0
}

optimize_system() {
    echo -e "${YELLOW}Optimizing kernel parameters (BBR & QUIC/UDP buffers)...${PLAIN}"
    local virt=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt 2>/dev/null)
    fi

    if [[ "$virt" =~ ^(lxc|openvz|docker|podman|container) ]]; then
        echo -e "${YELLOW}Container virtualization (${virt}) detected.${PLAIN}"
        echo -e "${YELLOW}Kernel sysctl parameter tuning skipped (managed by host node).${PLAIN}"
        return 0
    fi

    cat > "$SYSCTL_FILE" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
EOF
    if sysctl --system >/dev/null 2>&1; then
        echo -e "${GREEN}System parameters optimized!${PLAIN}"
    else
        echo -e "${YELLOW}Notice: Kernel parameters applied with minor warnings.${PLAIN}"
    fi
}

# ----------------- Core Installation & Update -----------------

install_singbox() {
    local target_ver="$1"
    [[ -z "$target_ver" ]] && target_ver="$CACHED_LAT_V"
    [[ -z "$target_ver" || "$target_ver" == "null" ]] && target_ver=$(fetch_latest_version)

    local clean_ver="${target_ver#v}"
    local filename="sing-box-${clean_ver}-linux-${ARCH}.tar.gz"
    local base_url="https://github.com/SagerNet/sing-box/releases/download/${target_ver}"

    echo -e "${YELLOW}Downloading Sing-box ${target_ver} (${ARCH})...${PLAIN}"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! wget -q --show-progress -O "${tmp_dir}/${filename}" "${base_url}/${filename}"; then
        echo -e "${RED}Failed to download Sing-box binary! Check network connectivity.${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Strict SHA256 Checksum Verification
    if wget -q -O "${tmp_dir}/checksums.txt" "${base_url}/checksums.txt" 2>/dev/null && [[ -s "${tmp_dir}/checksums.txt" ]]; then
        echo -e "${CYAN}Verifying SHA256 checksum...${PLAIN}"
        if ! (
            set -eo pipefail
            cd "$tmp_dir"
            grep -F " ${filename}" checksums.txt | sha256sum -c --status -
        ); then
            echo -e "${RED}SHA256 checksum verification failed! Aborting installation.${PLAIN}"
            rm -rf "$tmp_dir"
            return 1
        fi
        echo -e "${GREEN}SHA256 checksum verified.${PLAIN}"
    else
        echo -e "${YELLOW}Warning: Could not fetch checksums.txt, skipping SHA256 verification.${PLAIN}"
    fi

    tar -zxf "${tmp_dir}/${filename}" -C "$tmp_dir"
    systemctl stop sing-box 2>/dev/null

    cp -f "${tmp_dir}"/sing-box-*/sing-box "$BIN_PATH"
    chmod +x "$BIN_PATH"

    if [[ -f "${tmp_dir}"/sing-box-*/libcronet.so ]]; then
        cp -f "${tmp_dir}"/sing-box-*/libcronet.so /usr/lib/ 2>/dev/null
        cp -f "${tmp_dir}"/sing-box-*/libcronet.so /usr/local/lib/ 2>/dev/null
        chmod 755 /usr/lib/libcronet.so /usr/local/lib/libcronet.so 2>/dev/null || true
        ldconfig
    fi

    mkdir -p "$CONFIG_DIR" "$CERT_DIR"
    rm -rf "$tmp_dir"
    echo -e "${GREEN}Sing-box ${target_ver} installed to ${BIN_PATH}.${PLAIN}"
    return 0
}

# ----------------- SSL Certificate Management -----------------

verify_domain_dns() {
    local domain="$1"
    echo -e "${CYAN}Pre-checking DNS resolution for ${domain}...${PLAIN}"
    local resolved_ipv4 resolved_ipv6
    resolved_ipv4=$(curl -s4m 4 "https://1.1.1.1/dns-query?name=${domain}&type=A" -H 'accept: application/dns-json' 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n 1)
    resolved_ipv6=$(curl -s4m 4 "https://1.1.1.1/dns-query?name=${domain}&type=AAAA" -H 'accept: application/dns-json' 2>/dev/null | jq -r '.Answer[]? | select(.type==28) | .data' 2>/dev/null | head -n 1)

    if [[ -z "$resolved_ipv4" ]] && command -v getent >/dev/null 2>&1; then
        resolved_ipv4=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -n 1)
        resolved_ipv6=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | head -n 1)
    fi

    echo -e "  - Resolved IPv4: ${resolved_ipv4:-None}"
    echo -e "  - Server   IPv4: ${CACHED_IPV4:-N/A}"

    if [[ -n "$resolved_ipv4" && "$CACHED_IPV4" != "N/A" && "$resolved_ipv4" != "$CACHED_IPV4" ]]; then
        echo -e "${YELLOW}Warning: Domain resolved IPv4 ($resolved_ipv4) does not match server public IP ($CACHED_IPV4)!${PLAIN}"
        read -rp "Are you sure you want to proceed with certificate issuance? [y/N]: " force_dns
        [[ ! "$force_dns" =~ ^[Yy]$ ]] && return 1
    fi

    if [[ -n "$resolved_ipv6" ]]; then
        echo -e "  - Resolved IPv6: ${resolved_ipv6}"
        if [[ "$CACHED_IPV6" == "N/A" || -z "$CACHED_IPV6" ]]; then
            echo -e "${RED}Caution: Domain has an AAAA (IPv6) record, but this server has no working public IPv6!${PLAIN}"
            echo -e "${YELLOW}Let's Encrypt validates IPv6 first and will likely fail.${PLAIN}"
            echo -e "${YELLOW}Tip: Remove the AAAA record in your DNS provider before continuing.${PLAIN}"
            read -rp "Proceed anyway? [y/N]: " force_v6
            [[ ! "$force_v6" =~ ^[Yy]$ ]] && return 1
        fi
    fi
    return 0
}

setup_ssl() {
    echo -e "${YELLOW}Configuring SSL Certificate...${PLAIN}"
    load_existing_config

    if [[ -z "$DOMAIN" ]]; then
        read -rp "Enter your domain name (must point to this server IP): " DOMAIN
    else
        echo -e "${CYAN}Current configured domain: ${DOMAIN}${PLAIN}"
        read -rp "Keep using this domain? [Y/n]: " keep_dom
        if [[ "$keep_dom" =~ ^[Nn]$ ]]; then
            read -rp "Enter new domain name: " DOMAIN
        fi
    fi

    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}Error: Domain name cannot be empty!${PLAIN}"
        return 1
    fi

    verify_domain_dns "$DOMAIN" || return 1

    systemctl stop sing-box 2>/dev/null

    local acme_bin="$HOME/.acme.sh/acme.sh"
    if [[ ! -f "$acme_bin" ]]; then
        echo -e "${YELLOW}Installing acme.sh safely...${PLAIN}"
        local acme_installer
        acme_installer=$(mktemp)
        if curl --proto '=https' --tlsv1.2 -fsSL https://get.acme.sh -o "$acme_installer" && [[ -s "$acme_installer" ]]; then
            sh "$acme_installer" -s email="admin@${DOMAIN}" >/dev/null 2>&1
            rm -f "$acme_installer"
        else
            rm -f "$acme_installer"
            echo -e "${RED}Error: Failed to download acme.sh installer securely!${PLAIN}"
            return 1
        fi
    fi

    "$acme_bin" --upgrade --auto-upgrade >/dev/null 2>&1
    "$acme_bin" --set-default-ca --server letsencrypt >/dev/null 2>&1

    if [[ ! -f "$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer" && ! -f "$HOME/.acme.sh/${DOMAIN}/fullchain.cer" ]]; then
        echo -e "${YELLOW}Issuing Let's Encrypt ECC certificate for ${DOMAIN}...${PLAIN}"
        if ! "$acme_bin" --issue -d "$DOMAIN" --standalone --keylength ec-256 --force; then
            echo -e "${RED}SSL issuance failed! Ensure port 80 is open and ${DOMAIN} resolves to ${CACHED_IPV4}.${PLAIN}"
            return 1
        fi
    else
        echo -e "${GREEN}Existing valid certificate found for ${DOMAIN}.${PLAIN}"
    fi

    mkdir -p "$CERT_DIR"
    "$acme_bin" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "${CERT_DIR}/fullchain.pem" \
        --key-file "${CERT_DIR}/private.key" \
        --reloadcmd "systemctl restart sing-box 2>/dev/null || true" >/dev/null 2>&1

    chmod 600 "${CERT_DIR}/private.key"
    chmod 644 "${CERT_DIR}/fullchain.pem"
    echo -e "${GREEN}SSL certificate installed to ${CERT_DIR}.${PLAIN}"
    return 0
}

# ----------------- Firewall & Port Hopping -----------------

apply_iptables_rule() {
    local table="$1"
    local chain="$2"
    shift 2
    iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -I "$chain" 1 "$@" 2>/dev/null
}

apply_ip6tables_rule() {
    if ! command -v ip6tables >/dev/null 2>&1; then
        return 0
    fi
    local table="$1"
    local chain="$2"
    shift 2
    ip6tables -t "$table" -C "$chain" "$@" 2>/dev/null || ip6tables -t "$table" -I "$chain" 1 "$@" 2>/dev/null
}

setup_firewall() {
    echo -e "${YELLOW}Configuring firewall rules (IPv4 & IPv6)...${PLAIN}"
    load_existing_config

    local hy2_p="${HY2_PORT:-443}"

    # 1. UFW (Applies to both IPv4 and IPv6 automatically)
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        ufw allow 80/tcp >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        ufw allow 443/udp >/dev/null 2>&1
        ufw allow "${hy2_p}/udp" >/dev/null 2>&1
        if [[ -n "$HY2_HOP_START" && -n "$HY2_HOP_END" ]]; then
            ufw allow "${HY2_HOP_START}:${HY2_HOP_END}/udp" >/dev/null 2>&1
        fi
    fi

    # 2. Firewalld (Applies to both IPv4 and IPv6 automatically)
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=443/udp >/dev/null 2>&1
        firewall-cmd --permanent --add-port="${hy2_p}/udp" >/dev/null 2>&1
        if [[ -n "$HY2_HOP_START" && -n "$HY2_HOP_END" ]]; then
            firewall-cmd --permanent --add-port="${HY2_HOP_START}-${HY2_HOP_END}/udp" >/dev/null 2>&1
            firewall-cmd --permanent --add-forward-port="port=${HY2_HOP_START}-${HY2_HOP_END}:proto=udp:toport=${hy2_p}" >/dev/null 2>&1
        fi
        firewall-cmd --reload >/dev/null 2>&1
    fi

    # 3. Iptables & Ip6tables (Idempotent check before insert)
    if command -v iptables >/dev/null 2>&1; then
        # IPv4 Rules
        apply_iptables_rule filter INPUT -p tcp --dport 80 -j ACCEPT
        apply_iptables_rule filter INPUT -p tcp --dport 443 -j ACCEPT
        apply_iptables_rule filter INPUT -p udp --dport 443 -j ACCEPT
        apply_iptables_rule filter INPUT -p udp --dport "$hy2_p" -j ACCEPT

        # IPv6 Rules
        apply_ip6tables_rule filter INPUT -p tcp --dport 80 -j ACCEPT
        apply_ip6tables_rule filter INPUT -p tcp --dport 443 -j ACCEPT
        apply_ip6tables_rule filter INPUT -p udp --dport 443 -j ACCEPT
        apply_ip6tables_rule filter INPUT -p udp --dport "$hy2_p" -j ACCEPT

        if [[ -n "$HY2_HOP_START" && -n "$HY2_HOP_END" ]]; then
            apply_iptables_rule filter INPUT -p udp --dport "${HY2_HOP_START}:${HY2_HOP_END}" -j ACCEPT
            apply_iptables_rule nat PREROUTING -p udp --dport "${HY2_HOP_START}:${HY2_HOP_END}" -j REDIRECT --to-ports "$hy2_p"

            apply_ip6tables_rule filter INPUT -p udp --dport "${HY2_HOP_START}:${HY2_HOP_END}" -j ACCEPT
            apply_ip6tables_rule nat PREROUTING -p udp --dport "${HY2_HOP_START}:${HY2_HOP_END}" -j REDIRECT --to-ports "$hy2_p" 2>/dev/null || true
        fi

        # Persistence across reboots
        if [[ "$PM" == "apt" ]]; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y iptables-persistent >/dev/null 2>&1
            netfilter-persistent save >/dev/null 2>&1
        else
            if ! (systemctl is-active --quiet firewalld); then
                $PM install -y iptables-services >/dev/null 2>&1
                service iptables save >/dev/null 2>&1 || true
                service ip6tables save >/dev/null 2>&1 || true
                systemctl enable iptables ip6tables >/dev/null 2>&1 || true
            fi
        fi
    fi

    echo -e "${GREEN}Firewall configured successfully!${PLAIN}"
}

# Select or switch WARP outbound IP version preference
select_warp_ip_preference() {
    local cur_strat=""
    if [[ -f "$WARP_CONF" ]]; then
        cur_strat=$(jq -r '.domain_strategy // empty' "$WARP_CONF" 2>/dev/null)
    fi

    echo -e "${YELLOW}--- Cloudflare WARP Outbound IP Preference ---${PLAIN}"
    echo -e " 1. ${GREEN}IPv6 Preferred (Recommended)${PLAIN} - Cleanest IP for OpenAI, Claude, Google (No Captchas)"
    echo -e " 2. ${CYAN}IPv4 Preferred${PLAIN} - Best compatibility for legacy streaming services"
    echo -e " 3. ${YELLOW}Auto (Dual-stack)${PLAIN} - Default DNS resolution without preference"
    read -rp "Select preference [1-3, default 1]: " pref_choice

    local chosen_strategy="prefer_ipv6"
    case "$pref_choice" in
        2) chosen_strategy="prefer_ipv4" ;;
        3) chosen_strategy="" ;;
        *) chosen_strategy="prefer_ipv6" ;;
    esac

    if [[ -f "$WARP_CONF" ]]; then
        local updated
        updated=$(jq --arg strat "$chosen_strategy" '. + {domain_strategy: $strat}' "$WARP_CONF")
        echo "$updated" > "$WARP_CONF"
        chmod 600 "$WARP_CONF"
    fi
}

setup_warp() {
    echo -e "${YELLOW}--- Cloudflare WARP Management ---${PLAIN}"
    if [[ ! -x "$BIN_PATH" || ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: Sing-box is not fully installed! Please run Option 1 first.${PLAIN}"
        return 1
    fi

    if [[ -f "$WARP_CONF" ]]; then
        local cur_strat
        cur_strat=$(jq -r '.domain_strategy // empty' "$WARP_CONF" 2>/dev/null)
        case "$cur_strat" in
            prefer_ipv6) cur_strat="IPv6 Preferred" ;;
            prefer_ipv4) cur_strat="IPv4 Preferred" ;;
            *) cur_strat="Auto (Dual-stack)" ;;
        esac

        echo -e "${GREEN}WARP is currently active (Current Outbound: ${cur_strat}).${PLAIN}"
        echo -e " 1. Switch Outbound IP Preference (IPv6 / IPv4 / Auto)"
        echo -e " 2. Re-register WARP account"
        echo -e " 3. Disable & remove WARP integration"
        echo -e " 0. Return"
        read -rp "Select action [0-3]: " warp_act
        case "$warp_act" in
            1)
                select_warp_ip_preference
                load_existing_config
                generate_config
                systemctl restart sing-box
                echo -e "${GREEN}WARP outbound preference updated and Sing-box restarted!${PLAIN}"
                return 0
                ;;
            2) rm -f "$WARP_CONF" ;;
            3)
                rm -f "$WARP_CONF"
                load_existing_config
                generate_config
                systemctl restart sing-box
                echo -e "${GREEN}WARP removed and Sing-box restarted.${PLAIN}"
                return 0
                ;;
            *) return 0 ;;
        esac
    fi

    echo -e "${CYAN}Generating WireGuard keypair locally and registering with Cloudflare Official API...${PLAIN}"
    local key_out priv_key pub_key reg_resp v6_addr resv_b64 resv_json
    key_out=$("$BIN_PATH" generate wg-keypair 2>/dev/null)
    priv_key=$(echo "$key_out" | awk '/PrivateKey/ {print $2}')
    pub_key=$(echo "$key_out" | awk '/PublicKey/ {print $2}')

    if [[ -n "$priv_key" && -n "$pub_key" ]]; then
        reg_resp=$(curl -sLm 10 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "{\"key\":\"${pub_key}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"en_US\"}")

        v6_addr=$(echo "$reg_resp" | jq -r '.config.interface.addresses.v6 // empty' 2>/dev/null)
        resv_b64=$(echo "$reg_resp" | jq -r '.config.client_id // empty' 2>/dev/null)

        if [[ -n "$v6_addr" && -n "$resv_b64" ]]; then
            # Decode 3-byte client_id into JSON integer array [b1, b2, b3]
            resv_json=$(echo "$resv_b64" | base64 -d 2>/dev/null | od -An -tu1 | awk '{printf "[%d, %d, %d]", $1, $2, $3}')
            jq -n \
                --arg pk "$priv_key" \
                --arg v6 "$v6_addr" \
                --argjson resv "${resv_json:-[0,0,0]}" \
                --arg ep "162.159.192.1" \
                --argjson epport 2408 \
                '{private_key: $pk, v6: $v6, reserved: $resv, endpoint: $ep, endpoint_port: $epport, domain_strategy: "prefer_ipv6"}' > "$WARP_CONF"
            echo -e "${GREEN}Successfully registered via Official Cloudflare API!${PLAIN}"
        fi
    fi

    # Ask for explicit user consent before falling back to third-party APIs
    if [[ ! -s "$WARP_CONF" ]]; then
        echo -e "${YELLOW}Warning: Official Cloudflare API registration failed (likely rate-limited).${PLAIN}"
        echo -e "${RED}Security Notice: Fallback third-party APIs generate the WireGuard private key remotely.${PLAIN}"
        read -rp "Do you want to use third-party fallback APIs anyway? [y/N]: " allow_fallback
        if [[ "$allow_fallback" =~ ^[Yy]$ ]]; then
            local api_list=("https://api.zeroteam.top/warp?format=json" "https://warp-reg.vercel.app/api/reg")
            for api in "${api_list[@]}"; do
                local resp
                resp=$(curl --retry 1 --connect-timeout 6 -sL "$api")
                if echo "$resp" | jq -e '.code == "200" and .data.private_key != null' >/dev/null 2>&1; then
                    echo "$resp" | jq '.data + {endpoint: "162.159.192.1", endpoint_port: 2408, domain_strategy: "prefer_ipv6"}' > "$WARP_CONF"
                    break
                fi
            done
        fi
    fi

    if [[ ! -s "$WARP_CONF" ]]; then
        echo -e "${RED}Error: WARP registration failed! Check VPS outbound connectivity.${PLAIN}"
        rm -f "$WARP_CONF"
        return 1
    fi

    chmod 600 "$WARP_CONF"

    # Allow user to choose initial preference
    select_warp_ip_preference

    load_existing_config
    generate_config
    systemctl restart sing-box
    echo -e "${GREEN}WARP integrated into Sing-box and service restarted!${PLAIN}"
}

# ----------------- Configuration Generation (via jq) -----------------

generate_config() {
    echo -e "${YELLOW}Building Sing-box configuration via jq...${PLAIN}"

    # Only load from disk if memory variables are unset
    if [[ -z "$DOMAIN" || -z "$NAIVE_USER" ]]; then
        load_existing_config
    fi

    [[ -z "$NAIVE_USER" ]] && NAIVE_USER=$(openssl rand -hex 4)
    [[ -z "$NAIVE_PASS" ]] && NAIVE_PASS=$(openssl rand -hex 8)
    [[ -z "$HY2_PASS" ]] && HY2_PASS=$(openssl rand -hex 12)
    [[ -z "$HY2_PORT" ]] && HY2_PORT=$(shuf -i 20000-55000 -n 1)
    [[ -z "$HY2_MASK" ]] && HY2_MASK="https://www.xiaohongshu.com/"

    # Build Hysteria2 Inbound Object
    local hy2_inbound
    hy2_inbound=$(jq -n \
        --arg domain "$DOMAIN" \
        --arg pass "$HY2_PASS" \
        --arg mask "$HY2_MASK" \
        --argjson port "$HY2_PORT" \
        --arg cert "${CERT_DIR}/fullchain.pem" \
        --arg key "${CERT_DIR}/private.key" \
        '{
            type: "hysteria2",
            tag: "hy2-in",
            listen: "::",
            listen_port: $port,
            sniff: true,
            users: [{ password: $pass }],
            tls: {
                enabled: true,
                server_name: $domain,
                certificate_path: $cert,
                key_path: $key
            },
            masquerade: $mask
        }')

    if [[ -n "$HY2_UP_MBPS" && -n "$HY2_DOWN_MBPS" && "$HY2_UP_MBPS" =~ ^[0-9]+$ && "$HY2_DOWN_MBPS" =~ ^[0-9]+$ ]]; then
        hy2_inbound=$(echo "$hy2_inbound" | jq --argjson up "$HY2_UP_MBPS" --argjson down "$HY2_DOWN_MBPS" '. + {up_mbps: $up, down_mbps: $down, ignore_client_bandwidth: false}')
    else
        hy2_inbound=$(echo "$hy2_inbound" | jq '. + {ignore_client_bandwidth: true}')
    fi

    # Build Base Configuration
    local base_json
    base_json=$(jq -n \
        --arg domain "$DOMAIN" \
        --arg n_user "$NAIVE_USER" \
        --arg n_pass "$NAIVE_PASS" \
        --arg cert "${CERT_DIR}/fullchain.pem" \
        --arg key "${CERT_DIR}/private.key" \
        --argjson hy2_in "$hy2_inbound" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [
                {
                    type: "naive",
                    tag: "naive-in",
                    listen: "::",
                    listen_port: 443,
                    sniff: true,
                    users: [{ username: $n_user, password: $n_pass }],
                    tls: {
                        enabled: true,
                        server_name: $domain,
                        certificate_path: $cert,
                        key_path: $key
                    }
                },
                $hy2_in
            ],
            outbounds: [
                { type: "direct", tag: "direct" },
                { type: "block", tag: "block" }
            ],
            route: {
                rules: [
                    { ip_is_private: true, outbound: "block" },
                    { protocol: ["bittorrent"], outbound: "block" }
                ],
                final: "direct"
            }
        }')

    # Inject WARP Outbound & Comprehensive AI/Streaming Routing Rules if configured
    if [[ -s "$WARP_CONF" ]]; then
        local w_priv w_v6 w_resv w_ep w_epport w_strat
        w_priv=$(jq -r '.private_key // empty' "$WARP_CONF")
        w_v6=$(jq -r '.v6 // empty' "$WARP_CONF")
        w_resv=$(jq -c '.reserved // [0,0,0]' "$WARP_CONF")
        w_ep=$(jq -r '.endpoint // "162.159.192.1"' "$WARP_CONF")
        w_epport=$(jq -r '.endpoint_port // 2408' "$WARP_CONF")
        w_strat=$(jq -r '.domain_strategy // empty' "$WARP_CONF")

        if [[ -n "$w_priv" && -n "$w_v6" ]]; then
            base_json=$(echo "$base_json" | jq \
                --arg priv "$w_priv" \
                --arg v6 "${w_v6}/128" \
                --argjson resv "$w_resv" \
                --arg ep "$w_ep" \
                --argjson epport "$w_epport" \
                --arg strat "$w_strat" \
                '.outbounds += [{
                    type: "wireguard",
                    tag: "warp-out",
                    server: $ep,
                    server_port: $epport,
                    local_address: ["172.16.0.2/32", $v6],
                    private_key: $priv,
                    peer_public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0T7ncGA5S2NoKLU=",
                    reserved: $resv,
                    mtu: 1280
                } + (if $strat != "" then {domain_strategy: $strat} else {} end)] | .route.rules += [{
                    domain_suffix: [
                        "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "sora.com",
                        "ai.com", "anthropic.com", "claude.ai", "perplexity.ai", "hf.co", "huggingface.co",
                        "netflix.com", "netflix.net", "nflximg.net", "nflxvideo.net", "nflxso.net", "nflxext.com",
                        "disneyplus.com", "disney-plus.net", "disneystreaming.com", "dssott.com",
                        "spotify.com", "scdn.co", "max.com", "hbo.com", "hbomax.com"
                    ],
                    outbound: "warp-out"
                }]')
        fi
    fi

    echo "$base_json" | jq '.' > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

# ----------------- Systemd & Shortcut Management -----------------

setup_systemd() {
    # Create dedicated unprivileged system user for sing-box security isolation
    if ! id "sing-box" >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -M sing-box 2>/dev/null || useradd -r -s /sbin/nologin -M sing-box 2>/dev/null || true
    fi

    # Set proper permissions for the dedicated service user
    chown -R sing-box:sing-box "$CONFIG_DIR" 2>/dev/null || true

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Proxy Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=sing-box
Group=sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
Environment=LD_LIBRARY_PATH=/usr/lib:/usr/local/lib
ExecStart=${BIN_PATH} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    if "$BIN_PATH" check -c "$CONFIG_FILE" >/tmp/singbox_check.log 2>&1; then
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box
        echo -e "${GREEN}Sing-box configuration validated and service started!${PLAIN}"
    else
        echo -e "${RED}Error: Sing-box configuration validation failed!${PLAIN}"
        cat /tmp/singbox_check.log
        return 1
    fi

    # Install 'nb' shortcut safely (supporting curl|bash pipeline execution)
    local need_download=1
    if [[ -f "$0" && ! "$0" =~ ^/dev/fd && ! "$0" =~ ^/proc/ ]]; then
        if [[ "$(realpath "$0" 2>/dev/null)" != "$(realpath "$SHORTCUT_BIN" 2>/dev/null)" ]]; then
            cp -f "$0" "$SHORTCUT_BIN" 2>/dev/null && need_download=0
        else
            need_download=0
        fi
    fi

    if [[ $need_download -eq 1 ]]; then
        echo -e "${CYAN}Installing 'nb' shortcut from remote source...${PLAIN}"
        curl -fsSL "$REMOTE_SCRIPT_URL" -o "$SHORTCUT_BIN" 2>/dev/null || wget -qO "$SHORTCUT_BIN" "$REMOTE_SCRIPT_URL" 2>/dev/null || true
    fi

    if [[ -f "$SHORTCUT_BIN" ]]; then
        chmod +x "$SHORTCUT_BIN"
        echo -e "${CYAN}Shortcut installed! Type 'nb' anytime to open this manager.${PLAIN}"
    fi
}

# ----------------- Display Configs & Client Snippets -----------------

show_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: Configuration file not found! Please install first.${PLAIN}"
        return 1
    fi
    load_existing_config

    local mport_param=""
    if [[ -n "$HY2_HOP_START" && -n "$HY2_HOP_END" ]]; then
        mport_param="&mport=${HY2_HOP_START}-${HY2_HOP_END}"
    fi

    local link_nav="https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443?padding=true#Naive_${DOMAIN}"
    local link_roc="naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443?padding=true#Naive_${DOMAIN}"
    local link_hy2="hysteria2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}&insecure=0${mport_param}#Hy2_${DOMAIN}"

    clear
    echo -e "${PURPLE}=============================================================${PLAIN}"
    echo -e "${PURPLE}#               CONFIGURATIONS & IMPORT LINKS               #${PLAIN}"
    echo -e "${PURPLE}=============================================================${PLAIN}"
    echo -e "${YELLOW}Server Domain:${PLAIN}  ${DOMAIN}"
    echo -e "${YELLOW}Server IPv4:${PLAIN}    ${CACHED_IPV4}"
    [[ "$CACHED_IPV6" != "N/A" ]] && echo -e "${YELLOW}Server IPv6:${PLAIN}    ${CACHED_IPV6}"
    echo ""
    echo -e "${GREEN}[1] NaiveProxy (TCP/UDP 443)${PLAIN}"
    echo -e "  - v2rayN / NekoBox: ${CYAN}${link_nav}${PLAIN}"
    echo -e "  - Shadowrocket:     ${CYAN}${link_roc}${PLAIN}"
    echo ""
    echo -e "${GREEN}[2] Hysteria2 (UDP ${HY2_PORT}${HY2_HOP_START:+ | Hopping: ${HY2_HOP_START}-${HY2_HOP_END}})${PLAIN}"
    echo -e "  - Universal URI:    ${CYAN}${link_hy2}${PLAIN}"
    echo ""
    echo -e "${GREEN}[3] Clash Meta (Mihomo) YAML Snippet:${PLAIN}"
    cat <<EOF
  - name: "Hy2_${DOMAIN}"
    type: hysteria2
    server: ${DOMAIN}
    port: ${HY2_PORT}
$( [[ -n "$HY2_HOP_START" ]] && echo "    ports: ${HY2_HOP_START}-${HY2_HOP_END}" )
    password: "${HY2_PASS}"
    sni: ${DOMAIN}
    skip-cert-verify: false
EOF
    echo -e "${PURPLE}=============================================================${PLAIN}"
    echo -e "${YELLOW}QR Code - Shadowrocket (NaiveProxy):${PLAIN}"
    qrencode -t ansiutf8 "${link_roc}"
    echo ""
    echo -e "${YELLOW}QR Code - Hysteria2:${PLAIN}"
    qrencode -t ansiutf8 "${link_hy2}"
    echo -e "${PURPLE}=============================================================${PLAIN}"
}

# ----------------- Modification Functions -----------------

modify_credentials() {
    [[ ! -f "$CONFIG_FILE" ]] && echo -e "${RED}Error: Config file not found!${PLAIN}" && return
    load_existing_config

    echo -e "${YELLOW}--- Modify Credentials (Leave blank to keep current) ---${PLAIN}"
    read -rp "NaiveProxy Username [current: ${NAIVE_USER}]: " new_n_user
    read -rp "NaiveProxy Password [current: ${NAIVE_PASS}]: " new_n_pass
    read -rp "Hysteria2 Password  [current: ${HY2_PASS}]: " new_h_pass

    [[ -n "$new_n_user" ]] && NAIVE_USER="$new_n_user"
    [[ -n "$new_n_pass" ]] && NAIVE_PASS="$new_n_pass"
    [[ -n "$new_h_pass" ]] && HY2_PASS="$new_h_pass"

    generate_config
    systemctl restart sing-box
    echo -e "${GREEN}Credentials updated and Sing-box restarted!${PLAIN}"
}

modify_hy2_advanced() {
    [[ ! -f "$CONFIG_FILE" ]] && echo -e "${RED}Error: Config file not found!${PLAIN}" && return
    load_existing_config

    echo -e "${YELLOW}--- Modify Hysteria2 Masquerade, Port Hopping & Brutal ---${PLAIN}"
    read -rp "Masquerade URL [current: ${HY2_MASK}]: " new_mask
    if [[ -n "$new_mask" ]]; then
        if [[ "$new_mask" =~ ^https?://[a-zA-Z0-9._/-]+$ ]]; then
            HY2_MASK="$new_mask"
        else
            echo -e "${RED}Invalid URL format! Keeping current masquerade URL.${PLAIN}"
        fi
    fi

    read -rp "Enable UDP Port Hopping? [y/N]: " en_hop
    if [[ "$en_hop" =~ ^[Yy]$ ]]; then
        local hop_s hop_e
        read -rp "Start Port (1024-65534, e.g. 20000): " hop_s
        read -rp "End Port (1025-65535, e.g. 50000): " hop_e
        if validate_port_range "$hop_s" "$hop_e"; then
            HY2_HOP_START="$hop_s"
            HY2_HOP_END="$hop_e"
            printf "HY2_HOP_START=%d\nHY2_HOP_END=%d\n" "$HY2_HOP_START" "$HY2_HOP_END" > "${CONFIG_DIR}/hop.conf"
            chmod 600 "${CONFIG_DIR}/hop.conf"
        else
            echo -e "${YELLOW}Port hopping configuration skipped due to invalid input.${PLAIN}"
        fi
    else
        HY2_HOP_START=""
        HY2_HOP_END=""
        rm -f "${CONFIG_DIR}/hop.conf"
    fi

    read -rp "Configure Brutal Bandwidth limits? (Leave blank for standard BBR) [y/N]: " en_brutal
    if [[ "$en_brutal" =~ ^[Yy]$ ]]; then
        local up_m down_m
        read -rp "Server Upload Bandwidth in Mbps (e.g. 100): " up_m
        read -rp "Server Download Bandwidth in Mbps (e.g. 100): " down_m
        if [[ "$up_m" =~ ^[0-9]+$ && "$down_m" =~ ^[0-9]+$ ]] && (( up_m > 0 && down_m > 0 )); then
            HY2_UP_MBPS="$up_m"
            HY2_DOWN_MBPS="$down_m"
        else
            echo -e "${RED}Invalid bandwidth numbers! Using standard BBR.${PLAIN}"
            HY2_UP_MBPS=""
            HY2_DOWN_MBPS=""
        fi
    else
        HY2_UP_MBPS=""
        HY2_DOWN_MBPS=""
    fi

    generate_config
    setup_firewall
    systemctl restart sing-box
    echo -e "${GREEN}Hysteria2 settings updated and applied!${PLAIN}"
}

cleanup_firewall() {
    echo -e "${YELLOW}Cleaning up firewall rules...${PLAIN}"
    load_existing_config
    local hy2_p="${HY2_PORT:-443}"

    # 1. Clean UFW
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        ufw delete allow 80/tcp >/dev/null 2>&1 || true
        ufw delete allow 443/tcp >/dev/null 2>&1 || true
        ufw delete allow 443/udp >/dev/null 2>&1 || true
        ufw delete allow "${hy2_p}/udp" >/dev/null 2>&1 || true
        if [[ -n "$HY2_HOP_START" && -n "$HY2_HOP_END" ]]; then
            ufw delete allow "${HY2_HOP_START}:${HY2_HOP_END}/udp" >/dev/null 2>&1 || true
        fi
    fi

    # 2. Clean Firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --remove-port=80/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --remove-port=443/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --remove-port=443/udp >/dev/null 2>&1 || true
        firewall-cmd --permanent --remove-port="${hy2_p}/udp" >/dev/null 2>&1 || true
        if [[ -n "$HY2_HOP_START" && -n "$HY2_HOP_END" ]]; then
            firewall-cmd --permanent --remove-port="${HY2_HOP_START}-${HY2_HOP_END}/udp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --remove-forward-port="port=${HY2_HOP_START}-${HY2_HOP_END}:proto=udp:toport=${hy2_p}" >/dev/null 2>&1 || true
        fi
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    # 3. Clean Iptables & Ip6tables
    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$hy2_p" -j ACCEPT 2>/dev/null || true
        if [[ -n "$HY2_HOP_START" && -n "$HY2_HOP_END" ]]; then
            iptables -D INPUT -p udp --dport "${HY2_HOP_START}:${HY2_HOP_END}" -j ACCEPT 2>/dev/null || true
            iptables -t nat -D PREROUTING -p udp --dport "${HY2_HOP_START}:${HY2_HOP_END}" -j REDIRECT --to-ports "$hy2_p" 2>/dev/null || true
        fi
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p udp --dport "$hy2_p" -j ACCEPT 2>/dev/null || true
        if [[ -n "$HY2_HOP_START" && -n "$HY2_HOP_END" ]]; then
            ip6tables -D INPUT -p udp --dport "${HY2_HOP_START}:${HY2_HOP_END}" -j ACCEPT 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -p udp --dport "${HY2_HOP_START}:${HY2_HOP_END}" -j REDIRECT --to-ports "$hy2_p" 2>/dev/null || true
        fi
    fi

    # Save cleaned iptables
    if [[ "$PM" == "apt" ]] && command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service iptables save >/dev/null 2>&1 || true
        service ip6tables save >/dev/null 2>&1 || true
    fi
}

uninstall_all() {
    read -rp "Are you sure you want to completely uninstall Sing-box? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    echo -e "${YELLOW}Uninstalling Sing-box and reverting system changes...${PLAIN}"
    cleanup_firewall

    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    rm -f "$SERVICE_FILE" "$BIN_PATH" "$SHORTCUT_BIN" "$SYSCTL_FILE"
    rm -f /usr/lib/libcronet.so /usr/local/lib/libcronet.so
    ldconfig
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1

    # Remove dedicated sing-box user
    if id "sing-box" >/dev/null 2>&1; then
        userdel sing-box 2>/dev/null || true
    fi

    # Optional acme.sh cleanup prompt
    if [[ -d "$HOME/.acme.sh" ]]; then
        echo -e "${YELLOW}Do you want to handle acme.sh SSL certificate tool?${PLAIN}"
        echo -e " 1. Remove only this domain certificate ($DOMAIN)"
        echo -e " 2. Completely uninstall acme.sh and remove all renewal cron jobs"
        echo -e " 3. Keep acme.sh as-is (for other websites)"
        read -rp "Select option [1-3, default 1]: " acme_clean_opt
        case "$acme_clean_opt" in
            2)
                "$HOME/.acme.sh/acme.sh" --uninstall >/dev/null 2>&1 || true
                rm -rf "$HOME/.acme.sh"
                echo -e "${GREEN}acme.sh and its cron tasks completely removed.${PLAIN}"
                ;;
            3)
                echo -e "${CYAN}Preserving acme.sh directory.${PLAIN}"
                ;;
            *)
                if [[ -n "$DOMAIN" ]]; then
                    "$HOME/.acme.sh/acme.sh" --remove -d "$DOMAIN" --ecc >/dev/null 2>&1 || true
                    echo -e "${GREEN}Domain certificate removed from acme.sh.${PLAIN}"
                fi
                ;;
        esac
    fi

    echo -e "${GREEN}Uninstallation completed successfully!${PLAIN}"
    exit 0
}

# ----------------- Status & Main Menu Loop -----------------

get_vps_status() {
    local os_name kernel_ver bbr_status svc_status warp_status
    os_name=$(grep -w "PRETTY_NAME" /etc/os-release 2>/dev/null | cut -d '"' -f 2 || uname -s)
    kernel_ver=$(uname -r)
    bbr_status=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")

    if systemctl is-active --quiet sing-box; then
        svc_status="${GREEN}Running${PLAIN}"
    else
        svc_status="${RED}Stopped${PLAIN}"
    fi

    if [[ -s "$WARP_CONF" ]]; then
        local strat_label
        strat_label=$(jq -r '.domain_strategy // empty' "$WARP_CONF" 2>/dev/null)
        case "$strat_label" in
            prefer_ipv6) warp_status="${GREEN}IPv6 Preferred${PLAIN}" ;;
            prefer_ipv4) warp_status="${GREEN}IPv4 Preferred${PLAIN}" ;;
            *) warp_status="${GREEN}Auto${PLAIN}" ;;
        esac
    else
        warp_status="${YELLOW}Disabled${PLAIN}"
    fi

    echo -e "${BLUE}---------------- VPS & Service Status ----------------${PLAIN}"
    echo -e "${CYAN}OS / Kernel:${PLAIN}  ${os_name} (${kernel_ver} | ${ARCH})"
    echo -e "${CYAN}Congestion:${PLAIN}   ${bbr_status}"
    echo -e "${CYAN}Public IP:${PLAIN}    ${CACHED_IPV4}"
    echo -e "${CYAN}Sing-box:${PLAIN}     ${svc_status}   | ${CYAN}WARP:${PLAIN} ${warp_status}"
    echo -e "${BLUE}------------------------------------------------------${PLAIN}"
}

install_full_flow() {
    install_dependencies
    check_ports || return 1
    optimize_system
    install_singbox || return 1
    setup_ssl || return 1
    generate_config
    setup_firewall
    setup_systemd || return 1
    show_config
}

show_menu() {
    clear
    local cur_v
    cur_v=$(get_current_version)

    echo -e "${PURPLE}#############################################################${PLAIN}"
    echo -e "${PURPLE}#       Sing-box (NaiveProxy + Hysteria2) Pro Manager       #${PLAIN}"
    echo -e "${PURPLE}#############################################################${PLAIN}"

    get_vps_status

    echo -e " Core Version: ${YELLOW}${cur_v}${PLAIN} (Latest Release: ${GREEN}${CACHED_LAT_V}${PLAIN})"
    echo ""
    echo -e " ${YELLOW}1.${PLAIN} Install / Reinstall (NaiveProxy + Hysteria2)"
    echo -e " ${YELLOW}2.${PLAIN} Display Client Links, QR Codes & Clash YAML"
    echo -e " ${YELLOW}3.${PLAIN} Restart Sing-box Service"
    echo -e " ${YELLOW}4.${PLAIN} View Real-time Runtime Logs"
    echo -e " ${YELLOW}5.${PLAIN} Apply BBR & Kernel Network Optimization"
    echo -e " ${YELLOW}6.${PLAIN} Uninstall Sing-box Completely"
    echo -e " ${YELLOW}7.${PLAIN} Modify Credentials (Username / Passwords)"
    echo -e " ${YELLOW}8.${PLAIN} Configure Hysteria2 (Masquerade / Port Hopping / Brutal)"
    echo -e " ${YELLOW}9.${PLAIN} Manage Cloudflare WARP (Official API Stream/AI Unlock)"
    echo -e " ${YELLOW}10.${PLAIN} Update Sing-box Core Only (with SHA256 Check)"
    echo -e " ${YELLOW}0.${PLAIN} Exit"
    echo ""
    read -rp "Select an option [0-10]: " choice

    case "$choice" in
        1) install_full_flow ;;
        2) show_config ;;
        3) systemctl restart sing-box && echo -e "${GREEN}Service restarted!${PLAIN}" ;;
        4) journalctl -u sing-box -n 30 --no-pager ;;
        5) optimize_system ;;
        6) uninstall_all ;;
        7) modify_credentials ;;
        8) modify_hy2_advanced ;;
        9) setup_warp ;;
        10)
            refresh_cache
            if install_singbox "$CACHED_LAT_V"; then
                systemctl restart sing-box
                echo -e "${GREEN}Sing-box core updated to ${CACHED_LAT_V} and restarted!${PLAIN}"
            fi
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option!${PLAIN}" ;;
    esac

    echo ""
    read -rp "Press Enter to return to main menu..."
}

# ----------------- Entrypoint -----------------
detect_env
refresh_cache
while true; do
    show_menu
done
