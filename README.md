# Sing-box + NaiveProxy 自动部署脚本

这是一个用于在 Linux VPS (支持 ARM 和 AMD 架构) 上快速部署 Sing-box 并配置 NaiveProxy 协议的自动化脚本。

## 特点
- 支持 AMD64 和 ARM64 架构。
- 自动化安装 Sing-box。
- 自动化使用 acme.sh 申请 SSL 证书（Let's Encrypt）。
- 自动配置 Systemd 服务，确保开机自启。
- 生成随机的用户名和密码。

## 快速安装与管理

在您的 VPS 上运行以下命令，即可进入交互式菜单进行安装或卸载：

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/TrojanFish/SingboxNaiveProxy/main/install.sh && chmod +x install.sh && ./install.sh
```

### 菜单选项
1. **安装 Sing-box + NaiveProxy**: 自动化完成所有配置。
2. **一键删除 (卸载)**: 停止服务并清理所有配置文件和二进制文件。
0. **退出**: 退出脚本。

> 注意：请确保您的域名已解析到当前 VPS 的 IP，并且端口 80 和 443 是开放的。

---

## 客户端设置教程

### 1. Shadowrocket (小火箭) 设置

Shadowrocket 原生支持 NaiveProxy (通过 HTTPS 类型)。

1. 打开 Shadowrocket，点击右上角 `+` 号添加节点。
2. **类型 (Type)**: 选择 `HTTPS`。
3. **服务器 (Server)**: 填写您的域名 (例如 `example.com`)。
4. **端口 (Port)**: 填写 `443`。
5. **用户 (User)**: 填写脚本生成的用户名。
6. **密码 (Password)**: 填写脚本生成的密码。
7. **混淆 (Obfuscation)**: 保持默认或确认是否需要开启 (通常 NaiveProxy 默认就是伪装成 HTTPS)。
8. 点击保存，开始使用。

### 2. PassWall (OpenWrt) 设置

PassWall 需要您的固件内置了 `naiveproxy` 或者是最新的 `sing-box` 核心。

1. 进入 PassWall 节点列表，点击 `添加`。
2. **节点类型**: 选择 `NaiveProxy`。
3. **节点别名**: 自定义。
4. **服务器地址**: 填写您的域名。
5. **端口**: `443`。
6. **用户名**: 填写生成的用户名。
7. **密码**: 填写生成的密码。
8. **TLS服务名 (SNI)**: 填写您的域名。
9. 保存并应用。

---

## 常见问题排查 (Troubleshooting)

如果节点显示延迟为 `-1` 或无法连接，请按以下顺序排查：

1. **域名解析 (Cloudflare)**:
   - 检查 Cloudflare 的解析记录。
   - **代理状态** 必须设置为 **仅限 DNS (灰色云朵)**。开启橙色小黄云会导致 NaiveProxy 协议被拦截。

2. **云平台防火墙 (甲骨文/GCP)**:
   - 确保在云服务商后台的安全组中开放了以下端口：
     - **TCP 443** (NaiveProxy)
     - **UDP 12068** (Hysteria2)
     - **UDP 443** (辅助)

3. **客户端设置 (最常见错误)**:
   - **协议类型**: 必须选择 `HTTPS`。
   - **伪装域名 (Host/SNI)**: **请务必留空**，或填写你自己的域名。千万不要填写 `bing.com` 或 `google.com`，这会导致 TLS 证书不匹配报错。
   - **ALPN**: 手动填写 `h2`。

4. **服务器日志**:
   - 运行命令查看实时日志：`journalctl -u sing-box -f`
   - 如果看到 `not CONNECT request`，通常是客户端协议填错或开启了 `bing.com` 伪装。

## 伪装建议 (Masquerading Tips)

- **推荐二级域名**: `api.yourdomain.com`, `cdn.yourdomain.com`, `update.yourdomain.com` 具有更好的迷惑性。
- **关于伪装**: NaiveProxy 对伪装非常敏感。如果不确定，**保持默认不配置伪装域名** 是最稳妥的选择，它会自动表现为一个正常的 HTTPS 错误页面。

## 维护命令

- **查看日志**: `journalctl -u sing-box -f`
- **重启服务**: `systemctl restart sing-box`
- **查看状态**: `systemctl status sing-box`

## GitHub 仓库
[https://github.com/TrojanFish/SingboxNaiveProxy](https://github.com/TrojanFish/SingboxNaiveProxy)

## 贡献
欢迎提交 Issue 或 Pull Request 来完善此项目。
