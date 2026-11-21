# 透明代理原理与规则顺序

## 三条数据路径

1. **DNS**：客户端 UDP/TCP 53 → nft `redirect` → mihomo DNS 端口 → fake-ip / 分流解析。
2. **TCP**：客户端 TCP → nft `redirect` 到 redir-port → mihomo 按规则决定直连或走代理。
3. **UDP**：客户端 UDP → nft `tproxy` 到 tproxy-port，并打 `meta mark` → 内核策略路由把标记包送回本机 → mihomo 处理。

## 为什么规则顺序不能错

nftables 链内按声明顺序匹配，先命中先执行：

```
prerouting_nat:
  ① DNS 重定向（udp/tcp dport 53）      ← 必须最前
  ② 排除受保护目标 → return
  ③ TCP 重定向到 redir-port            ← 必须在排除之后

prerouting_mangle:
  ① 排除受保护目标 → return
  ② DNS 端口放行 → return
  ③ UDP TPROXY + mark
```

- **DNS 重定向放在排除之前**：本机地址/网关也在排除列表里。如果排除在前，DNS 查询会先被 `return`，客户端继续拿到被污染的结果，表现为「代理能开网页但解析很怪」。
- **TCP 重定向放在排除之后**：否则访问本机 SSH、路由器 LuCI、Docker 发布端口的流量会被劫持到代理端口，直接把自己锁在外面。

## 为什么需要策略路由

WARP 模式下存在两条独立路由需求：

1. **上游隧道流量必须进隧道**：mihomo 出站 socket 的源地址会被内核选成物理网卡地址，命中不了 `from <WG_IP>` 规则。因此 mihomo 节点设置 `routing-mark: 2`，配合：

   ```sh
   ip rule add fwmark 0x2 lookup 111
   ip route replace default dev lp-wg0 table 111
   ```

   缺了这条规则时，隧道握手成功但数据仍从物理口直发，表现为「看着正常但实际走直连」。

2. **TPROXY 包必须回到本机**：`ip rule add fwmark 1 lookup 100` + `ip route add local 0.0.0.0/0 dev lo table 100`，否则打标 UDP 包不会被本地 socket 接管。

## 排除列表怎么来的

`build_exclude()` 每次渲染时动态合并：

- 内置私网/回环/链路本地/组播/保留地址
- 用户自定义 `LP_EXCLUDE_IPS`
- custom 模式的 `LP_UPSTREAM_CIDRS`
- Docker bridge 网段（自动探测）
- 上级网关 `/32`
- 本机 LAN IP `/32`
- WARP 边缘节点网段（防止端点轮换时回环）
- 当前 SSH 客户端源 IP `/32`（远程部署保护）

守护进程每轮比对这份列表的签名；变化后自动重新渲染并重载规则，这就是「活动路由」。

## nftables 与 iptables 后端

- `auto` 优先选 nft：独立 `table ip <name>`，`nft -f` 原子加载，失败自动删表。
- iptables 后端用 `LP_PRE` / `LP_PRE_M` 自定义链，先摘掉旧跳转，再用 `iptables-restore -n` 原子重建。**必须用 `-n`（noflush）**，否则会冲掉 Docker 和其他工具维护的规则。
- 两者都只处理 IPv4；IPv6 流量保持原样，不受影响。

## 两种上游模式

| 模式 | 隧道 | 路由 | 适合场景 |
|------|------|------|----------|
| `warp` | 内核 WireGuard `lp-wg0` | fwmark → 表 → 隧道 | 免费出口，需要稳定握手 |
| `custom` | 无（mihomo 直出） | 无需策略路由 | 已有节点，或设备不支持内核 WG |

WARP 模式的关键约束：

- 内核 WG 由宿主创建，mihomo 以 `system:true` 复用同一接口。
- 绝不 `wg set peer ... remove` 再 add：握手重传计数会清零，服务端可能不再响应该公钥+源端口组合，此后握手必然失败。只能原地 `endpoint`。
- 端点改变时必须同步 `config.yaml` 并重启容器，否则 mihomo 会用自己启动时读到的旧端点把内核配置改回去。
