# Sing-box + NaiveProxy 自动部署脚本

这是一个用于在 Linux VPS (支持 ARM 和 AMD 架构) 上快速部署 Sing-box 并配置 NaiveProxy 协议的自动化脚本。

## 特点
- 支持 AMD64 和 ARM64 架构。
- 自动化安装 Sing-box。
- 自动化使用 acme.sh 申请 SSL 证书（Let's Encrypt）。
- 自动配置 Systemd 服务，确保开机自启。
- 生成随机的用户名和密码。

## 快速安装

在您的 VPS 上运行以下命令：

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/TrojanFish/SingboxNaiveProxy/main/install.sh && chmod +x install.sh && ./install.sh
```

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

## 维护命令

- **查看日志**: `journalctl -u sing-box -f`
- **重启服务**: `systemctl restart sing-box`
- **停止服务**: `systemctl stop sing-box`
- **查看状态**: `systemctl status sing-box`

## GitHub 仓库
[https://github.com/TrojanFish/SingboxNaiveProxy](https://github.com/TrojanFish/SingboxNaiveProxy)

## 贡献
欢迎提交 Issue 或 Pull Request 来完善此项目。
