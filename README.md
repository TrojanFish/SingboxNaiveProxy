<div align="center">

# Sing-box (NaiveProxy + Hysteria2 + WARP) Ultimate Manager

**[English](README.md) | [中文说明](README_CN.md)**

</div>

An enterprise-grade, fully automated deployment and management script for Linux VPS (supporting AMD64 / ARM64 / ARMv7 architectures). Built on the modern [Sing-box](https://github.com/SagerNet/sing-box) core, seamlessly integrating **NaiveProxy**, **Hysteria2**, and **Cloudflare WARP** outbound routing for unblocking AI and streaming services.

---

## 🚀 Key Features

- **Dual Flagship Protocols**:
  - **NaiveProxy** (TCP/UDP 443): Directly embeds Chromium's official network stack. Traffic signatures are 100% identical to regular Google Chrome browsing, providing unparalleled resistance to active probing, heuristic analysis, and DPI censorship.
  - **Hysteria2** (UDP independent port): Built upon the QUIC protocol with a custom congestion control algorithm (Brutal). Retains maximum throughput without packet-loss-induced speed drops, maximizing bandwidth on lossy, high-latency cross-border networks.
- **Smart Outbound Routing (Cloudflare Anycast WARP & IP Preference)**:
  - WireGuard keypairs are generated locally and registered via Cloudflare's official API, connecting directly to optimized Anycast endpoints (`162.159.192.1:2408`) to bypass DNS-based endpoint throttling.
  - **Switchable Outbound IP Preference**: Seamlessly toggle between **IPv6 Preferred (Cleanest IP, zero captchas on OpenAI/Claude)**, **IPv4 Preferred**, or **Auto (Dual-stack)**.
  - **Comprehensive AI & Streaming Matrix**: Automatically routes OpenAI, ChatGPT, Sora, Claude, Perplexity, HuggingFace, Netflix, Disney+, Spotify, Max, and more through WARP to circumvent geo-restrictions.
- **UDP Port Hopping**:
  - Supports configurable port ranges (e.g., `20000-50000/udp`) with transparent kernel redirection, breaking single-port high-traffic behavioral patterns and effectively mitigating ISP QoS rate-limiting.
- **Geek-Level Kernel Tuning & Virtualization Awareness**:
  - Automatically enables native BBR congestion control and FQ queuing disciplines, expanding system UDP/QUIC buffers to 64MB for extreme concurrency.
  - **Smart Virtualization Detection**: Built-in `systemd-detect-virt` pre-check applies deep kernel parameters on bare-metal KVM/Xen servers while gracefully skipping tuning on LXC/OpenVZ/Docker containers to prevent system errors.
- **Rigorous Security Engineering**:
  - **Privilege Minimization**: Runs the Sing-box daemon under a dedicated, unprivileged `sing-box` system user with isolated Linux Capabilities (`CAP_NET_BIND_SERVICE`, `CAP_NET_ADMIN`, `CAP_NET_RAW`), eliminating root privilege escalation risks.
  - **DNS & IPv6 Trap Pre-check**: Uses DoH (DNS over HTTPS) to pre-validate domain resolution prior to certificate issuance; flags AAAA (IPv6) traps when the host lacks public IPv6 to prevent Let's Encrypt validation timeouts and rate limits.
  - **Full Dual-Stack Firewall Automation**: Synchronously configures IPv4 (`iptables`) and IPv6 (`ip6tables`) rules with persistent reboot retention across Debian/Ubuntu (`iptables-persistent`) and RHEL/CentOS (`iptables-services`); **guarantees 100% clean rule rollback upon uninstallation**.
  - **Rate-Limit-Free Core Updates**: Tracks the latest official release via HTTP redirect headers without consuming GitHub API quotas, eliminating `403 Rate Limit` update failures.

---

## 📥 Quick Installation

Run the following command on your VPS (root privileges required):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/TrojanFish/SingboxNaiveProxy/main/install.sh)
```

Alternative command (if `curl` is not installed):
```bash
bash <(wget -qO- https://raw.githubusercontent.com/TrojanFish/SingboxNaiveProxy/main/install.sh)
```

---

## 📖 Simple 3-Step Setup (User Workflow)

All you need is a domain name resolved to your VPS public IP. The interactive installation requires only **3 simple steps**:

```text
[Preparation] Point your domain/subdomain (A record) to the VPS public IP
              (In Cloudflare DNS, ensure proxy status is set to "DNS only / Gray cloud").
  ↓
[Step 1] Paste and run the one-liner command in your VPS terminal.
  ↓
[Step 2] Enter "1" in the interactive menu and press Enter.
  ↓
[Step 3] When prompted "Enter your domain name:", enter your domain and press Enter.
  ↓
[Done] The script automatically handles all dependencies, certificates, and compilation!
       Import URLs, terminal QR codes, and Clash Meta YAML configurations will be displayed.
```

---

## ⚙️ Automated Internal Architecture (Under the Hood)

Selecting `1` in the menu automatically executes the following 9-stage sequence:

1. **Environment & Dependency Provisioning**: Detects OS architecture and package manager; installs required tools (`curl`, `jq`, `socat`, `qrencode`, `cron`, etc.) silently.
2. **Port Conflict Pre-flight**: Inspects ports 80 and 443; prompts to terminate conflicting processes (e.g., stale Nginx/Apache) to prevent mid-install failures.
3. **Kernel & Network Optimization**: Inspects virtualization; applies BBR and 64MB buffers on KVM nodes or skips safely on containerized systems.
4. **Binary Retrieval & SHA256 Verification**: Fetches the latest stable release without API rate-limiting; performs strict SHA256 checksum validation before extraction.
5. **DNS Pre-check & SSL Automation**: Verifies DNS resolution via DoH; requests an ECC-256 certificate from Let's Encrypt using `acme.sh` in standalone mode.
6. **Dynamic Configuration Assembly**: Generates cryptographically random credentials, random high-range UDP ports, and masquerade sites; compiles `config.json` via `jq` and locks permissions to `600`.
7. **Dual-Stack Firewall Deployment**: Configures UFW / Firewalld / iptables / ip6tables for ports 80, 443, and Hysteria2 UDP; saves rules for reboot persistence.
8. **Privilege Isolation & Service Startup**: Creates a dedicated `sing-box` system user; assigns capabilities; validates config syntax via `sing-box check`; enables and starts the systemd service.
9. **Global Shortcut Deployment & Summary**: Installs the script as the global command `nb`; clears the screen to display client links, terminal QR codes, and Clash configurations.

---

## 🛠️ Management Panel (`nb`)

Once installed, type the following shortcut anywhere in your terminal to open the management panel:

```bash
nb
```

### Menu Options Overview

| Option | Function | Description |
| :---: | :--- | :--- |
| **1** | Install / Reinstall | Full automated installation of NaiveProxy, Hysteria2, port 80 enforcement, SSL, and system tuning |
| **2** | Display Configurations | Displays Universal import URIs, terminal QR codes, and Clash Meta (Mihomo) YAML blocks |
| **3** | Restart Service | Smoothly restarts the Sing-box systemd daemon |
| **4** | View Live Logs | Streams recent runtime logs (`30 lines`) directly from journalctl |
| **5** | Apply BBR & Kernel Tuning | Standalone kernel parameter and buffer optimization (with container auto-detection) |
| **6** | Complete Uninstallation | Stops service, deletes binaries/configs, removes user, and **cleanly rolls back firewall rules** |
| **7** | Modify Credentials | Update NaiveProxy username/password and Hysteria2 connection password |
| **8** | Configure Hysteria2 Advanced | Change HTTP masquerade site, configure UDP port hopping ranges, and set Brutal bandwidth limits |
| **9** | Manage Cloudflare WARP | Register official API account, toggle outbound IP preference (IPv6/IPv4/Auto), or remove WARP |
| **10** | Check Streaming & AI Unlock | Dual-route verification (Direct vs. WARP) for Netflix, Disney+, YouTube, OpenAI, and Claude |
| **11** | Update Sing-box Core Only | Fetch and verify latest Sing-box core (syncs built-in NaiveProxy & Hysteria2 stacks) |
| **12** | Switch Language | Toggle interface language between English and Simplified Chinese (persisted) |
| **0** | Exit | Exit the management script |

---

## 📱 Client Setup & Configuration

Run menu option **`2`** at any time to retrieve node links, QR codes, and Clash Meta snippets.

### 1. NaiveProxy
- **Universal Clients**: [v2rayN](https://github.com/2dust/v2rayN), [NekoBox](https://github.com/MatsuriDayo/nekoray), [Sing-box](https://github.com/SagerNet/sing-box). Import the `https://...` link directly.
- **Shadowrocket**:
  - Type: `HTTPS`
  - Server: Your domain
  - Port: `443`
  - User / Password: As generated or viewed via Option 7
  - ALPN: `h2`

### 2. Hysteria2
- **Universal URI**: Use the standard `hysteria2://` URI format supported by most modern proxy clients.
- **Clash Meta (Mihomo)**: Copy the YAML node block output by the script into your proxy configuration file.
- **Port Hopping**: If UDP port hopping is enabled (e.g., `20000-50000`), specify the port range in your client (in Clash Meta, use `ports: 20000-50000`) to mitigate ISP QoS throttling.

---

## ❓ Troubleshooting & FAQ

1. **Domain & Cloudflare Settings**:
   - A valid domain pointing to your VPS is required for NaiveProxy.
   - In Cloudflare, **Proxy status must be set to "DNS only" (Gray Cloud)**. Do NOT enable Cloudflare proxy (Orange Cloud).
   - **IPv6 Caution**: If your VPS does not have an active public IPv6 address, do NOT configure an AAAA record in DNS; Let's Encrypt prioritizes IPv6 and will fail.
2. **Cloud Firewall & Security Groups**:
   - **TCP 80**: Let's Encrypt initial validation.
   - **TCP 443 & UDP 443**: NaiveProxy and HTTPS/QUIC traffic.
   - **UDP [Custom Port]**: Hysteria2 listening port (randomly generated by default).
   - **UDP [Hopping Range]**: If port hopping is enabled (e.g., `20000:50000`), open this UDP port range in your cloud provider's firewall console.
3. **Live Logs Inspection**:
   ```bash
   journalctl -u sing-box -f -o cat
   ```
4. **Service Health Check**:
   ```bash
   systemctl status sing-box
   ```

---

## 📜 Maintenance & Credits

- **GitHub Repository**: [https://github.com/TrojanFish/SingboxNaiveProxy](https://github.com/TrojanFish/SingboxNaiveProxy)
- **Official Documentation**: [Sing-box Official Docs](https://sing-box.sagernet.org/)
