# lan-transparent-proxy

一套**通用、可自愈、拿来即用**的局域网透明代理部署方案。把任意一台常开的 Linux 网关设备（OpenWrt / iStoreOS 软路由、小主机、NAS、Debian 服务器）变成整网代理出口。

不绑定任何特定品牌、IP 段或端口：接口、网段、网关、端口、路由表、隧道参数全部由 `etc/proxy.env` 驱动，自动探测生成，随时可改。

**其它 AI 平台 / 编码助手**：直接读取 [`AGENTS.md`](AGENTS.md)，里面给出了与平台无关的完整部署、验收、排障指令。

## 特性

- **自适应局域网**：自动探测 LAN 接口、网段、网关、Docker 网段、上行口；支持多接口、多网段。
- **端口全可配置**：mixed / redir / tproxy / DNS / API 五个端口独立配置，部署时自动检测冲突并顺延。
- **活动路由**：策略路由幂等维护，守护进程持续自愈；LAN 接口、网段、排除集变化后自动重新渲染并原子重载规则。
- **安全闸**：代理未就绪时拒绝下发透明规则；远程部署自动放过自己的 SSH 源 IP，防止把自己锁在门外。
- **原子下发 / 原子回滚**：nftables 用独立 table 原子加载，iptables 用自定义链 + `iptables-restore -n` 原子加载；失败即整体回滚。
- **两种上游**：Cloudflare WARP（免费，内核 WireGuard + 策略路由）或任意 mihomo 支持的自定义节点。
- **隔离验收**：在设备内部用容器模拟客户端，不碰管理电脑的路由。
- **开机自启**：自动识别 OpenWrt procd 与 systemd。

## 架构

```
 局域网设备 ──网关/DNS──> 网关设备
                              │
                 nftables / iptables
              DNS 劫持 → 排除 → TCP REDIRECT
                        mangle → UDP TPROXY
                              │
                        mihomo 容器
                     分流 / fake-ip DNS
                              │
              ┌───────────────┴───────────────┐
              │                               │
       WARP 模式（默认）                 custom 模式
  内核 WireGuard + 策略路由              自定义节点直出
  fwmark → 表 → warp0                   任意 mihomo 节点
```

## 网络拓扑适配

支持三种常见部署形态，`detect.sh` 会自动识别并写入 `LP_TOPOLOGY`：

| 拓扑 | 典型设备 | 关键点 |
|------|----------|--------|
| **旁路由 bypass** | NAS / 小主机，客户端网关手动指向它 | 自动开启 SNAT，避免非对称路由；网关 IP 自动排除，不影响访问主路由管理页 |
| **双口主路由 main** | OpenWrt 软路由，WAN + br-lan | 只在 LAN 口下发规则，WAN 侧不受影响；保留客户端真实源 IP |
| **单臂路由 onearm** | 单网卡 + VLAN trunk（eth0.1 LAN / eth0.2 WAN） | 必须用 VLAN 子接口名，父接口不配 IP；交换机 VLAN 需对应 |

三种拓扑的详细配置、坑与验证方法见 `references/topologies.md`。判定不准可手工设置 `LP_TOPOLOGY=bypass|main|onearm` 与 `LP_MASQUERADE=auto|1|0`。

## 快速开始

在**目标网关设备**上执行（不是在你的电脑上）：

```sh
# 0. 准备目录
mkdir -p /opt/lan-proxy
cd /opt/lan-proxy
# 把本仓库的 scripts/ 和 assets/ 复制过来

# 1. 探测网络并生成配置
sh scripts/detect.sh

# 2. 编辑配置（核对 LP_INTERFACE / LP_LAN_CIDRS / LP_PROXY_IP / LP_GATEWAY）
vi /opt/lan-proxy/etc/proxy.env

# 3. 准备上游（二选一）
sh scripts/warp-keygen.sh          # WARP：导入 warp.conf 或用 wgcf 生成
# 或：编辑 etc/custom-proxies.yaml，设 LP_MODE=custom

# 4. 启动
sh scripts/up.sh

# 5. 验收（不碰管理电脑的路由）
sh scripts/verify.sh

# 6. 稳定后安装开机自启
sh scripts/install-init.sh
```

启动成功后会打印：

```
显式代理 : http://<代理机IP>:7890  /  socks5h://<代理机IP>:7890
透明代理 : 客户端网关 + DNS 指向 <代理机IP>
面板     : http://<代理机IP>:9090
```

客户端二选一即可：

- 浏览器/App 设置代理为上面的地址；
- 或把设备的网关与 DNS 改成代理主机地址（真正的透明代理，无需逐台配置）。

## 前置依赖

| 依赖 | 用途 | 安装提示 |
|------|------|----------|
| Linux root | 改路由与防火墙 | — |
| Docker | 运行 mihomo | OpenWrt: `opkg install dockerd luci-app-dockerman`；Debian: 官方安装脚本 |
| nftables（优先）或 iptables | 透明代理规则 | OpenWrt 22.03+ 自带 nft |
| iproute2 | `ip rule` / `ip route` | — |
| wireguard-tools + 内核模块（仅 WARP 模式） | 内核隧道 | OpenWrt: `opkg install wireguard-tools kmod-wireguard` |
| curl、wget | 健康检查与验收 | busybox 自带 wget |
| country.mmdb / geosite.dat（可选） | GEOIP 智能分流 | 放到 `etc/`，缺失时降级为「仅私网直连」 |

mihomo 镜像默认 `metacubex/mihomo:latest`，可通过 `LP_IMAGE` 换成自己的镜像。

## 目录结构

```
lan-transparent-proxy/
├── SKILL.md                     # WorkBuddy 使用说明
├── AGENTS.md                    # 其它 AI 平台/编码助手的通用指令
├── README.md                    # 本文档
├── assets/
│   ├── mihomo.yaml.tmpl         # mihomo 配置模板
│   ├── warp-proxy.yaml.tmpl     # WARP 节点模板
│   └── custom-proxies.yaml.example
├── references/
│   ├── configuration.md         # 全部参数说明
│   ├── topologies.md            # 旁路由/双口主路由/单臂路由
│   ├── platform-matrix.md       # 平台差异
│   ├── networking.md            # 原理与规则顺序
│   └── troubleshooting.md       # 排障与踩坑
└── scripts/
    ├── lib.sh                   # 公共库
    ├── detect.sh                # 环境探测
    ├── render.sh                # 配置渲染
    ├── warp-keygen.sh           # WARP 身份导入
    ├── up.sh / down.sh          # 启动 / 回退
    ├── fw.sh                    # 防火墙规则
    ├── guard.sh                 # 守护自愈
    ├── status.sh                # 状态
    ├── verify.sh                # 隔离验收
    └── install-init.sh          # 开机自启
```

## 常用运维

```sh
sh scripts/status.sh            # 状态总览
sh scripts/fw.sh status         # 看透明规则
sh scripts/fw.sh counters       # 看规则命中计数
sh scripts/guard.sh status      # 看隧道/出口/容器
sh scripts/fw.sh reload         # 只重载防火墙规则
sh scripts/up.sh                # 改配置后重启整套
sh scripts/down.sh              # 一键回退到普通网络
docker logs -f lan-proxy        # 看 mihomo 日志
```

## 安全说明

- **不要在你的管理电脑上做全量路由劫持来测试**，那会劫持你自己所有流量并可能导致断连。验收脚本已经把测试隔离在设备内部。
- 隧道/节点故障时会**自动恢复**；但如果上游长时间不可用，代理出口会失效——`down.sh` 是随时可用的回退开关。
- 远程 SSH 部署时，脚本会把 SSH 客户端源 IP 自动加入排除列表。手工修改 `LP_EXCLUDE_IPS` 时请勿删掉它。
- 目标是内网 localhost/回环地址的流量**不应该**走代理（手机 App 常见坑）：私网与回环已在默认排除列表中；如仍有问题，在客户端侧补充 `127.0.0.0/8` 与本地网段绕过。
- 面板默认监听 `0.0.0.0`，请修改 `LP_API_SECRET`，并避免把管理端口暴露到公网。

## License

MIT
