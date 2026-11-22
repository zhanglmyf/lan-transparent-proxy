---
name: lan-transparent-proxy
description: 在 OpenWrt/iStoreOS/软路由/Debian 等网关设备上部署可自愈的局域网透明代理（mihomo + 内核 WireGuard/WARP 或自定义节点）。自动探测不同局域网的接口、网段、网关与端口，全参数可配置，活动路由随 LAN 变化自动重载，防火墙规则原子下发并带安全闸，提供完全隔离的端到端验收。This skill should be used when the user asks to set up, deploy, migrate, repair, audit, or explain a LAN-wide transparent proxy, gateway proxy, WARP gateway, or mihomo transparent proxy on a router/NAS.
agent_created: true
---

# 局域网透明代理（通用版）

## 用途

把一台常开的网关设备（OpenWrt/iStoreOS 软路由、小主机、NAS、Debian 服务器）变成整网可用的代理出口。提供两种使用方式：

- **显式代理**：客户端填写 `http://<网关IP>:<mixed-port>` 或 `socks5h://...`
- **透明代理**：客户端网关与 DNS 指向该设备，无需在客户端配置

上游默认 Cloudflare WARP（免费），也可切换为任意 mihomo 支持的自定义节点。所有接口、网段、端口、路由表、隧道参数均来自配置文件，脚本本身不含设备特定硬编码。

**平台边界（先判断再动手）**：本方案跑在**能 root 的 Linux 网关**上——OpenWrt/iStoreOS、x86/ARM Linux（Debian/Ubuntu）为完整支持；群晖等 NAS 降级为显式代理。**普通家用路由器原厂固件与 Windows 不支持**（无 root / 无 Docker / 无内核 WireGuard / 非 POSIX 环境），它们只能当被服务的客户端，或改用「旁路由 + 一台 Linux 设备」的混合部署。完整判据见 `references/platform-matrix.md` 第 0 节。

## 何时使用

- 用户要求「整网代理 / 旁路由 / 透明代理 / 网关代理 / WARP 网关」
- 需要把某台现有代理设备迁移到新局域网（网段、接口、端口全变了）
- 代理「看着正常但实际走直连」、规则重载后断网、隧道握手不稳等故障排查
- 需要审查透明代理方案的架构与安全性

## 标准工作流

按顺序执行，每一步的产物都是下一步的输入：

1. **确认环境**：读取 `references/platform-matrix.md`，确认设备系统、内核是否支持 WireGuard、是否有 nftables 或 iptables、是否已装 Docker。不要在本机 Windows/Mac 上做全量路由劫持来测试。
2. **探测并生成配置**：把 `scripts/` 与 `assets/` 复制到目标设备的 `$LP_BASE`（默认 `/opt/lan-proxy`），执行 `sh scripts/detect.sh`。非交互场景用 `sh scripts/detect.sh --yes`。
3. **确认关键参数与拓扑**：打开生成的 `$LP_BASE/etc/proxy.env`，核对 `LP_INTERFACE`、`LP_LAN_CIDRS`、`LP_PROXY_IP`、`LP_GATEWAY` 与五个端口。读取 `references/topologies.md`，确认 `LP_TOPOLOGY` 判定正确：旁路由（`bypass`）必须开 SNAT，双口主路由（`main`）与单臂路由（`onearm`）通常不开。`LP_PROXY_IP` 必须是客户端能访问到的地址。
4. **准备上游**：
   - WARP 模式：执行 `sh scripts/warp-keygen.sh`，从 `warp.conf` 导入身份（或用 `wgcf` 生成）。
   - 自定义模式：编辑 `$LP_BASE/etc/custom-proxies.yaml`，设置 `LP_MODE=custom` 与 `LP_CUSTOM_PROXY_NAMES`。
   - 可选：把 `country.mmdb` 与 `geosite.dat` 放到 `$LP_BASE/etc/` 启用 GEOIP 分流；缺失时能降级运行，但分流效果变差。
5. **启动**：执行 `sh scripts/up.sh`，它会自动渲染配置、建隧道、起容器、配策略路由、下发透明规则。
6. **验收**：执行 `sh scripts/verify.sh`。该脚本在设备内部用容器模拟客户端，**不修改管理电脑的路由**。确认 DNS 劫持、境外走代理、国内直连、计数器命中。
7. **开机自启**：确认运行稳定后执行 `sh scripts/install-init.sh`，按提示启用服务。
8. **交付**：向用户说明显式代理地址、透明代理设置方式、面板地址、常用运维命令与回退方式（`down.sh` 一键撤销）。

## 脚本索引

| 脚本 | 作用 |
|------|------|
| `lib.sh` | 公共库：配置加载、探测、排除集、幂等路由、隧道健康判定 |
| `detect.sh` | 探测 LAN 接口/网段/网关/端口占用，生成 `proxy.env` |
| `render.sh` | 把 `proxy.env` 渲染为 `mihomo.yaml` 与 `fw.nft` |
| `warp-keygen.sh` | 导入或生成 WARP WireGuard 身份 |
| `up.sh` / `down.sh` | 一键启动 / 一键回退（down 会先撤规则再停服务） |
| `fw.sh` | nftables / iptables 双后端规则，原子下发与回滚 |
| `guard.sh` | 守护：路由自愈、端点轮换、容器拉起、LAN 变化重载 |
| `status.sh` | 状态总览 |
| `verify.sh` | 隔离环境下的端到端验收 |
| `install-init.sh` | 生成 OpenWrt procd 或 systemd 开机自启 |

详细参数见 `references/configuration.md`；三种拓扑（旁路由/双口主路由/单臂路由）见 `references/topologies.md`；规则顺序与原理见 `references/networking.md`；异常处理见 `references/troubleshooting.md`。

## 不可违反的铁律

1. **先撤规则再停代理**：`down.sh` 的顺序不能改，否则整网 TCP 会被重定向到已关闭的端口。
2. **安全闸**：代理端口未监听时，`fw.sh` 必须拒绝下发规则。
3. **不 remove WireGuard peer**：只能 `wg set peer ... endpoint` 原地更新。remove+add 会清零握手重传计数，导致此后持续握手失败。
4. **config.yaml 是端点唯一事实源**：轮换端点后必须同步配置并重启容器，否则容器会把端点改回去。
5. **DNS 重定向必须排在排除规则之前**；**TCP 重定向必须排在排除规则之后**。顺序颠倒会造成解析污染或本机失联。
6. **远程部署先排除 SSH 源 IP**：`LP_AUTO_EXCLUDE_SSH=1` 默认开启；手工改配置时要保留。
7. **验收只在设备内部做**：绝不在管理电脑上加全量路由或透明代理规则。
8. **原子回滚**：规则写入失败必须整体撤销，不允许留下半套规则。
9. **按拓扑处理**：旁路由必须开 SNAT；单臂路由必须填 VLAN 子接口名而不是物理口。

## 修改配置后

执行 `sh scripts/render.sh && sh scripts/up.sh`；若只改了防火墙相关参数，可执行 `sh scripts/fw.sh reload`。守护进程会在接口/网段/排除集变化时自动重载，无需手工干预。
