# AGENTS.md — Universal operating instructions for AI agents

本文件面向**任意 AI 平台 / 编码助手**（Claude Code、Cursor、GitHub Copilot、Codex、WorkBuddy、通义灵码等）。任何 AI 拿到本仓库后，按本文件执行即可完成部署、验收与排障。无需依赖任何特定平台的 skill 机制。

> Target: deploy a self-healing LAN transparent proxy on a gateway device (OpenWrt / iStoreOS / Debian / NAS / mini PC).
> Read order: `AGENTS.md` → `README.md` → `references/topologies.md` → `references/configuration.md`.

---

## 0. 适用范围与前提

**平台准入（先判断，不满足就别往下走）**：

| 平台 | 支持 | 处理 |
|------|------|------|
| OpenWrt / iStoreOS / 衍生版 | ✅ 完整 | 正常执行本文件全部步骤 |
| x86 / ARM + Debian/Ubuntu Linux | ✅ 完整 | 正常执行 |
| 群晖 / 威联通等 NAS | ⚠️ 降级 | 设 `LP_FW_ENABLED=0`，只提供显式代理 |
| 普通家用路由器原厂固件 | ❌ 不支持 | 刷 OpenWrt，或改用旁路由 + 一台 Linux 设备 |
| Windows / macOS | ❌ 不支持 | 只能作为客户端；不要在它上面跑本方案 |
| WSL / Docker 容器内 | ❌ 不支持 | 必须跑在宿主 |

- **在操作目标网关设备上执行**，不是管理用的 Windows/Mac/PC。
- 需要 root。
- 依赖：`docker`、`iproute2`、`nftables`（或 `iptables`）、`curl`；WARP 模式另需 `wireguard-tools` 与内核 WireGuard 模块。
- 若设备不支持透明代理（例如群晖 NAS），设 `LP_FW_ENABLED=0`，只提供显式代理。
- 完整平台矩阵见 `references/platform-matrix.md` 第 0 节。

## 1. 决策树（先判断拓扑，再动手）

```
设备是否在客户端流量主路径上？
├─ 否（旁路由：客户端网关手动指向本机）→ LP_TOPOLOGY=bypass，必须开 SNAT
└─ 是
   ├─ 单网卡 + VLAN trunk（eth0.1 LAN / eth0.2 WAN）→ LP_TOPOLOGY=onearm
   └─ 两个以上接口（br-lan + WAN）→ LP_TOPOLOGY=main
```

`detect.sh` 会自动判定，但仍需人工/AI 复核 `LP_TOPOLOGY` 是否正确。判定不准时手工覆盖。

## 2. 标准执行序列

按顺序执行，不要跳步：

```sh
# 1) 放置文件：把 scripts/ 与 assets/ 复制到目标设备的 $LP_BASE（默认 /opt/lan-proxy）
mkdir -p /opt/lan-proxy && cd /opt/lan-proxy
#    （复制仓库中的 scripts/ 和 assets/ 到此目录）

# 2) 探测（只写配置，不改系统）
sh scripts/detect.sh

# 3) 核对 etc/proxy.env：LP_TOPOLOGY / LP_INTERFACE / LP_LAN_CIDRS /
#    LP_PROXY_IP / LP_GATEWAY / 五个端口。改完保存。

# 4) 上游二选一
sh scripts/warp-keygen.sh          # WARP：导入 warp.conf 或用 wgcf 生成
# 或：编辑 etc/custom-proxies.yaml，设 LP_MODE=custom 与 LP_CUSTOM_PROXY_NAMES

# 5) 可选但强烈建议：把 country.mmdb 与 geosite.dat 放到 etc/ 启用 GEOIP 分流

# 6) 启动
sh scripts/up.sh

# 7) 验收（隔离在设备内部，不碰管理电脑路由）
sh scripts/verify.sh

# 8) 稳定后安装开机自启
sh scripts/install-init.sh
```

成功标志：`up.sh` 打印出显式代理地址、透明代理设置方式与出口 IP；`verify.sh` 中 DNS 返回 fake-ip、境外站点 OK、国内站点 OK、规则计数器非零。

## 3. 三种拓扑的关键参数

| 拓扑 | LP_INTERFACE | LP_PROXY_IP | LP_GATEWAY | LP_MASQUERADE |
|------|--------------|-------------|------------|---------------|
| bypass 旁路由 | 单口如 `eth0` | 旁路由 IP | 主路由 IP | `1` 或 `auto` |
| main 双口主路由 | `br-lan` | LAN 口 IP | 上级/光猫 | `0` |
| onearm 单臂 | VLAN 子接口如 `eth0.1` | VLAN 内 IP | 上级/光猫 | `0` |

单臂路由必须填 VLAN 子接口名，父接口不配 IP；交换机 trunk 的 VLAN ID 必须一致。

## 4. 安全红线（不可违反）

1. **不要在本地管理电脑上做全量路由劫持来测试**。验收只能用 `verify.sh` 的隔离容器。
2. **停止顺序固定**：先撤防火墙规则，再停代理。`down.sh` 已按此实现，不要改顺序。
3. **安全闸**：代理端口未监听时禁止下发透明规则。
4. **WireGuard peer 只能原地更新 endpoint**，绝不 `remove` 后 `add`（会清零握手重传计数，导致持续握手失败）。
5. **config.yaml 是上游端点的唯一事实源**：换端点后必须同步配置并重启容器。
6. **DNS 重定向在排除规则之前；TCP 重定向在排除规则之后**。
7. **规则原子下发，失败整体回滚**，不允许留下半套规则。
8. **远程部署排除 SSH 源 IP**（`LP_AUTO_EXCLUDE_SSH=1`），否则可能把自己锁在外面。
9. **旁路由必须开 SNAT**，否则回包绕过本机造成非对称路由。

## 5. 常用运维与回退

```sh
sh scripts/status.sh            # 总览
sh scripts/fw.sh status         # 规则
sh scripts/fw.sh counters       # 命中计数
sh scripts/guard.sh status      # 隧道/出口/容器
sh scripts/fw.sh reload         # 只重载规则
sh scripts/up.sh                # 改配置后重启
sh scripts/down.sh              # 一键回退到普通网络
docker logs -f lan-proxy        # 日志
```

失联时的应急：通过管理网口/串口/VNC 执行 `nft delete table ip lan_proxy`（或 `sh scripts/down.sh`），网络立即恢复。

## 6. 失败处理

| 现象 | 先做什么 |
|------|----------|
| 全网断网 | 立刻 `down.sh`，然后查规则顺序与代理端口 |
| SSH/LuCI 连不上 | `fw.sh stop`，检查 SSH 源 IP 是否在排除列表 |
| 隧道正常但实际走直连 | `ip rule show`、`ip route show table <LP_WG_TABLE>`，确认 fwmark 规则存在 |
| 端点反复回退 | 确认改了 config.yaml 并重启了容器 |
| 国内站点也走代理 | 放 geodata 到 `etc/` 后重新 `render.sh && up.sh` |
| 手机 App 502 | 客户端侧绕过 `127.0.0.0/8` 与内网段（回环地址语义问题） |

更完整的排障表见 `references/troubleshooting.md`。

## 7. 交付给用户的格式

完成后向用户报告：

1. 显式代理地址与透明代理设置方式（网关/DNS 指向哪个 IP）
2. 面板地址与密码（提醒修改默认密码）
3. 拓扑判定结果与 SNAT 状态
4. 验收结果（DNS / 境外 / 国内 / 计数器）
5. 回退命令 `sh scripts/down.sh`
6. 哪些项目未实测（如本机无 Docker/真实网关时）
