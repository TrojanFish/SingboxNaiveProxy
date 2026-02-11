# Sing-box Ultimate 自动部署脚本

这是一个用于在 Linux VPS (支持 ARM 和 AMD 架构) 上快速部署 Sing-box 并配置多种顶级代理协议的自动化脚本。

## 核心特点
- **三剑客协议支持**：同时部署 **NaiveProxy**、**Hysteria2** 和 **VLESS-REALITY**。
- **极致性能优化**：自动开启 BBR 并进行深度内核 TCP 调优，降低高延迟环境下的丢包与抖动。
- **智能化预检**：安装前自动检测端口占用 (80/443)，防止安装失败。
- **免域名备方案**：集成 REALITY 协议，无需域名和 SSL 证书即可直连，完美应对证书申请失败的情况。
- **自动化证书**：使用 acme.sh 自动申请并续期 Let's Encrypt SSL 证书。

## 快速安装与管理

在您的 VPS 上运行以下命令：

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/TrojanFish/SingboxNaiveProxy/main/install.sh && chmod +x install.sh && ./install.sh
```

### 菜单选项
1. **安装 / 修复**: 自动化完成内核调优、证书申请及三协议配置。
2. **查看配置**: 显示 NaiveProxy、Hysteria2 及 REALITY 的导入链接。
3. **系统优化**: 独立运行 BBR 与内核专项调优。
4. **卸载**: 清理所有二进制文件及配置文件。

---

## 客户端设置教程

### 1. NaiveProxy (推荐)
- **Shadowrocket**: 类型选 `HTTPS`，填写域名、端口 443 及用户名密码。
- **ALPN**: 手动填写 `h2`。

### 2. VLESS-REALITY (免域名备份)
- **Shadowrocket**: 类型选 `VLESS`。
- **传输方式**: `TCP`。
- **UUID / Flow**: 填写脚本生成的 UUID，流控设为 `xtls-rprx-vision`。
- **TLS**: 开启 `Reality`。
- **SNI**: `dl.google.com` (或脚本中配置的伪装域名)。
- **公钥 (Public Key)**: **务必**填写安装时控制台输出的 Public Key。

### 3. Hysteria2 (抗丢包神器)
- **Shadowrocket**: 直接添加 `Hysteria2` 类型，填写端口与密码即可。

---

## 常见问题排查

1. **域名解析**: 使用 NaiveProxy 时，Cloudflare 的 **代理状态** 必须设置为 **仅限 DNS (灰色云朵)**。
2. **端口开放**: 务必在云服务商后台防火墙开启以下端口：
   - **TCP 443** (NaiveProxy)
   - **UDP 443** (辅助)
   - **UDP [随机端口]** (Hysteria2，见脚本安装输出)
   - **TCP [随机端口]** (REALITY，见脚本安装输出)
3. **REALITY 无法连接**: 检查客户端是否正确填入了 **Public Key** 以及 **Short ID**。

## 维护命令

- **快捷菜单**: 输入 `nb` 即可再次进入脚本管理菜单。
- **实时日志**: `journalctl -u sing-box -f`
- **重启服务**: `systemctl restart sing-box`

## GitHub 仓库
[https://github.com/TrojanFish/SingboxNaiveProxy](https://github.com/TrojanFish/SingboxNaiveProxy)
