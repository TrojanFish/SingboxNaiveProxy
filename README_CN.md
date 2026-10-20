<div align="center">

# Sing-box (NaiveProxy + Hysteria2 + WARP) 一键部署脚本

**[English](README.md) | [中文说明](README_CN.md)**

</div>

适用于 Linux VPS（支持 AMD64 / ARM64 / ARMv7 架构）的现代化企业级代理自动化部署脚本。基于 [Sing-box](https://github.com/SagerNet/sing-box) 核心，深度集成 **NaiveProxy**、**Hysteria2** 协议以及 **Cloudflare WARP** 原生流媒体与 AI 解锁。

---

## 🚀 核心特性

- **双旗舰协议组合**：
  - **NaiveProxy** (TCP/UDP 443)：直接调用 Chromium 官方网络栈，流量特征与标准 Chrome 浏览器完全一致，具备极强的抗封锁、主动探测免疫与统计分析抵御能力。
  - **Hysteria2** (UDP 独立端口)：基于 QUIC 协议与定制拥塞控制算法开发，恶劣网络与高丢包环境下丢包不降速，暴力跑满 VPS 带宽。
- **智能出站分流 (Cloudflare WARP 优选 & IPv4/IPv6 偏好切换)**：
  - 本地生成 WireGuard 密钥对并通过 Cloudflare 官方 API 注册，默认采用优选 Anycast 节点（`162.159.192.1:2408`），突破传统默认域名遭阻断的痛点。
  - **支持出站出口偏好切换**：可一键自由切换为 **IPv6 优先（极力推荐，信誉极高零验证码）**、**IPv4 优先** 或 **双栈自适应**。
  - **全套 AI 与流媒体分流矩阵**：自动将 OpenAI、ChatGPT、Sora、Claude、Perplexity、HuggingFace 以及 Netflix、Disney+、Spotify、Max 等服务精准分流至 WARP，彻底解除区域封锁。
- **UDP 端口跳跃 (Port Hopping)**：
  - 支持自定义端口范围（如 `20000-50000`）透明重定向转发，击碎单端口高吞吐特征，有效规避运营商 QoS 限速或阻断。
- **极客级网络调优与环境自适应**：
  - 自动启用 BBR 拥塞控制与 FQ 队列规则，深度调优 64MB 系统级 UDP/QUIC 读写缓冲区。
  - **智能虚拟化识别**：内置 `systemd-detect-virt` 预检，在 KVM/Xen 宿主机应用内核调优，在 LXC/OpenVZ/Docker 等容器环境中优雅跳过，杜绝系统级报错。
- **严格的安全工程设计**：
  - **权限最小化隔离**：创建专用系统级 `sing-box` 无特权用户，通过 Linux Capabilities（`CAP_NET_BIND_SERVICE` / `CAP_NET_ADMIN` / `CAP_NET_RAW`）保持低位 443 端口绑定能力，**告别 root 裸奔运行**。
  - **DNS 预检与 IPv6 陷阱防护**：证书申请前通过 DoH 自动校验域名解析；若检测到域名配置了 AAAA (IPv6) 解析但服务器无公网 IPv6，主动报警拦截，防止 Let's Encrypt 优先验证 IPv6 导致证书申请暴毙及频控受限。
  - **双栈防火墙闭环**：同步配置 IPv4 (`iptables`) 与 IPv6 (`ip6tables`) 放行规则，全自动适配 Debian/Ubuntu (`iptables-persistent`) 及 RHEL/CentOS (`iptables-services`) 开机持久化；卸载时**全自动回滚清理所有规则，零系统残留**。
  - **无限速版本抓取**：采用 HTTP 重定向追踪最新 Release Tag，完全不消耗 GitHub API 配额，根治 403 限速回退老旧版本的问题。

---

## 📥 快速安装

在您的 VPS 上（需 root 权限）执行以下命令即可启动交互式部署：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/TrojanFish/SingboxNaiveProxy/main/install.sh)
```

备用安装命令（若无 curl）：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/TrojanFish/SingboxNaiveProxy/main/install.sh)
```

---

## 📖 极简安装步骤（用户视角）

只需准备好一个解析到 VPS 的域名，安装过程只需 **3 步交互**：

```text
[准备] 将域名通过 DNS 解析到 VPS 公网 IP (Cloudflare 保持“灰色云朵”)
  ↓
[步骤 1] 在 VPS 终端粘贴运行上述一键安装命令
  ↓
[步骤 2] 在弹出的主管理菜单中输入「1」并回车
  ↓
[步骤 3] 提示「Enter your domain name:」时，输入你的域名并回车
  ↓
[完成] 脚本全自动完成全部编译配置，屏幕直接打印节点链接、二维码与 Clash 配置！
```

---

## ⚙️ 一键安装底层自动化流程（系统内部流转）

当你在菜单选择 `1` 后，脚本内部会自动串联执行以下 9 个阶段：

1. **环境与依赖安装**：自动检测系统架构（AMD64/ARM64）与包管理器，静默安装 `curl`、`jq`、`socat`、`qrencode`、`cron` 等基础依赖。
2. **端口冲突排查**：主动检测 80 与 443 端口是否被占用，若被占用会友好提示用户确认是否清理，防止安装半途失败。
3. **内核参数调优**：检测底层虚拟化环境，若为 KVM 物理架构则自动开启 BBR 拥塞控制并放开 64MB 系统缓冲区；若为容器则优雅跳过。
4. **核心二进制拉取**：无限速追踪 GitHub 最新稳定 Release，下载官方核心包并通过严格的 SHA256 完整性校验，解压部署。
5. **DNS 预检与 SSL 证书申请**：通过 DoH 预检域名解析状态，防范 IPv6 陷阱；使用 `acme.sh` 自动向 Let's Encrypt 签发 ECC-256 强加密证书。
6. **自适应配置文件生成**：自动生成高强度随机密码与 Hysteria2 独立端口，使用 `jq` 精准构建包含 NaiveProxy 与 Hysteria2 的 `config.json`，权限锁定为 `600`。
7. **全栈双协议防火墙放行**：同步放行 UFW / Firewalld / iptables / ip6tables 的 80、443、Hy2 端口，并设置开机自动持久化生效。
8. **安全隔离与服务拉起**：自动创建专用的系统无特权用户 `sing-box`，分配 Linux Capabilities 绑定低位 443 端口；通过 `sing-box check` 校验配置无误后启动服务并设置开机自启。
9. **自动注册快捷命令与输出结果**：自动将脚本自身部署为全局命令 `nb`；清屏输出节点 Universal 导入链接、Clash Meta YAML 配置及 Shadowrocket 终端二维码。

---

## 🛠️ 管理菜单功能

安装完成后，在终端任意位置输入快捷命令即可随时唤出管理面板（已全面适配管道安装，杜绝空文件假死）：

```bash
nb
```

菜单功能选项一览：

| 选项 | 功能 | 描述 |
| :---: | :--- | :--- |
| **1** | 安装 / 重新安装 | 自动化完成依赖安装、端口检查、内核调优、核心校验、SSL 申请与配置构建 |
| **2** | 查看节点配置与链接 | 输出 Universal 导入链接、二维码及 Clash Meta (Mihomo) YAML 节点配置 |
| **3** | 重启服务 | 快速平滑重启 Sing-box 系统守护进程 |
| **4** | 查看实时日志 | 实时查看 Sing-box 核心最新输出日志（30 行） |
| **5** | 应用内核与 BBR 优化 | 独立配置 BBR 及 UDP 缓冲区系统参数（支持容器环境自适应） |
| **6** | 彻底卸载 | 停止并移除服务、二进制文件、自动回滚清理防火墙规则并可选清理证书 |
| **7** | 修改节点凭证 | 快速修改 NaiveProxy 用户名/密码及 Hysteria2 连接密码 |
| **8** | 配置 Hysteria2 高级项 | 自定义 HTTP 伪装站点、配置 UDP 端口跳跃范围及 Brutal 速率上限 |
| **9** | 管理 Cloudflare WARP | 官方 API 注册、切换出口 IP 偏好 (IPv6/IPv4/双栈自适应)、移除 WARP |
| **10** | 仅升级 Sing-box 核心 | 自动拉取最新 Release 核心二进制并执行 SHA256 校验更新 |
| **0** | 退出管理脚本 | 退出交互菜单 |

---

## 📱 客户端配置与使用

运行菜单选项 **`2`** 可以随时查看完整的节点信息、分享链接、二维码以及 Clash Meta 节点代码。

### 1. NaiveProxy
- **通用客户端**：支持 [v2rayN](https://github.com/2dust/v2rayN)、[NekoBox](https://github.com/MatsuriDayo/nekoray)、[Sing-box](https://github.com/SagerNet/sing-box) 等。直接导入脚本输出的 `https://...` 链接即可。
- **Shadowrocket (小火箭)**：
  - 类型：`HTTPS`
  - 服务器：您的域名
  - 端口：`443`
  - 用户名/密码：根据安装输出或选项 7 查看
  - ALPN：`h2`

### 2. Hysteria2
- **通用链接**：使用 `hysteria2://` 标准 URI 格式，支持大部分现代客户端一键导入。
- **Clash Meta (Mihomo)**：脚本提供了开箱即用的 YAML 节点代码块，复制到代理配置文件即可使用。
- **端口跳跃使用**：若开启了 UDP 端口跳跃（例如 `20000-50000`），在客户端端口设置处填写对应跳跃范围（Clash Meta 填入 `ports: 20000-50000`），即可自动轮换规避运营商 QoS。

---

## ❓ 常见问题与排查指南

1. **域名解析与 Cloudflare 设置**：
   - 使用 NaiveProxy 必须拥有一个解析至 VPS 的域名。
   - 若使用 Cloudflare 解析域名，**代理状态必须设置为“仅限 DNS”（灰色云朵）**，切勿开启 CDN 代理（橙色云朵）。
   - **IPv6 提示**：若服务器没有分配独立的公网 IPv6，请不要在 DNS 处添加 AAAA 记录，否则 Let's Encrypt 优先验证 IPv6 会导致申请失败。
2. **云服务商后台安全组 / 防火墙开放端口**：
   - **TCP 80**：Let's Encrypt 证书初次申请与验证。
   - **TCP 443** & **UDP 443**：NaiveProxy 与 HTTPS/QUIC 流量。
   - **UDP [自定义端口]**：Hysteria2 监听端口（默认随机生成，可自定义）。
   - **UDP [跳跃端口范围]**：若开启了端口跳跃（如 `20000:50000`），务必在云后台开放此范围的 UDP 规则。
3. **查看完整服务日志**：
   ```bash
   journalctl -u sing-box -f -o cat
   ```
4. **服务运行状态自检**：
   ```bash
   systemctl status sing-box
   ```

---

## 📜 维护与开源

- **GitHub 仓库**：[https://github.com/TrojanFish/SingboxNaiveProxy](https://github.com/TrojanFish/SingboxNaiveProxy)
- **协议官方文档**：[Sing-box Documentation](https://sing-box.sagernet.org/)
