# 参数说明（etc/proxy.env）

所有脚本都通过 `scripts/lib.sh` 读取本文件。修改后执行 `sh scripts/render.sh && sh scripts/up.sh` 生效。配置文件权限为 600，内含密钥，请勿提交到 Git。

## 基本

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `LP_BASE` | `/opt/lan-proxy` | 安装根目录，脚本、配置、日志都在这里 |
| `LP_MODE` | `warp` | `warp`=Cloudflare WARP；`custom`=自定义 mihomo 节点 |
| `LP_INTERFACE` | `br-lan` | 透明代理作用的 LAN 接口，空格分隔可多个，如 `"br-lan eth1"` |
| `LP_LAN_CIDRS` | `192.168.1.0/24` | 透明代理作用的客户端网段，空格分隔可多个 |
| `LP_PROXY_IP` | 探测值 | 客户端应把网关/DNS 指向的地址（本机 LAN IP） |
| `LP_GATEWAY` | 探测值 | 上级网关，自动加入排除列表，防止流量绕环 |
| `LP_WAN_IF` | 探测值 | 上行接口，仅记录供排障 |
| `LP_WAN_INTERFACE` | 探测值 | WAN 接口，`detect_topology()` 判定拓扑用 |
| `LP_TOPOLOGY` | `auto` | `auto` 自动判定；`bypass` 旁路由 / `main` 双口主路由 / `onearm` 单臂路由 |
| `LP_MASQUERADE` | `auto` | `auto` 跟随拓扑（旁路由自动开 SNAT）；`1` 强制开；`0` 强制关 |

拓扑判定规则见 `references/topologies.md`。旁路由必须开 SNAT，否则回包可能绕过本机导致部分站点打不开。

多网段示例：

```sh
LP_INTERFACE="br-lan eth1"
LP_LAN_CIDRS="192.168.1.0/24 192.168.2.0/24 10.9.0.0/24"
```

## 端口

| 参数 | 默认 | 用途 |
|------|------|------|
| `LP_MIXED_PORT` | 7890 | HTTP/SOCKS5 显式代理 |
| `LP_REDIR_PORT` | 7892 | TCP 透明代理（nft REDIRECT） |
| `LP_TPROXY_PORT` | 7893 | UDP 透明代理（TPROXY） |
| `LP_DNS_PORT` | 1053 | DNS 劫持后转交给 mihomo 的端口 |
| `LP_API_PORT` | 9090 | mihomo 控制面板 |
| `LP_API_SECRET` | 随机 | 面板密码，务必修改 |

`detect.sh` 会检测端口占用并从默认值开始顺延。手工改端口后需重新渲染并重启。

## 排除目标

| 参数 | 默认 | 说明 |
|------|------|------|
| `LP_EXCLUDE_CIDRS` | 私网/回环/组播/保留段 | 不劫持这些目标，避免内网与本机服务被代理 |
| `LP_EXCLUDE_IPS` | 空 | 额外排除 IP，空格分隔 |
| `LP_UPSTREAM_CIDRS` | 空 | custom 模式下上游节点 IP/段，避免自己劫持上游 |
| `LP_AUTO_EXCLUDE_DOCKER` | 1 | 自动把 Docker bridge 网段加入排除 |
| `LP_AUTO_EXCLUDE_GATEWAY` | 1 | 自动把上级网关加入排除 |
| `LP_AUTO_EXCLUDE_SSH` | 1 | 远程部署时自动放过 SSH 客户端源 IP |

WARP 模式下脚本还会自动排除 Cloudflare WARP 边缘节点网段（端点轮换时避免回环）。

## WARP 上游

| 参数 | 默认 | 说明 |
|------|------|------|
| `LP_WG_IF` | `lp-wg0` | 内核 WireGuard 接口名 |
| `LP_WG_IP` | `172.16.0.2` | 隧道地址 |
| `LP_WG_CIDR` | `172.16.0.2/32` | 隧道地址（含掩码） |
| `LP_WG_TABLE` | 111 | 策略路由表号 |
| `LP_WG_FWMARK` | 2 | 出站打标；必须与 mihomo 节点 `routing-mark` 一致 |
| `LP_WG_MTU` | 1280 | 隧道 MTU |
| `LP_WG_PRIVATE_KEY` | 空 | 本地私钥，由 `warp-keygen.sh` 写入 |
| `LP_WG_PUBLIC_KEY` | 空 | 本地公钥，由私钥推导 |
| `LP_WG_PEER_PUB` | WARP 公钥 | 对端公钥 |
| `LP_WG_ENDPOINT` | `162.159.195.1:2408` | 当前端点（单一事实源） |
| `LP_WG_ENDPOINTS` | 多个候选 | 守护轮换用的端点列表 |
| `LP_WG_ALLOWED_IPS` | `0.0.0.0/0,::/0` | peer 允许地址 |

## 自定义上游

| 参数 | 默认 | 说明 |
|------|------|------|
| `LP_CUSTOM_PROXY_NAMES` | `MyProxy` | `custom-proxies.yaml` 里的节点名，空格分隔 |

## TPROXY / 容器 / 防火墙

| 参数 | 默认 | 说明 |
|------|------|------|
| `LP_TPROXY_MARK` | 1 | UDP TPROXY 的 fwmark |
| `LP_TPROXY_TABLE` | 100 | TPROXY 策略路由表号 |
| `LP_CONTAINER` | `lan-proxy` | 容器名 |
| `LP_IMAGE` | `metacubex/mihomo:latest` | 容器镜像 |
| `LP_CONFIG` | `$LP_BASE/etc/mihomo.yaml` | 渲染后的 mihomo 配置 |
| `LP_FW_BACKEND` | `auto` | `auto` / `nft` / `iptables` |
| `LP_NFT_TABLE` | `lan_proxy` | nftables 独立表名 |
| `LP_FW_ENABLED` | 1 | 设 0 则只提供显式代理，不下发透明规则 |
| `LP_DNS_CAPTURE` | 1 | 设 0 则只劫持 TCP/UDP 应用流量，不劫持 53 |

## 守护

| 参数 | 默认 | 说明 |
|------|------|------|
| `LP_GUARD_INTERVAL` | 60 | 巡检间隔（秒） |
| `LP_HEALTH_TARGET` | gstatic generate_204 | 端到端健康探测目标 |
| `LP_ENV` | `/opt/lan-proxy/etc/proxy.env` | 可用环境变量覆盖，便于多套配置并存 |
