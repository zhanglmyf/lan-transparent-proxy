# 排障与踩坑清单

## 先做三步定位

```sh
sh scripts/status.sh          # 配置/端口/容器/隧道/出口总览
sh scripts/fw.sh counters     # 规则有没有命中
docker logs --tail 50 lan-proxy
```

按现象查下表。

## 现象 → 原因 → 处理

| 现象 | 常见原因 | 处理 |
|------|----------|------|
| 客户端完全上不了网 | 规则生效但代理未启动 | 立即 `sh scripts/down.sh`；再查 mihomo 端口与日志 |
| SSH / LuCI 突然连不上 | TCP 重定向排在排除之前，或 SSH 源 IP 不在排除里 | `fw.sh stop` 立刻恢复；检查 `LP_EXCLUDE_IPS` 与 `LP_AUTO_EXCLUDE_SSH`；确认 `fw.nft` 中 DNS→排除→TCP 顺序 |
| DNS 解析异常、国内域名解析到陌生地址 | DNS 重定向被排除规则提前 return | 确认 `fw.nft` 中 DNS 规则在排除规则之前 |
| 网页能开但境外站点超时 | 上游隧道握手成功但数据走直连 | 检查 `ip rule show \| grep 111` 与 `ip route show table 111`；守护应能自愈 |
| WARP 时好时坏，频繁重连 | 健康判断把 wg 输出解析错了，导致无谓轮换端点 | 确认用 `wg show <if> transfer` 的第 2 列取接收字节、`latest-handshakes` 取时间戳；不要 grep "received" |
| 端点切换后几分钟又被改回旧值 | 只改了内核 peer，没同步 mihomo 配置 | `set_config_endpoint` 写回 `config.yaml` 后重启容器 |
| 握手后再也不握手 | 对 peer 做了 remove + add | 恢复为只 `wg set peer ... endpoint` 原地更新 |
| `ip rule` 规则反复累积或删不掉 | `ip rule del` 无匹配也返回 0；或把整个条件加了引号当成一个参数 | 用有限循环 + 计数校验；`ip rule del fwmark 0x2 lookup 111` 必须拆成多个参数 |
| OpenWrt 上 `stop` 不清理 | rc.common 里定义了 `USE_PROCD=0` | 删除该变量；"0" 是非空字符串，会被当成走 procd 分支 |
| 容器重启后透明规则消失 | 防火墙重载把规则冲掉，或 LAN 接口 ifup | 使用独立 nft table；装好 hotplug 脚本 `99-lan-proxy`；守护会自动重载 |
| 手机 App 挂代理后连不上 NAS（502） | App 请求自己本机的 `127.0.0.1:端口`，被代理转到网关设备 | 在客户端侧绕过 `127.0.0.0/8` 与内网段；或只给浏览器配代理。这是回环地址的语义问题，网关侧修不了 |
| 国内站点也走代理、速度慢 | 没有 geodata，退回简化分流 | 放 `country.mmdb` 和 `geosite.dat` 到 `$LP_BASE/etc/`，重新 `render.sh && up.sh` |
| 端口被占用启动失败 | 默认端口已有服务 | 用 `detect.sh` 重新探测自动顺延，或手改 `proxy.env` 五个端口 |

## 应急回退

```sh
# 一键回到普通网络（先撤规则，再停服务）
sh scripts/down.sh

# 只撤透明规则，保留显式代理
sh scripts/fw.sh stop

# 只需要重新下发规则
sh scripts/fw.sh reload
```

如果网络已经失联、SSH 进不去，用管理网口/串口/VNC 登录后执行 `nft delete table ip lan_proxy`（或 `sh scripts/down.sh`），规则清除后网络立即恢复。

## 已验证的设计铁律

1. `wg set peer ... remove` 再 add 会清零握手重传计数，导致持续握手失败。只做原地 endpoint 更新。
2. `wg show <if> transfer` 的输出是 `<pub>\t<rx>\t<tx>`，不是人类可读格式；按 "received" 关键字取值永远取不到。
3. `ip rule del` 无匹配仍返回 0，必须用「循环 + 规则计数归零」终止。
4. `ip rule add/del` 的参数必须分开写，整体加引号会被当成单个参数解析失败。
5. DNS 重定向必须在排除之前；TCP 重定向必须在排除之后。
6. 规则必须原子下发，失败整体回滚；绝不能留下「排除没写进去但重定向生效」的半套规则。
7. 内核 WireGuard + 策略路由缺一不可：只有 allowed-ips 不足以把出站流量送进隧道。
8. 守护必须用 procd/systemd 托管；裸 `&` 在 OpenWrt 下会随 SSH 会话结束被回收。
9. 验收绝不能在本机 Windows/Mac 上加全量路由，要用隔离容器。
10. 手机 App 的内部回环服务（如 `127.0.0.1:8895`）挂全局代理必踩坑，只能客户端侧绕过。
