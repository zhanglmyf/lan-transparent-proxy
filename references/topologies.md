# 三种网络拓扑适配

脚本不假设设备一定是主路由。`detect.sh` 会根据接口数量、默认路由接口、VLAN 子接口与网段关系自动判定拓扑，写入 `LP_TOPOLOGY`，并据此决定是否启用 SNAT。也可手工覆盖。

```
旁路由 bypass        双口主路由 main         单臂路由 onearm
  客户端                 客户端                  客户端
     │                      │                       │
  [主路由] ← 网关       [本机 LAN 口]          [交换机 VLAN trunk]
     ↑                      │                       │
   [本机] ← 网关指向     [本机 WAN 口]          eth0.1(LAN) eth0.2(WAN)
     │                      │                       │
    internet             internet                internet
```

## 1. 旁路由（bypass）

**特征**：设备不在客户端流量主路径上；客户端的网关/DNS 手动（或由主路由 DHCP 下发）指向本机；本机自己再通过主路由上网。常见于 NAS、小主机做旁网关。

**自动判定**：LAN 接口与默认路由接口相同（单网卡），或 LAN/WAN 在同一网段（双网卡接同一交换机）。

**必须注意**：

- **SNAT**：旁路由必须把客户端流量伪装成本机 IP，否则主路由的回包可能绕过旁路由，形成非对称路径。脚本在 `LP_MASQUERADE=auto` 且拓扑为 bypass 时自动开启 nft `masquerade` / iptables `MASQUERADE`。手工关闭可能导致「部分网站打不开」。
- **主路由管理页**：客户端访问主路由管理地址时，目标 IP 在排除列表里（网关 IP 自动排除），不会被劫持，可直接访问。
- **DHCP 指向**：如果由主路由下发网关，把 DHCP 的网关和 DNS 都设为旁路由 IP；或者逐台设备手工设置。
- **回环地址坑**：手机 App 请求 `127.0.0.1:端口` 时，代理会把这个请求转到旁路由本机（那里没有服务）→ 502。这是回环地址语义问题，只能在客户端侧绕过 `127.0.0.0/8`，或只给浏览器配代理。

配置示例：

```sh
LP_TOPOLOGY=bypass
LP_INTERFACE="eth0"
LP_LAN_CIDRS="192.168.1.0/24"
LP_PROXY_IP=192.168.1.2       # 旁路由 IP（按实际填写）
LP_GATEWAY=192.168.1.1        # 主路由 IP
LP_MASQUERADE=auto            # = 1
```

## 2. 双口主路由（main）

**特征**：一个 WAN 口接上级网络/光猫，一个 LAN 口（通常是网桥 `br-lan`）接客户端；本机就是客户端的默认网关。这是最标准的场景。

**自动判定**：默认路由接口与 LAN 接口不同，且两者网段不同。

**必须注意**：

- **不要在 WAN 口下发劫持规则**：脚本用 `iifname $LP_INTERFACE` 限定只处理 LAN 口进来的流量，WAN 侧不受影响。
- **LAN 桥接**：多 LAN 口桥接为一个 `br-lan` 时，填桥接口名而不是物理口。
- **不启用 SNAT**：保留客户端真实源 IP，方便主路由/上游做基于 IP 的策略。
- 如果 LAN 口还承载了 Docker、IPTV 等网段，这些段已在自动排除列表里。

配置示例：

```sh
LP_TOPOLOGY=main
LP_INTERFACE="br-lan"
LP_LAN_CIDRS="192.168.1.0/24 192.168.2.0/24"
LP_PROXY_IP=192.168.1.1
LP_GATEWAY=<光猫或上级地址>   # PPPoE 拨号时通常为空
LP_MASQUERADE=0
```

## 3. 单臂路由（onearm）

**特征**：只有一个物理网卡，通过 VLAN trunk 同时跑 WAN 与 LAN。典型是 `eth0.1` 作 LAN、`eth0.2` 作 WAN，上级交换机/光猫配 trunk 口。

**自动判定**：LAN 或 WAN 接口名是 VLAN 子接口（如 `eth0.2`、`br-lan.10`），且两者不同。

**必须注意**：

- **填 VLAN 子接口而不是物理口**：`LP_INTERFACE=eth0.1`（LAN VLAN），`LP_WAN_INTERFACE=eth0.2`。填 `eth0` 会让规则匹配不到VLAN流量，或把 WAN 流量一起劫持。
- **交换机侧 VLAN 一致性**：trunk 允许的 VLAN ID、PVID、untagged 设置必须与设备上的子接口一致，否则网络本身就不通，跟代理无关。
- **父接口不要配 IP**：`eth0` 本身不应有地址，地址在子接口上。
- **规则作用域**：nft 的 `iifname "eth0.1"` 匹配 VLAN 子接口名，iptables 的 `-i eth0.1` 同理。
- **SNAT**：单臂路由是主路由，默认不开 SNAT；若你的 VLAN 拓扑特殊（LAN/WAN 同段），把 `LP_TOPOLOGY` 手工设为 `bypass`。

配置示例：

```sh
LP_TOPOLOGY=onearm
LP_INTERFACE="eth0.1"
LP_WAN_INTERFACE="eth0.2"
LP_LAN_CIDRS="192.168.10.0/24"
LP_PROXY_IP=192.168.10.1
LP_MASQUERADE=0
```

## 手工覆盖与验证

自动判定不准时，直接改 `proxy.env`：

```sh
LP_TOPOLOGY=bypass   # 或 main / onearm
LP_MASQUERADE=1      # 强制开 SNAT；0 强制关闭；auto 跟随拓扑
```

然后 `sh scripts/render.sh && sh scripts/up.sh`。

验证 SNAT 是否生效：

```sh
sh scripts/fw.sh status | grep -i masquerade
# nft 下应看到 chain postrouting_nat 与 comment "lp-masquerade"
```

验证规则只作用于 LAN 口：

```sh
sh scripts/fw.sh status | grep iifname
# 应只出现 LAN 接口名，不应出现 WAN 接口
```
