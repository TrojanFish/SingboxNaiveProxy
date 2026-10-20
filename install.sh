#!/bin/bash
# ==============================================================================
# Sing-box (NaiveProxy + Hysteria2 + WARP) Ultimate Manager (Bilingual Edition)
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
LANG_FILE="${CONFIG_DIR}/lang"
CERT_DIR="${CONFIG_DIR}/certs"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
BIN_PATH="/usr/local/bin/sing-box"
SHORTCUT_BIN="/usr/local/bin/nb"
SYSCTL_FILE="/etc/sysctl.d/99-singbox.conf"
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/TrojanFish/SingboxNaiveProxy/main/install.sh"

# Cached Runtime Variables
CURRENT_LANG="zh"
CACHED_IPV4=""
CACHED_IPV6=""
CACHED_LAT_V=""
ARCH=""
PM=""

# Check Root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root! / 错误: 必须以 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

# ----------------- Multi-language (i18n) Initialization -----------------

init_lang() {
    if [[ -f "$LANG_FILE" ]]; then
        CURRENT_LANG=$(cat "$LANG_FILE" 2>/dev/null | tr -d '[:space:]')
        [[ "$CURRENT_LANG" != "en" && "$CURRENT_LANG" != "zh" ]] && CURRENT_LANG="zh"
    else
        if [[ -t 0 ]]; then
            echo -e "${CYAN}=============================================================${PLAIN}"
            echo -e "${CYAN} Please select language / 请选择界面语言:${PLAIN}"
            echo -e "   ${YELLOW}1.${PLAIN} 简体中文 (Chinese) [默认 / Default]"
            echo -e "   ${YELLOW}2.${PLAIN} English"
            echo -e "${CYAN}=============================================================${PLAIN}"
            read -rp " Select / 请选择 [1-2, default: 1]: " init_l
            init_l=$(echo "$init_l" | tr -d '\r' | tr -d ' ')
            case "$init_l" in
                2) CURRENT_LANG="en" ;;
                *) CURRENT_LANG="zh" ;;
            esac
        else
            if [[ "${LANG:-}" =~ zh|CN ]] || [[ "${LC_ALL:-}" =~ zh|CN ]]; then
                CURRENT_LANG="zh"
            else
                CURRENT_LANG="zh"
            fi
        fi
        mkdir -p "$CONFIG_DIR" 2>/dev/null || true
        echo "$CURRENT_LANG" > "$LANG_FILE" 2>/dev/null || true
    fi
}

switch_language() {
    echo ""
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}请选择界面语言 / Select Language:${PLAIN}"
        echo -e "  1. 简体中文 (当前)"
        echo -e "  2. English"
        read -rp "请选择 [1-2]: " l_ch
    else
        echo -e "${YELLOW}Select Language / 请选择界面语言:${PLAIN}"
        echo -e "  1. 简体中文"
        echo -e "  2. English (Current)"
        read -rp "Select [1-2]: " l_ch
    fi

    l_ch=$(echo "$l_ch" | tr -d '\r' | tr -d ' ')
    case "$l_ch" in
        2) CURRENT_LANG="en" ;;
        1) CURRENT_LANG="zh" ;;
        *) return ;;
    esac

    mkdir -p "$CONFIG_DIR" 2>/dev/null || true
    echo "$CURRENT_LANG" > "$LANG_FILE" 2>/dev/null || true
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${GREEN}已切换为简体中文！${PLAIN}"
    else
        echo -e "${GREEN}Language switched to English!${PLAIN}"
    fi
    sleep 1
}

# ----------------- Environment & Cache Initialization -----------------

detect_env() {
    local arch_raw
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *)
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                echo -e "${RED}不支持的系统架构: $arch_raw${PLAIN}"
            else
                echo -e "${RED}Unsupported architecture: $arch_raw${PLAIN}"
            fi
            exit 1
            ;;
    esac

    if command -v apt-get >/dev/null 2>&1; then
        PM="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PM="yum"
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${RED}不支持的 Linux 发行版包管理器！${PLAIN}"
        else
            echo -e "${RED}Unsupported Linux distribution package manager!${PLAIN}"
        fi
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
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${RED}错误: 端口必须为纯数字！${PLAIN}"
        else
            echo -e "${RED}Error: Ports must be pure numbers!${PLAIN}"
        fi
        return 1
    fi
    if (( start < 1024 || end > 65535 || start >= end )); then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${RED}错误: 端口范围无效！必须满足 1024 <= 起始端口 < 结束端口 <= 65535。${PLAIN}"
        else
            echo -e "${RED}Error: Invalid port range! Must satisfy 1024 <= Start < End <= 65535.${PLAIN}"
        fi
        return 1
    fi
    return 0
}

# ----------------- System & Dependency Setup -----------------

install_dependencies() {
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}正在安装系统依赖...${PLAIN}"
    else
        echo -e "${YELLOW}Installing system dependencies...${PLAIN}"
    fi
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
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${GREEN}系统依赖安装完成。${PLAIN}"
    else
        echo -e "${GREEN}Dependencies installed.${PLAIN}"
    fi
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
                if [[ "$CURRENT_LANG" == "zh" ]]; then
                    echo -e "${YELLOW}警告: 端口 $port 当前被进程 $pname (PID: $pid) 占用。${PLAIN}"
                    read -rp "是否强制终止该进程并继续安装？ [y/N]: " kill_it
                else
                    echo -e "${YELLOW}Warning: Port $port is currently occupied by $pname (PID: $pid).${PLAIN}"
                    read -rp "Do you want to terminate this process and continue? [y/N]: " kill_it
                fi
                if [[ "$kill_it" =~ ^[Yy]$ ]]; then
                    kill -9 "$pid" 2>/dev/null
                    sleep 1
                    if [[ "$CURRENT_LANG" == "zh" ]]; then
                        echo -e "${GREEN}进程 $pname (PID: $pid) 已终止。${PLAIN}"
                    else
                        echo -e "${GREEN}Process $pname (PID: $pid) terminated.${PLAIN}"
                    fi
                else
                    if [[ "$CURRENT_LANG" == "zh" ]]; then
                        echo -e "${RED}用户已取消操作。${PLAIN}"
                    else
                        echo -e "${RED}Operation aborted by user.${PLAIN}"
                    fi
                    return 1
                fi
            fi
        fi
    done
    return 0
}

optimize_system() {
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}正在优化内核网络参数 (BBR 与 QUIC/UDP 缓冲区)...${PLAIN}"
    else
        echo -e "${YELLOW}Optimizing kernel parameters (BBR & QUIC/UDP buffers)...${PLAIN}"
    fi
    local virt=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt 2>/dev/null)
    fi

    if [[ "$virt" =~ ^(lxc|openvz|docker|podman|container) ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${YELLOW}检测到容器虚拟化环境 (${virt})。${PLAIN}"
            echo -e "${YELLOW}已自动跳过内核 sysctl 参数调优（由宿主机统一管理）。${PLAIN}"
        else
            echo -e "${YELLOW}Container virtualization (${virt}) detected.${PLAIN}"
            echo -e "${YELLOW}Kernel sysctl parameter tuning skipped (managed by host node).${PLAIN}"
        fi
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
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${GREEN}系统内核网络参数优化完成！${PLAIN}"
        else
            echo -e "${GREEN}System parameters optimized!${PLAIN}"
        fi
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${YELLOW}提示: 内核参数已应用，但存在部分告警。${PLAIN}"
        else
            echo -e "${YELLOW}Notice: Kernel parameters applied with minor warnings.${PLAIN}"
        fi
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

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}正在下载 Sing-box ${target_ver} (${ARCH})...${PLAIN}"
    else
        echo -e "${YELLOW}Downloading Sing-box ${target_ver} (${ARCH})...${PLAIN}"
    fi
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! wget -q --show-progress -O "${tmp_dir}/${filename}" "${base_url}/${filename}"; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${RED}下载 Sing-box 核心失败！请检查 VPS 网络连接。${PLAIN}"
        else
            echo -e "${RED}Failed to download Sing-box binary! Check network connectivity.${PLAIN}"
        fi
        rm -rf "$tmp_dir"
        return 1
    fi

    # Strict SHA256 Checksum Verification
    if wget -q -O "${tmp_dir}/checksums.txt" "${base_url}/checksums.txt" 2>/dev/null && [[ -s "${tmp_dir}/checksums.txt" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${CYAN}正在校验 SHA256 完整性...${PLAIN}"
        else
            echo -e "${CYAN}Verifying SHA256 checksum...${PLAIN}"
        fi
        if ! (
            set -eo pipefail
            cd "$tmp_dir"
            grep -F " ${filename}" checksums.txt | sha256sum -c --status -
        ); then
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                echo -e "${RED}SHA256 校验和不匹配！终止安装。${PLAIN}"
            else
                echo -e "${RED}SHA256 checksum verification failed! Aborting installation.${PLAIN}"
            fi
            rm -rf "$tmp_dir"
            return 1
        fi
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${GREEN}SHA256 校验通过。${PLAIN}"
        else
            echo -e "${GREEN}SHA256 checksum verified.${PLAIN}"
        fi
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${YELLOW}警告: 未能获取 checksums.txt，跳过 SHA256 校验。${PLAIN}"
        else
            echo -e "${YELLOW}Warning: Could not fetch checksums.txt, skipping SHA256 verification.${PLAIN}"
        fi
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
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${GREEN}Sing-box ${target_ver} 已成功安装到 ${BIN_PATH}。${PLAIN}"
    else
        echo -e "${GREEN}Sing-box ${target_ver} installed to ${BIN_PATH}.${PLAIN}"
    fi
    return 0
}

# ----------------- SSL Certificate Management -----------------

verify_domain_dns() {
    local domain="$1"
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${CYAN}正在预检域名 ${domain} 的 DNS 解析...${PLAIN}"
    else
        echo -e "${CYAN}Pre-checking DNS resolution for ${domain}...${PLAIN}"
    fi
    local resolved_ipv4 resolved_ipv6
    resolved_ipv4=$(curl -s4m 4 "https://1.1.1.1/dns-query?name=${domain}&type=A" -H 'accept: application/dns-json' 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n 1)
    resolved_ipv6=$(curl -s4m 4 "https://1.1.1.1/dns-query?name=${domain}&type=AAAA" -H 'accept: application/dns-json' 2>/dev/null | jq -r '.Answer[]? | select(.type==28) | .data' 2>/dev/null | head -n 1)

    if [[ -z "$resolved_ipv4" ]] && command -v getent >/dev/null 2>&1; then
        resolved_ipv4=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -n 1)
        resolved_ipv6=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | head -n 1)
    fi

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "  - 解析 IPv4: ${resolved_ipv4:-无}"
        echo -e "  - 本机 IPv4: ${CACHED_IPV4:-未知}"
    else
        echo -e "  - Resolved IPv4: ${resolved_ipv4:-None}"
        echo -e "  - Server   IPv4: ${CACHED_IPV4:-N/A}"
    fi

    if [[ -n "$resolved_ipv4" && "$CACHED_IPV4" != "N/A" && "$resolved_ipv4" != "$CACHED_IPV4" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${YELLOW}警告: 域名解析的 IPv4 ($resolved_ipv4) 与服务器公网 IP ($CACHED_IPV4) 不一致！${PLAIN}"
            read -rp "确定要强制继续申请证书吗？ [y/N]: " force_dns
        else
            echo -e "${YELLOW}Warning: Domain resolved IPv4 ($resolved_ipv4) does not match server public IP ($CACHED_IPV4)!${PLAIN}"
            read -rp "Are you sure you want to proceed with certificate issuance? [y/N]: " force_dns
        fi
        [[ ! "$force_dns" =~ ^[Yy]$ ]] && return 1
    fi

    if [[ -n "$resolved_ipv6" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "  - 解析 IPv6: ${resolved_ipv6}"
        else
            echo -e "  - Resolved IPv6: ${resolved_ipv6}"
        fi
        if [[ "$CACHED_IPV6" == "N/A" || -z "$CACHED_IPV6" ]]; then
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                echo -e "${RED}注意: 域名配置了 AAAA (IPv6) 解析记录，但当前服务器无公网 IPv6！${PLAIN}"
                echo -e "${YELLOW}Let's Encrypt 会优先验证 IPv6，极大概率导致证书申请失败。${PLAIN}"
                echo -e "${YELLOW}建议: 请在 DNS 域名解析处先删除 AAAA (IPv6) 记录后再继续。${PLAIN}"
                read -rp "仍然强制继续？ [y/N]: " force_v6
            else
                echo -e "${RED}Caution: Domain has an AAAA (IPv6) record, but this server has no working public IPv6!${PLAIN}"
                echo -e "${YELLOW}Let's Encrypt validates IPv6 first and will likely fail.${PLAIN}"
                echo -e "${YELLOW}Tip: Remove the AAAA record in your DNS provider before continuing.${PLAIN}"
                read -rp "Proceed anyway? [y/N]: " force_v6
            fi
            [[ ! "$force_v6" =~ ^[Yy]$ ]] && return 1
        fi
    fi
    return 0
}

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

open_port_80() {
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}正在防火墙中强制放行 80 端口 (TCP) 以保障 Let's Encrypt 证书验证...${PLAIN}"
    else
        echo -e "${YELLOW}Enforcing Port 80 (TCP) open in firewall for Let's Encrypt issuance...${PLAIN}"
    fi

    # 1. UFW
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        ufw allow 80/tcp >/dev/null 2>&1 || true
    fi

    # 2. Firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --add-port=80/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
    fi

    # 3. Iptables & Ip6tables
    if command -v iptables >/dev/null 2>&1; then
        apply_iptables_rule filter INPUT -p tcp --dport 80 -j ACCEPT
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        apply_ip6tables_rule filter INPUT -p tcp --dport 80 -j ACCEPT
    fi
}

setup_ssl() {
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}正在配置 SSL 证书...${PLAIN}"
    else
        echo -e "${YELLOW}Configuring SSL Certificate...${PLAIN}"
    fi
    load_existing_config

    if [[ -z "$DOMAIN" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            read -rp "请输入您的域名 (必须已通过 DNS 解析到本机 IP): " DOMAIN
        else
            read -rp "Enter your domain name (must point to this server IP): " DOMAIN
        fi
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${CYAN}当前已配置的域名: ${DOMAIN}${PLAIN}"
            read -rp "是否继续使用此域名？ [Y/n]: " keep_dom
            if [[ "$keep_dom" =~ ^[Nn]$ ]]; then
                read -rp "请输入新域名: " DOMAIN
            fi
        else
            echo -e "${CYAN}Current configured domain: ${DOMAIN}${PLAIN}"
            read -rp "Keep using this domain? [Y/n]: " keep_dom
            if [[ "$keep_dom" =~ ^[Nn]$ ]]; then
                read -rp "Enter new domain name: " DOMAIN
            fi
        fi
    fi

    if [[ -z "$DOMAIN" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${RED}错误: 域名不能为空！${PLAIN}"
        else
            echo -e "${RED}Error: Domain name cannot be empty!${PLAIN}"
        fi
        return 1
    fi

    verify_domain_dns "$DOMAIN" || return 1

    # Force open port 80 and stop port-occupying services before SSL validation
    open_port_80
    systemctl stop sing-box 2>/dev/null

    local acme_bin="$HOME/.acme.sh/acme.sh"
    if [[ ! -x "$acme_bin" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${YELLOW}正在安装 acme.sh 证书申请工具...${PLAIN}"
        else
            echo -e "${YELLOW}Installing acme.sh certificate tool...${PLAIN}"
        fi

        # Primary: Official get.acme.sh via curl pipe
        curl -fsSL https://get.acme.sh | sh -s email="admin@${DOMAIN}" >/dev/null 2>&1 || true

        # Fallback 1: GitHub raw install-online
        if [[ ! -x "$acme_bin" ]]; then
            curl -fsSL https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh | sh -s -- --install-online -m "admin@${DOMAIN}" >/dev/null 2>&1 || true
        fi

        # Fallback 2: git clone
        if [[ ! -x "$acme_bin" ]] && command -v git >/dev/null 2>&1; then
            local acme_git_dir
            acme_git_dir=$(mktemp -d)
            if git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "$acme_git_dir" >/dev/null 2>&1; then
                (cd "$acme_git_dir" && ./acme.sh --install -m "admin@${DOMAIN}" >/dev/null 2>&1)
            fi
            rm -rf "$acme_git_dir"
        fi
    fi

    if [[ ! -x "$acme_bin" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${RED}错误: 安装 acme.sh 失败！请检查 VPS 网络连接。${PLAIN}"
        else
            echo -e "${RED}Error: Failed to install acme.sh! Please check network connectivity.${PLAIN}"
        fi
        return 1
    fi

    "$acme_bin" --upgrade --auto-upgrade >/dev/null 2>&1
    "$acme_bin" --set-default-ca --server letsencrypt >/dev/null 2>&1

    local stop_nginx=0 stop_apache=0 stop_caddy=0
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl stop nginx 2>/dev/null && stop_nginx=1
    fi
    if systemctl is-active --quiet apache2 2>/dev/null; then
        systemctl stop apache2 2>/dev/null && stop_apache=1
    fi
    if systemctl is-active --quiet caddy 2>/dev/null; then
        systemctl stop caddy 2>/dev/null && stop_caddy=1
    fi
    if command -v fuser >/dev/null 2>&1; then
        fuser -k 80/tcp >/dev/null 2>&1 || true
    fi

    if [[ ! -f "$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer" && ! -f "$HOME/.acme.sh/${DOMAIN}/fullchain.cer" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${YELLOW}正在为 ${DOMAIN} 申请 Let's Encrypt ECC 证书...${PLAIN}"
        else
            echo -e "${YELLOW}Issuing Let's Encrypt ECC certificate for ${DOMAIN}...${PLAIN}"
        fi
        if ! "$acme_bin" --issue -d "$DOMAIN" --standalone --keylength ec-256 --force; then
            [[ $stop_nginx -eq 1 ]] && systemctl start nginx 2>/dev/null || true
            [[ $stop_apache -eq 1 ]] && systemctl start apache2 2>/dev/null || true
            [[ $stop_caddy -eq 1 ]] && systemctl start caddy 2>/dev/null || true
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                echo -e "${RED}SSL 证书申请失败！请确保 80 端口未被占用且已放行，并且 ${DOMAIN} 正确解析到 ${CACHED_IPV4}。${PLAIN}"
            else
                echo -e "${RED}SSL issuance failed! Ensure port 80 is open and ${DOMAIN} resolves to ${CACHED_IPV4}.${PLAIN}"
            fi
            return 1
        fi
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${GREEN}检测到 ${DOMAIN} 已存在有效证书，跳过重复申请。${PLAIN}"
        else
            echo -e "${GREEN}Existing valid certificate found for ${DOMAIN}.${PLAIN}"
        fi
    fi

    [[ $stop_nginx -eq 1 ]] && systemctl start nginx 2>/dev/null || true
    [[ $stop_apache -eq 1 ]] && systemctl start apache2 2>/dev/null || true
    [[ $stop_caddy -eq 1 ]] && systemctl start caddy 2>/dev/null || true

    mkdir -p "$CERT_DIR"
    "$acme_bin" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "${CERT_DIR}/fullchain.pem" \
        --key-file "${CERT_DIR}/private.key" \
        --reloadcmd "systemctl restart sing-box 2>/dev/null || true" >/dev/null 2>&1

    chmod 600 "${CERT_DIR}/private.key"
    chmod 644 "${CERT_DIR}/fullchain.pem"
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${GREEN}SSL 证书已安装至 ${CERT_DIR}。${PLAIN}"
    else
        echo -e "${GREEN}SSL certificate installed to ${CERT_DIR}.${PLAIN}"
    fi
    return 0
}

# ----------------- Firewall & Port Hopping -----------------

setup_firewall() {
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}正在配置防火墙规则 (IPv4 & IPv6)...${PLAIN}"
    else
        echo -e "${YELLOW}Configuring firewall rules (IPv4 & IPv6)...${PLAIN}"
    fi
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

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${GREEN}防火墙规则配置成功！${PLAIN}"
    else
        echo -e "${GREEN}Firewall configured successfully!${PLAIN}"
    fi
}

# Select or switch WARP outbound IP version preference
select_warp_ip_preference() {
    local cur_strat=""
    if [[ -f "$WARP_CONF" ]]; then
        cur_strat=$(jq -r '.domain_strategy // empty' "$WARP_CONF" 2>/dev/null)
    fi

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}--- Cloudflare WARP 出站 IP 偏好设置 ---${PLAIN}"
        echo -e " 1. ${GREEN}IPv6 优先 (极力推荐)${PLAIN} - 针对 OpenAI、Claude、Google 信誉最高 (零验证码)"
        echo -e " 2. ${CYAN}IPv4 优先${PLAIN} - 对传统流媒体网站兼容性最佳"
        echo -e " 3. ${YELLOW}自适应 (双栈)${PLAIN} - 默认 DNS 解析，不强制指定偏好"
        read -rp "请选择出站偏好 [1-3, 默认 1]: " pref_choice
    else
        echo -e "${YELLOW}--- Cloudflare WARP Outbound IP Preference ---${PLAIN}"
        echo -e " 1. ${GREEN}IPv6 Preferred (Recommended)${PLAIN} - Cleanest IP for OpenAI, Claude, Google (No Captchas)"
        echo -e " 2. ${CYAN}IPv4 Preferred${PLAIN} - Best compatibility for legacy streaming services"
        echo -e " 3. ${YELLOW}Auto (Dual-stack)${PLAIN} - Default DNS resolution without preference"
        read -rp "Select preference [1-3, default 1]: " pref_choice
    fi

    pref_choice=$(echo "$pref_choice" | tr -d '\r' | tr -d ' ')
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
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}--- Cloudflare WARP 管理 ---${PLAIN}"
        if [[ ! -x "$BIN_PATH" || ! -f "$CONFIG_FILE" ]]; then
            echo -e "${RED}错误: Sing-box 尚未完全安装！请先运行选项 1。${PLAIN}"
            return 1
        fi
    else
        echo -e "${YELLOW}--- Cloudflare WARP Management ---${PLAIN}"
        if [[ ! -x "$BIN_PATH" || ! -f "$CONFIG_FILE" ]]; then
            echo -e "${RED}Error: Sing-box is not fully installed! Please run Option 1 first.${PLAIN}"
            return 1
        fi
    fi

    if [[ -f "$WARP_CONF" ]]; then
        local cur_strat
        cur_strat=$(jq -r '.domain_strategy // empty' "$WARP_CONF" 2>/dev/null)
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            case "$cur_strat" in
                prefer_ipv6) cur_strat="IPv6 优先" ;;
                prefer_ipv4) cur_strat="IPv4 优先" ;;
                *) cur_strat="自适应 (双栈)" ;;
            esac
            echo -e "${GREEN}WARP 当前已启用 (当前出站偏好: ${cur_strat})。${PLAIN}"
            echo -e " 1. 切换出站 IP 偏好 (IPv6 / IPv4 / 自适应)"
            echo -e " 2. 重新注册 WARP 账号"
            echo -e " 3. 停用并移除 WARP"
            echo -e " 0. 返回"
            read -rp "请选择操作 [0-3]: " warp_act
        else
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
        fi

        warp_act=$(echo "$warp_act" | tr -d '\r' | tr -d ' ')
        case "$warp_act" in
            1)
                select_warp_ip_preference
                load_existing_config
                generate_config
                systemctl restart sing-box
                if [[ "$CURRENT_LANG" == "zh" ]]; then
                    echo -e "${GREEN}WARP 出站偏好已更新，Sing-box 服务已重启！${PLAIN}"
                    read -rp "是否立即检测流媒体与 AI 解锁状态？ [Y/n]: " check_now
                else
                    echo -e "${GREEN}WARP outbound preference updated and Sing-box restarted!${PLAIN}"
                    read -rp "Test streaming & AI unlock status now? [Y/n]: " check_now
                fi
                check_now=$(echo "$check_now" | tr -d '\r' | tr -d ' ')
                [[ ! "$check_now" =~ ^[Nn]$ ]] && check_media_unlock
                return 0
                ;;
            2) rm -f "$WARP_CONF" ;;
            3)
                rm -f "$WARP_CONF"
                load_existing_config
                generate_config
                systemctl restart sing-box
                if [[ "$CURRENT_LANG" == "zh" ]]; then
                    echo -e "${GREEN}WARP 已移除，Sing-box 服务已重启。${PLAIN}"
                else
                    echo -e "${GREEN}WARP removed and Sing-box restarted.${PLAIN}"
                fi
                return 0
                ;;
            *) return 0 ;;
        esac
    fi

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${CYAN}正在本地生成 WireGuard 密钥对并通过 Cloudflare 官方 API 注册...${PLAIN}"
    else
        echo -e "${CYAN}Generating WireGuard keypair locally and registering with Cloudflare Official API...${PLAIN}"
    fi
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
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                echo -e "${GREEN}通过 Cloudflare 官方 API 注册成功！${PLAIN}"
            else
                echo -e "${GREEN}Successfully registered via Official Cloudflare API!${PLAIN}"
            fi
        fi
    fi

    # Ask for explicit user consent before falling back to third-party APIs
    if [[ ! -s "$WARP_CONF" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${YELLOW}警告: 官方 Cloudflare API 注册失败 (可能触发频率限制)。${PLAIN}"
            echo -e "${RED}安全提示: 备用第三方 API 会在远程生成 WireGuard 私钥。${PLAIN}"
            read -rp "是否仍要使用备用第三方 API？ [y/N]: " allow_fallback
        else
            echo -e "${YELLOW}Warning: Official Cloudflare API registration failed (likely rate-limited).${PLAIN}"
            echo -e "${RED}Security Notice: Fallback third-party APIs generate the WireGuard private key remotely.${PLAIN}"
            read -rp "Do you want to use third-party fallback APIs anyway? [y/N]: " allow_fallback
        fi
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
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${RED}错误: WARP 注册失败！请检查 VPS 出站网络连通性。${PLAIN}"
        else
            echo -e "${RED}Error: WARP registration failed! Check VPS outbound connectivity.${PLAIN}"
        fi
        rm -f "$WARP_CONF"
        return 1
    fi

    chmod 600 "$WARP_CONF"

    # Allow user to choose initial preference
    select_warp_ip_preference

    load_existing_config
    generate_config
    systemctl restart sing-box
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${GREEN}WARP 已成功接入 Sing-box，服务已重启！${PLAIN}"
        read -rp "是否立即检测流媒体与 AI 解锁状态？ [Y/n]: " check_now
    else
        echo -e "${GREEN}WARP integrated into Sing-box and service restarted!${PLAIN}"
        read -rp "Test streaming & AI unlock status now? [Y/n]: " check_now
    fi
    check_now=$(echo "$check_now" | tr -d '\r' | tr -d ' ')
    [[ ! "$check_now" =~ ^[Nn]$ ]] && check_media_unlock
}

# ----------------- Configuration Generation (via jq) -----------------

generate_config() {
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}正在使用 jq 构建 Sing-box 配置文件...${PLAIN}"
    else
        echo -e "${YELLOW}Building Sing-box configuration via jq...${PLAIN}"
    fi

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

    # Build Base Configuration (Modern Sing-box 1.11+ / 1.14+ compatible)
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
                    type: "mixed",
                    tag: "local-in",
                    listen: "127.0.0.1",
                    listen_port: 10808
                },
                {
                    type: "naive",
                    tag: "naive-in",
                    listen: "::",
                    listen_port: 443,
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
                    { action: "sniff" },
                    { ip_is_private: true, outbound: "block" },
                    { protocol: ["bittorrent"], outbound: "block" }
                ],
                final: "direct"
            }
        }')

    # Inject WARP Endpoint & Comprehensive AI/Streaming Routing Rules if configured
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
                '.endpoints = [{
                    type: "wireguard",
                    tag: "warp-out",
                    address: ["172.16.0.2/32", $v6],
                    private_key: $priv,
                    peers: [{
                        address: $ep,
                        port: $epport,
                        public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0T7ncGA5S2NoKLU=",
                        allowed_ips: ["0.0.0.0/0", "::/0"],
                        reserved: $resv
                    }],
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
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${GREEN}Sing-box 配置校验通过，服务已启动！${PLAIN}"
        else
            echo -e "${GREEN}Sing-box configuration validated and service started!${PLAIN}"
        fi
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${RED}错误: Sing-box 配置校验失败！${PLAIN}"
        else
            echo -e "${RED}Error: Sing-box configuration validation failed!${PLAIN}"
        fi
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
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${CYAN}正在从远程安装 'nb' 快捷命令...${PLAIN}"
        else
            echo -e "${CYAN}Installing 'nb' shortcut from remote source...${PLAIN}"
        fi
        curl -fsSL "$REMOTE_SCRIPT_URL" -o "$SHORTCUT_BIN" 2>/dev/null || wget -qO "$SHORTCUT_BIN" "$REMOTE_SCRIPT_URL" 2>/dev/null || true
    fi

    if [[ -f "$SHORTCUT_BIN" ]]; then
        chmod +x "$SHORTCUT_BIN"
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${CYAN}快捷命令已安装！在终端随时输入 'nb' 即可打开此管理菜单。${PLAIN}"
        else
            echo -e "${CYAN}Shortcut installed! Type 'nb' anytime to open this manager.${PLAIN}"
        fi
    fi
}

# ----------------- Display Configs & Client Snippets -----------------

show_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${RED}错误: 未找到配置文件！请先安装。${PLAIN}"
        else
            echo -e "${RED}Error: Configuration file not found! Please install first.${PLAIN}"
        fi
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
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${PURPLE}#               节点配置与客户端导入链接                    #${PLAIN}"
    else
        echo -e "${PURPLE}#               CONFIGURATIONS & IMPORT LINKS               #${PLAIN}"
    fi
    echo -e "${PURPLE}=============================================================${PLAIN}"
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}服务器域名:${PLAIN}  ${DOMAIN}"
        echo -e "${YELLOW}服务器 IPv4:${PLAIN} ${CACHED_IPV4}"
        [[ "$CACHED_IPV6" != "N/A" ]] && echo -e "${YELLOW}服务器 IPv6:${PLAIN} ${CACHED_IPV6}"
        echo ""
        echo -e "${GREEN}[1] NaiveProxy 节点 (TCP/UDP 443)${PLAIN}"
        echo -e "  - v2rayN / NekoBox 链接: ${CYAN}${link_nav}${PLAIN}"
        echo -e "  - Shadowrocket 专用链接:  ${CYAN}${link_roc}${PLAIN}"
        echo ""
        echo -e "${GREEN}[2] Hysteria2 节点 (UDP ${HY2_PORT}${HY2_HOP_START:+ | 跳跃端口: ${HY2_HOP_START}-${HY2_HOP_END}})${PLAIN}"
        echo -e "  - 通用订阅链接:           ${CYAN}${link_hy2}${PLAIN}"
        echo ""
        echo -e "${GREEN}[3] Clash Meta (Mihomo) YAML 节点配置片段:${PLAIN}"
    else
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
    fi
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
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}二维码 - Shadowrocket (NaiveProxy 协议):${PLAIN}"
    else
        echo -e "${YELLOW}QR Code - Shadowrocket (NaiveProxy):${PLAIN}"
    fi
    qrencode -t ansiutf8 "${link_roc}"
    echo ""
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}二维码 - Hysteria2 协议:${PLAIN}"
    else
        echo -e "${YELLOW}QR Code - Hysteria2:${PLAIN}"
    fi
    qrencode -t ansiutf8 "${link_hy2}"
    echo -e "${PURPLE}=============================================================${PLAIN}"
}

# ----------------- Modification Functions -----------------

modify_credentials() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${RED}错误: 未找到配置文件！${PLAIN}"
        else
            echo -e "${RED}Error: Config file not found!${PLAIN}"
        fi
        return
    fi
    load_existing_config

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}--- 修改凭证 (直接回车保留当前配置) ---${PLAIN}"
        read -rp "NaiveProxy 用户名 [当前: ${NAIVE_USER}]: " new_n_user
        read -rp "NaiveProxy 密码   [当前: ${NAIVE_PASS}]: " new_n_pass
        read -rp "Hysteria2  密码   [当前: ${HY2_PASS}]: " new_h_pass
    else
        echo -e "${YELLOW}--- Modify Credentials (Leave blank to keep current) ---${PLAIN}"
        read -rp "NaiveProxy Username [current: ${NAIVE_USER}]: " new_n_user
        read -rp "NaiveProxy Password [current: ${NAIVE_PASS}]: " new_n_pass
        read -rp "Hysteria2 Password  [current: ${HY2_PASS}]: " new_h_pass
    fi

    [[ -n "$new_n_user" ]] && NAIVE_USER="$new_n_user"
    [[ -n "$new_n_pass" ]] && NAIVE_PASS="$new_n_pass"
    [[ -n "$new_h_pass" ]] && HY2_PASS="$new_h_pass"

    generate_config
    systemctl restart sing-box
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${GREEN}凭证已更新，Sing-box 服务已重启！${PLAIN}"
    else
        echo -e "${GREEN}Credentials updated and Sing-box restarted!${PLAIN}"
    fi
}

modify_hy2_advanced() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${RED}错误: 未找到配置文件！${PLAIN}"
        else
            echo -e "${RED}Error: Config file not found!${PLAIN}"
        fi
        return
    fi
    load_existing_config

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}--- 配置 Hysteria2 伪装域名、端口跳跃与 Brutal 限速 ---${PLAIN}"
        read -rp "伪装网站 URL [当前: ${HY2_MASK}]: " new_mask
    else
        echo -e "${YELLOW}--- Modify Hysteria2 Masquerade, Port Hopping & Brutal ---${PLAIN}"
        read -rp "Masquerade URL [current: ${HY2_MASK}]: " new_mask
    fi

    if [[ -n "$new_mask" ]]; then
        if [[ "$new_mask" =~ ^https?://[a-zA-Z0-9._/-]+$ ]]; then
            HY2_MASK="$new_mask"
        else
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                echo -e "${RED}URL 格式无效！保留当前伪装站。${PLAIN}"
            else
                echo -e "${RED}Invalid URL format! Keeping current masquerade URL.${PLAIN}"
            fi
        fi
    fi

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        read -rp "是否启用 UDP 端口跳跃？ [y/N]: " en_hop
    else
        read -rp "Enable UDP Port Hopping? [y/N]: " en_hop
    fi

    if [[ "$en_hop" =~ ^[Yy]$ ]]; then
        local hop_s hop_e
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            read -rp "起始端口 (1024-65534, 例如 20000): " hop_s
            read -rp "结束端口 (1025-65535, 例如 50000): " hop_e
        else
            read -rp "Start Port (1024-65534, e.g. 20000): " hop_s
            read -rp "End Port (1025-65535, e.g. 50000): " hop_e
        fi
        if validate_port_range "$hop_s" "$hop_e"; then
            HY2_HOP_START="$hop_s"
            HY2_HOP_END="$hop_e"
            printf "HY2_HOP_START=%d\nHY2_HOP_END=%d\n" "$HY2_HOP_START" "$HY2_HOP_END" > "${CONFIG_DIR}/hop.conf"
            chmod 600 "${CONFIG_DIR}/hop.conf"
        else
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                echo -e "${YELLOW}端口范围无效，已跳过端口跳跃配置。${PLAIN}"
            else
                echo -e "${YELLOW}Port hopping configuration skipped due to invalid input.${PLAIN}"
            fi
        fi
    else
        HY2_HOP_START=""
        HY2_HOP_END=""
        rm -f "${CONFIG_DIR}/hop.conf"
    fi

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        read -rp "是否配置 Brutal 强制带宽速率？(直接回车使用标准 BBR) [y/N]: " en_brutal
    else
        read -rp "Configure Brutal Bandwidth limits? (Leave blank for standard BBR) [y/N]: " en_brutal
    fi

    if [[ "$en_brutal" =~ ^[Yy]$ ]]; then
        local up_m down_m
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            read -rp "服务器上行带宽 Mbps (例如 100): " up_m
            read -rp "服务器下行带宽 Mbps (例如 100): " down_m
        else
            read -rp "Server Upload Bandwidth in Mbps (e.g. 100): " up_m
            read -rp "Server Download Bandwidth in Mbps (e.g. 100): " down_m
        fi
        if [[ "$up_m" =~ ^[0-9]+$ && "$down_m" =~ ^[0-9]+$ ]] && (( up_m > 0 && down_m > 0 )); then
            HY2_UP_MBPS="$up_m"
            HY2_DOWN_MBPS="$down_m"
        else
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                echo -e "${RED}带宽数值无效！将继续使用标准 BBR。${PLAIN}"
            else
                echo -e "${RED}Invalid bandwidth numbers! Using standard BBR.${PLAIN}"
            fi
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
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${GREEN}Hysteria2 配置已更新并生效！${PLAIN}"
    else
        echo -e "${GREEN}Hysteria2 settings updated and applied!${PLAIN}"
    fi
}

cleanup_firewall() {
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}正在清理防火墙放行规则...${PLAIN}"
    else
        echo -e "${YELLOW}Cleaning up firewall rules...${PLAIN}"
    fi
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
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        read -rp "确定要彻底卸载 Sing-box 吗？ [y/N]: " confirm
    else
        read -rp "Are you sure you want to completely uninstall Sing-box? [y/N]: " confirm
    fi
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${YELLOW}正在卸载 Sing-box 并还原系统配置...${PLAIN}"
    else
        echo -e "${YELLOW}Uninstalling Sing-box and reverting system changes...${PLAIN}"
    fi
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
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${YELLOW}是否处理 acme.sh SSL 证书管理工具？${PLAIN}"
            echo -e " 1. 仅移除当前域名的证书 ($DOMAIN)"
            echo -e " 2. 彻底卸载 acme.sh 并清理所有定时续期任务"
            echo -e " 3. 保留 acme.sh 原状 (供其他网站使用)"
            read -rp "请选择操作 [1-3, 默认 1]: " acme_clean_opt
        else
            echo -e "${YELLOW}Do you want to handle acme.sh SSL certificate tool?${PLAIN}"
            echo -e " 1. Remove only this domain certificate ($DOMAIN)"
            echo -e " 2. Completely uninstall acme.sh and remove all renewal cron jobs"
            echo -e " 3. Keep acme.sh as-is (for other websites)"
            read -rp "Select option [1-3, default 1]: " acme_clean_opt
        fi
        acme_clean_opt=$(echo "$acme_clean_opt" | tr -d '\r' | tr -d ' ')
        case "$acme_clean_opt" in
            2)
                "$HOME/.acme.sh/acme.sh" --uninstall >/dev/null 2>&1 || true
                rm -rf "$HOME/.acme.sh"
                if [[ "$CURRENT_LANG" == "zh" ]]; then
                    echo -e "${GREEN}acme.sh 及其定时任务已彻底删除。${PLAIN}"
                else
                    echo -e "${GREEN}acme.sh and its cron tasks completely removed.${PLAIN}"
                fi
                ;;
            3)
                if [[ "$CURRENT_LANG" == "zh" ]]; then
                    echo -e "${CYAN}保留 acme.sh 目录。${PLAIN}"
                else
                    echo -e "${CYAN}Preserving acme.sh directory.${PLAIN}"
                fi
                ;;
            *)
                if [[ -n "$DOMAIN" ]]; then
                    "$HOME/.acme.sh/acme.sh" --remove -d "$DOMAIN" --ecc >/dev/null 2>&1 || true
                    if [[ "$CURRENT_LANG" == "zh" ]]; then
                        echo -e "${GREEN}当前域名证书已从 acme.sh 中注销。${PLAIN}"
                    else
                        echo -e "${GREEN}Domain certificate removed from acme.sh.${PLAIN}"
                    fi
                fi
                ;;
        esac
    fi

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${GREEN}卸载完成！${PLAIN}"
    else
        echo -e "${GREEN}Uninstallation completed successfully!${PLAIN}"
    fi
    exit 0
}

# ----------------- Streaming & AI Unlock Check -----------------

test_stream_route() {
    local route_name="$1"
    shift
    local -a proxy_opts=("$@")

    echo -e "${YELLOW}>> 正在检测: ${route_name}...${PLAIN}"

    # 1. IP & Location via Cloudflare Trace
    local trace_url="https://cloudflare.com/cdn-cgi/trace"
    if [[ ${#proxy_opts[@]} -gt 0 && -s "$WARP_CONF" ]]; then
        trace_url="https://chatgpt.com/cdn-cgi/trace"
    fi

    local trace_out ip_val loc_val colo_val warp_val
    trace_out=$(curl -s -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" --max-time 6 "${proxy_opts[@]}" "$trace_url" 2>/dev/null)
    ip_val=$(echo "$trace_out" | grep '^ip=' | cut -d= -f2)
    loc_val=$(echo "$trace_out" | grep '^loc=' | cut -d= -f2)
    colo_val=$(echo "$trace_out" | grep '^colo=' | cut -d= -f2)
    warp_val=$(echo "$trace_out" | grep '^warp=' | cut -d= -f2)

    if [[ -z "$ip_val" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "   ${RED}网络连接失败或出口不可达！${PLAIN}"
        else
            echo -e "   ${RED}Connection failed or outbound unreachable!${PLAIN}"
        fi
        return 1
    fi

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "   出口 IP:     ${CYAN}${ip_val}${PLAIN} (${loc_val:-未知}${colo_val:+ | 节点: ${colo_val}} | WARP: ${warp_val:-off})"
    else
        echo -e "   Outbound IP: ${CYAN}${ip_val}${PLAIN} (${loc_val:-Unknown}${colo_val:+ | Colo: ${colo_val}} | WARP: ${warp_val:-off})"
    fi

    # 2. Netflix Check
    local nf_res nf_code
    nf_code=$(curl -sL -o /dev/null -w "%{http_code}" -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" --max-time 7 "${proxy_opts[@]}" "https://www.netflix.com/title/70143836" 2>/dev/null)
    if [[ "$nf_code" == "200" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            nf_res="${GREEN}完整原生解锁 (支持全部自制与非自制剧)${PLAIN}"
        else
            nf_res="${GREEN}Full Unlock (Full Catalog & Non-Originals)${PLAIN}"
        fi
    else
        local nf_orig
        nf_orig=$(curl -sL -o /dev/null -w "%{http_code}" -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" --max-time 7 "${proxy_opts[@]}" "https://www.netflix.com/title/80018499" 2>/dev/null)
        if [[ "$nf_orig" == "200" ]]; then
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                nf_res="${YELLOW}仅支持自制剧 (Originals Only)${PLAIN}"
            else
                nf_res="${YELLOW}Originals Only${PLAIN}"
            fi
        else
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                nf_res="${RED}不支持 / 已被封锁${PLAIN}"
            else
                nf_res="${RED}No / Blocked${PLAIN}"
            fi
        fi
    fi
    echo -e "   Netflix:     ${nf_res}"

    # 3. Disney+ Check
    local dp_info dp_code dp_url dp_res
    dp_info=$(curl -sL -o /dev/null -w "%{http_code} %{url_effective}" -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" --max-time 7 "${proxy_opts[@]}" "https://www.disneyplus.com/" 2>/dev/null)
    dp_code=$(echo "$dp_info" | awk '{print $1}')
    dp_url=$(echo "$dp_info" | awk '{print $2}')
    if [[ "$dp_url" =~ unavailable ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            dp_res="${YELLOW}所在地区暂未开放服务${PLAIN}"
        else
            dp_res="${YELLOW}Unavailable in Region${PLAIN}"
        fi
    elif [[ "$dp_code" == "403" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            dp_res="${RED}不支持 (IP 被拒绝访问)${PLAIN}"
        else
            dp_res="${RED}No (IP Blocked)${PLAIN}"
        fi
    elif [[ "$dp_code" =~ ^(200|301|302)$ ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            dp_res="${GREEN}支持解锁${PLAIN}"
        else
            dp_res="${GREEN}Unlocked / Yes${PLAIN}"
        fi
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            dp_res="${RED}检测超时或无法访问 (HTTP ${dp_code})${PLAIN}"
        else
            dp_res="${RED}Timeout or Failed (HTTP ${dp_code})${PLAIN}"
        fi
    fi
    echo -e "   Disney+:     ${dp_res}"

    # 4. YouTube Premium Check
    local yt_html yt_country yt_res
    yt_html=$(curl -sL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" --max-time 7 "${proxy_opts[@]}" "https://www.youtube.com/premium" 2>/dev/null)
    yt_country=$(echo "$yt_html" | grep -o '"countryCode":"[^"]*"' | head -n1 | cut -d'"' -f4)
    if [[ -n "$yt_country" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            yt_res="${GREEN}支持解锁 (地区: ${yt_country})${PLAIN}"
        else
            yt_res="${GREEN}Unlocked / Yes (Region: ${yt_country})${PLAIN}"
        fi
    else
        if echo "$yt_html" | grep -qi "Premium is not available"; then
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                yt_res="${YELLOW}该地区未开放 Premium${PLAIN}"
            else
                yt_res="${YELLOW}Premium Not Available in Region${PLAIN}"
            fi
        else
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                yt_res="${RED}检测超时或受限${PLAIN}"
            else
                yt_res="${RED}Timeout or Restricted${PLAIN}"
            fi
        fi
    fi
    echo -e "   YouTube:     ${yt_res}"

    # 5. OpenAI / ChatGPT Check
    local ai_web_code ai_ios_status ai_res
    ai_web_code=$(curl -sL -o /dev/null -w "%{http_code}" -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" --max-time 7 "${proxy_opts[@]}" "https://chatgpt.com" 2>/dev/null)
    ai_ios_status=$(curl -s -A "Mozilla/5.0" --max-time 6 "${proxy_opts[@]}" "https://ios.chat.openai.com/public-api/mobile/server_status/v1" 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    if [[ "$ai_web_code" =~ ^(200|307|308)$ && "$ai_ios_status" == "normal" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            ai_res="${GREEN}全面解锁 (网页端与 App 端)${PLAIN}"
        else
            ai_res="${GREEN}Full Unlock (Web & App)${PLAIN}"
        fi
    elif [[ "$ai_ios_status" == "normal" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            ai_res="${YELLOW}仅 App / API 端解锁 (网页端受限: HTTP ${ai_web_code})${PLAIN}"
        else
            ai_res="${YELLOW}App & API Only (Web Blocked: HTTP ${ai_web_code})${PLAIN}"
        fi
    elif [[ "$ai_web_code" == "403" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            ai_res="${RED}不支持 / 已被 Cloudflare 拦截封禁${PLAIN}"
        else
            ai_res="${RED}No / Blocked by Cloudflare${PLAIN}"
        fi
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            ai_res="${RED}检测超时或无法访问 (HTTP ${ai_web_code})${PLAIN}"
        else
            ai_res="${RED}Timeout or Failed (HTTP ${ai_web_code})${PLAIN}"
        fi
    fi
    echo -e "   OpenAI:      ${ai_res}"

    # 6. Claude AI Check
    local claude_code claude_res
    claude_code=$(curl -sL -o /dev/null -w "%{http_code}" -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" --max-time 7 "${proxy_opts[@]}" "https://claude.ai/login" 2>/dev/null)
    if [[ "$claude_code" =~ ^(200|301|302|307|308)$ ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            claude_res="${GREEN}支持解锁${PLAIN}"
        else
            claude_res="${GREEN}Unlocked / Yes${PLAIN}"
        fi
    elif [[ "$claude_code" == "403" ]]; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            claude_res="${RED}不支持 / 已被 Cloudflare 拦截封禁${PLAIN}"
        else
            claude_res="${RED}No / Blocked by Cloudflare${PLAIN}"
        fi
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            claude_res="${RED}检测超时或无法访问 (HTTP ${claude_code})${PLAIN}"
        else
            claude_res="${RED}Timeout or Failed (HTTP ${claude_code})${PLAIN}"
        fi
    fi
    echo -e "   Claude AI:   ${claude_res}"
}

check_media_unlock() {
    clear
    echo -e "${PURPLE}=============================================================${PLAIN}"
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${PURPLE}#               流媒体与 AI 服务解锁状态检测                #${PLAIN}"
    else
        echo -e "${PURPLE}#             STREAMING & AI UNLOCK STATUS CHECK            #${PLAIN}"
    fi
    echo -e "${PURPLE}=============================================================${PLAIN}"

    # Auto upgrade config if local-in is missing in existing installation
    if [[ -f "$CONFIG_FILE" ]] && ! grep -q '"local-in"' "$CONFIG_FILE" 2>/dev/null; then
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${YELLOW}检测到现有配置缺少本地回环检测入口，正在自动热更新配置文件...${PLAIN}"
        else
            echo -e "${YELLOW}Local loopback inbound not found in existing config, auto-updating...${PLAIN}"
        fi
        load_existing_config
        generate_config
        systemctl is-active --quiet sing-box && systemctl restart sing-box
    fi

    # 1. Direct VPS route
    local direct_label
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        direct_label="[1] VPS 本机原生网络直连出口 (Direct Native IP)"
    else
        direct_label="[1] VPS Direct Native Route (Direct Native IP)"
    fi
    test_stream_route "$direct_label"
    echo ""

    # 2. Sing-box route (via 127.0.0.1:10808)
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        local warp_status_text=""
        if [[ -s "$WARP_CONF" ]]; then
            warp_status_text="[WARP 出站已启用]"
        else
            warp_status_text="[默认直连出站]"
        fi
        local singbox_label
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            singbox_label="[2] Sing-box 代理路由出口 (端口 10808 ${warp_status_text})"
        else
            singbox_label="[2] Sing-box Proxy Route (Port 10808 ${warp_status_text})"
        fi
        test_stream_route "$singbox_label" -x "socks5h://127.0.0.1:10808"
        echo ""
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            echo -e "${YELLOW}[2] Sing-box 服务未运行，跳过代理路由出口检测。${PLAIN}"
        else
            echo -e "${YELLOW}[2] Sing-box service not active, skipping proxy route check.${PLAIN}"
        fi
        echo ""
    fi

    echo -e "${PURPLE}=============================================================${PLAIN}"
    local run_third_party
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        read -rp "是否运行第三方社区增强脚本 (RegionRestrictionCheck) 测试更多小众平台？ [y/N]: " run_third_party
    else
        read -rp "Run 3rd-party community script (RegionRestrictionCheck) for exhaustive tests? [y/N]: " run_third_party
    fi
    run_third_party=$(echo "$run_third_party" | tr -d '\r' | tr -d ' ')
    if [[ "$run_third_party" =~ ^[Yy]$ ]]; then
        bash <(curl -L -s https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh)
    fi
}

# ----------------- Status & Main Menu Loop -----------------

get_vps_status() {
    load_existing_config
    local os_name kernel_ver bbr_status svc_status warp_status
    local nav_status hy2_status
    os_name=$(grep -w "PRETTY_NAME" /etc/os-release 2>/dev/null | cut -d '"' -f 2 || uname -s)
    kernel_ver=$(uname -r)
    bbr_status=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")

    local is_svc_active=0
    if systemctl is-active --quiet sing-box; then
        is_svc_active=1
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            svc_status="${GREEN}运行中${PLAIN}"
        else
            svc_status="${GREEN}Running${PLAIN}"
        fi
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            svc_status="${RED}已停止${PLAIN}"
        else
            svc_status="${RED}Stopped${PLAIN}"
        fi
    fi

    if [[ -s "$WARP_CONF" ]]; then
        local strat_label
        strat_label=$(jq -r '.domain_strategy // empty' "$WARP_CONF" 2>/dev/null)
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            case "$strat_label" in
                prefer_ipv6) warp_status="${GREEN}IPv6 优先${PLAIN}" ;;
                prefer_ipv4) warp_status="${GREEN}IPv4 优先${PLAIN}" ;;
                *) warp_status="${GREEN}自适应${PLAIN}" ;;
            esac
        else
            case "$strat_label" in
                prefer_ipv6) warp_status="${GREEN}IPv6 Preferred${PLAIN}" ;;
                prefer_ipv4) warp_status="${GREEN}IPv4 Preferred${PLAIN}" ;;
                *) warp_status="${GREEN}Auto${PLAIN}" ;;
            esac
        fi
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            warp_status="${YELLOW}已禁用${PLAIN}"
        else
            warp_status="${YELLOW}Disabled${PLAIN}"
        fi
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        if [[ $is_svc_active -eq 1 ]]; then
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                nav_status="${GREEN}运行中${PLAIN} (端口: 443 | Chromium 内核栈)"
                hy2_status="${GREEN}运行中${PLAIN} (端口: ${HY2_PORT:-443}${HY2_HOP_START:+ | 跳跃: ${HY2_HOP_START}-${HY2_HOP_END}})"
            else
                nav_status="${GREEN}Active${PLAIN} (Port: 443 | Chromium Stack)"
                hy2_status="${GREEN}Active${PLAIN} (Port: ${HY2_PORT:-443}${HY2_HOP_START:+ | Hop: ${HY2_HOP_START}-${HY2_HOP_END}})"
            fi
        else
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                nav_status="${YELLOW}已就绪/未运行${PLAIN} (端口: 443)"
                hy2_status="${YELLOW}已就绪/未运行${PLAIN} (端口: ${HY2_PORT:-443})"
            else
                nav_status="${YELLOW}Ready/Stopped${PLAIN} (Port: 443)"
                hy2_status="${YELLOW}Ready/Stopped${PLAIN} (Port: ${HY2_PORT:-443})"
            fi
        fi
    else
        if [[ "$CURRENT_LANG" == "zh" ]]; then
            nav_status="${RED}未配置${PLAIN}"
            hy2_status="${RED}未配置${PLAIN}"
        else
            nav_status="${RED}Not Configured${PLAIN}"
            hy2_status="${RED}Not Configured${PLAIN}"
        fi
    fi

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${BLUE}---------------- VPS 与服务运行状态 ----------------${PLAIN}"
        echo -e "${CYAN}操作系统/内核:${PLAIN}   ${os_name} (${kernel_ver} | ${ARCH})"
        echo -e "${CYAN}拥塞控制算法:${PLAIN}   ${bbr_status}"
        echo -e "${CYAN}公网 IPv4:${PLAIN}       ${CACHED_IPV4}"
        echo -e "${CYAN}Sing-box 核心:${PLAIN}  ${svc_status}   | ${CYAN}WARP 状态:${PLAIN} ${warp_status}"
        echo -e "${CYAN}NaiveProxy 协议:${PLAIN} ${nav_status}"
        echo -e "${CYAN}Hysteria2  协议:${PLAIN} ${hy2_status}"
        echo -e "${BLUE}------------------------------------------------------${PLAIN}"
    else
        echo -e "${BLUE}---------------- VPS & Service Status ----------------${PLAIN}"
        echo -e "${CYAN}OS / Kernel:${PLAIN}    ${os_name} (${kernel_ver} | ${ARCH})"
        echo -e "${CYAN}Congestion:${PLAIN}     ${bbr_status}"
        echo -e "${CYAN}Public IP:${PLAIN}      ${CACHED_IPV4}"
        echo -e "${CYAN}Sing-box Core:${PLAIN}  ${svc_status}   | ${CYAN}WARP:${PLAIN} ${warp_status}"
        echo -e "${CYAN}NaiveProxy:${PLAIN}     ${nav_status}"
        echo -e "${CYAN}Hysteria2:${PLAIN}      ${hy2_status}"
        echo -e "${BLUE}------------------------------------------------------${PLAIN}"
    fi
}

install_full_flow() {
    install_dependencies
    check_ports || return 1
    optimize_system
    install_singbox || return 1
    open_port_80
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
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        echo -e "${PURPLE}#       Sing-box (NaiveProxy + Hysteria2) 专业管理脚本      #${PLAIN}"
    else
        echo -e "${PURPLE}#       Sing-box (NaiveProxy + Hysteria2) Pro Manager       #${PLAIN}"
    fi
    echo -e "${PURPLE}#############################################################${PLAIN}"

    get_vps_status

    if [[ "$CURRENT_LANG" == "zh" ]]; then
        if [[ "$cur_v" == "Not Installed" ]]; then
            echo -e " 核心版本: ${YELLOW}未安装${PLAIN} (待安装 NaiveProxy + Hysteria2 | 最新发布: ${GREEN}${CACHED_LAT_V}${PLAIN})"
        else
            echo -e " 核心版本: ${YELLOW}${cur_v}${PLAIN} (内置 NaiveProxy + Hysteria2 协议栈 | 最新发布: ${GREEN}${CACHED_LAT_V}${PLAIN})"
        fi
        echo ""
        echo -e " ${YELLOW}1.${PLAIN} 安装 / 重新安装 (NaiveProxy + Hysteria2 双旗舰协议)"
        echo -e " ${YELLOW}2.${PLAIN} 显示客户端链接、二维码与 Clash YAML 配置"
        echo -e " ${YELLOW}3.${PLAIN} 重启 Sing-box 服务"
        echo -e " ${YELLOW}4.${PLAIN} 查看实时运行日志"
        echo -e " ${YELLOW}5.${PLAIN} 开启 BBR 加速与内核网络优化"
        echo -e " ${YELLOW}6.${PLAIN} 彻底卸载 Sing-box"
        echo -e " ${YELLOW}7.${PLAIN} 修改凭据 (用户名 / 密码)"
        echo -e " ${YELLOW}8.${PLAIN} 配置 Hysteria2 (伪装站 / 端口跳跃 / Brutal限速)"
        echo -e " ${YELLOW}9.${PLAIN} 管理 Cloudflare WARP (官方API解锁流媒体/AI)"
        echo -e " ${YELLOW}10.${PLAIN} 检测流媒体与 AI 解锁状态 (Netflix / Disney+ / OpenAI / YouTube)"
        echo -e " ${YELLOW}11.${PLAIN} 仅更新 Sing-box 核心 (同步升级 NaiveProxy 与 Hysteria2)"
        echo -e " ${YELLOW}12.${PLAIN} 切换语言 / Switch Language (当前: 简体中文)"
        echo -e " ${YELLOW}0.${PLAIN} 退出"
        echo ""
        read -rp "请选择操作 [0-12]: " choice
    else
        if [[ "$cur_v" == "Not Installed" ]]; then
            echo -e " Core Version: ${YELLOW}Not Installed${PLAIN} (NaiveProxy + Hysteria2 | Latest: ${GREEN}${CACHED_LAT_V}${PLAIN})"
        else
            echo -e " Core Version: ${YELLOW}${cur_v}${PLAIN} (Built-in NaiveProxy + Hysteria2 | Latest: ${GREEN}${CACHED_LAT_V}${PLAIN})"
        fi
        echo ""
        echo -e " ${YELLOW}1.${PLAIN} Install / Reinstall (NaiveProxy + Hysteria2 Dual Protocols)"
        echo -e " ${YELLOW}2.${PLAIN} Display Client Links, QR Codes & Clash YAML"
        echo -e " ${YELLOW}3.${PLAIN} Restart Sing-box Service"
        echo -e " ${YELLOW}4.${PLAIN} View Real-time Runtime Logs"
        echo -e " ${YELLOW}5.${PLAIN} Apply BBR & Kernel Network Optimization"
        echo -e " ${YELLOW}6.${PLAIN} Uninstall Sing-box Completely"
        echo -e " ${YELLOW}7.${PLAIN} Modify Credentials (Username / Passwords)"
        echo -e " ${YELLOW}8.${PLAIN} Configure Hysteria2 (Masquerade / Port Hopping / Brutal)"
        echo -e " ${YELLOW}9.${PLAIN} Manage Cloudflare WARP (Official API Stream/AI Unlock)"
        echo -e " ${YELLOW}10.${PLAIN} Check Streaming & AI Unlock Status (Netflix / Disney+ / OpenAI)"
        echo -e " ${YELLOW}11.${PLAIN} Update Sing-box Core Only (Syncs NaiveProxy & Hysteria2)"
        echo -e " ${YELLOW}12.${PLAIN} Switch Language / 切换语言 (Current: English)"
        echo -e " ${YELLOW}0.${PLAIN} Exit"
        echo ""
        read -rp "Select an option [0-12]: " choice
    fi

    choice=$(echo "$choice" | tr -d '\r' | tr -d ' ')
    case "$choice" in
        1) install_full_flow ;;
        2) show_config ;;
        3)
            systemctl restart sing-box
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                echo -e "${GREEN}服务已重启！${PLAIN}"
            else
                echo -e "${GREEN}Service restarted!${PLAIN}"
            fi
            ;;
        4) journalctl -u sing-box -n 30 --no-pager ;;
        5) optimize_system ;;
        6) uninstall_all ;;
        7) modify_credentials ;;
        8) modify_hy2_advanced ;;
        9) setup_warp ;;
        10) check_media_unlock ;;
        11)
            refresh_cache
            if install_singbox "$CACHED_LAT_V"; then
                systemctl restart sing-box
                if [[ "$CURRENT_LANG" == "zh" ]]; then
                    echo -e "${GREEN}Sing-box 核心已更新至 ${CACHED_LAT_V} 并已重启！${PLAIN}"
                else
                    echo -e "${GREEN}Sing-box core updated to ${CACHED_LAT_V} and restarted!${PLAIN}"
                fi
            fi
            ;;
        12)
            switch_language
            return 0
            ;;
        0) exit 0 ;;
        *)
            if [[ "$CURRENT_LANG" == "zh" ]]; then
                echo -e "${RED}无效选项！${PLAIN}"
            else
                echo -e "${RED}Invalid option!${PLAIN}"
            fi
            ;;
    esac

    echo ""
    if [[ "$CURRENT_LANG" == "zh" ]]; then
        read -rp "按回车键返回主菜单..."
    else
        read -rp "Press Enter to return to main menu..."
    fi
}

# ----------------- Entrypoint -----------------
init_lang
detect_env
refresh_cache
while true; do
    show_menu
done
