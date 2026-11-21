# 平台差异对照

核心脚本使用 POSIX sh，不依赖 bash 特性；目标是 OpenWrt busybox 与 Debian 都能跑。

| 平台 | LAN 接口常见值 | 防火墙 | 隧道 | 开机自启 | 备注 |
|------|----------------|--------|------|----------|------|
| OpenWrt 22.03+ / iStoreOS | `br-lan` | nftables（fw4） | 需 `kmod-wireguard` + `wireguard-tools` | procd | `fw.sh` 用独立 nft table，fw4 重载不会误删 |
| OpenWrt 21.x 及更早 | `br-lan` | iptables | 同上 | procd | `LP_FW_BACKEND=iptables`，用自定义链 + `iptables-restore -n` |
| Debian / Ubuntu 服务器 | `eth0` / `enp*` | nft 或 iptables | 内核自带 | systemd | 需先装 Docker |
| OpenMediaVault / 小主机 Debian | `eth0` | nft | 内核自带 | systemd | 若设备不是网关，需客户端手动把网关指向它 |
| 群晖 / 威联通 NAS | `eth0` / `ovs_eth0` | 通常 iptables | 套件不一定有 | 计划任务 | 建议只用显式代理模式（`LP_FW_ENABLED=0`） |
| Docker 容器里 | — | 需特权 | 不支持 | — | 本方案设计运行在宿主，不是容器内部 |

## OpenWrt / iStoreOS 要点

- 安装包：`opkg update && opkg install dockerd wireguard-tools kmod-wireguard`
- `LP_INTERFACE` 通常探测为 `br-lan`；若有多个 LAN 口桥接，仍是一个接口。
- 若主路由不是本机（旁路由模式），客户端网关必须手动指向本机；此时 `LP_GATEWAY` 是真正的主路由，不要填自己。
- `install-init.sh` 生成 procd 服务。**不要**在主服务的 rc.common 里定义 `USE_PROCD=0`：OpenWrt 24.10 判断 `[ -n "$USE_PROCD" ]`，"0" 为非空，会走 procd 分支并覆盖自定义 `start()`/`stop()`，导致停止时清理逻辑失效。

## Debian / Ubuntu 要点

- 安装 Docker 官方源后，`systemctl enable --now docker`。
- 网卡名可能是 `enp0s3`、`end0` 等，以 `detect.sh` 探测结果为准。
- 若作为旁路由，需在主路由上把客户端网关指向本机，或开启本机的 IPv4 forwarding（容器 host 网络下通常由 Docker 处理）。
- UFirewall / firewalld 与 nft 规则可能共存；本方案的独立 table 不冲突，但不要在其他工具里 flush 全部 nft 规则。

## 非网关设备的降级模式

如果设备不是流量必经之路，无法做透明代理，可设：

```sh
LP_FW_ENABLED=0
```

此时只提供显式代理（mixed-port），客户端逐台填写代理地址即可，完全不碰防火墙。

## geodata 获取

把以下两个文件放到 `$LP_BASE/etc/`：

- `country.mmdb`（GeoIP 数据库，mihomo 内置格式）
- `geosite.dat`（GeoSite 数据库）

来源可以是 mihomo 官方发布或常用的规则数据源。下载失败不影响启动，但会退化为「仅私网直连，其余全走代理」，国内站点也会走代理出口。

## 资源建议

- 内存：mihomo 常驻约 100–200MB，fake-ip 与规则集越多占用越高。
- CPU：WARP 模式的内核 WireGuard 在软路由上通常足够；千兆线速建议 x86 或带加密加速的 SoC。
- 磁盘：镜像与日志约 1GB 起。
