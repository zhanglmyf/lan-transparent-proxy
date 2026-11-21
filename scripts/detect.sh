#!/bin/sh
# =====================================================================
#  detect.sh —— 探测本机网络环境，生成可编辑的 proxy.env
#
#  用法：sh detect.sh [--yes]
#    --yes  非交互，全部采用探测值（端口冲突时自动顺延）
#
#  不修改任何系统配置，只写 $LP_BASE/etc/proxy.env。
# =====================================================================

LP_ENV=${LP_ENV:-/opt/lan-proxy/etc/proxy.env}
. "$(dirname "$0")/lib.sh"
SD="$(cd "$(dirname "$0")" && pwd)"

need_root
mkdir -p "$LP_BASE/etc" "$LP_BASE/run"

AUTO=0
[ "${1:-}" = "--yes" ] && AUTO=1

# 路径规范化：Windows 侧传入的反斜杠路径在 sh 里会被当转义符，统一成正斜杠
BASE_POSIX=$(printf '%s' "$LP_BASE" | tr '\\' '/')
LP_BASE="$BASE_POSIX"

# 保留旧的密钥字段（重新探测不应弄丢 WARP 身份）
OLD_PRIV=""; OLD_PUB=""; OLD_PEER=""; OLD_SECRET=""
if [ -f "$LP_ENV" ]; then
    OLD_PRIV=$(sed -n 's/^LP_WG_PRIVATE_KEY=//p' "$LP_ENV" | head -1)
    OLD_PUB=$(sed -n 's/^LP_WG_PUBLIC_KEY=//p' "$LP_ENV" | head -1)
    OLD_PEER=$(sed -n 's/^LP_WG_PEER_PUB=//p' "$LP_ENV" | head -1)
    OLD_SECRET=$(sed -n 's/^LP_API_SECRET=//p' "$LP_ENV" | head -1)
fi

# ---------------- 探测接口（含单臂 VLAN 子接口）----------------
# 保留 br-lan / eth0.2 / br-lan.10 这类 VLAN 子接口；排除 Docker 网桥与虚拟接口
candidates=""
for _d in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2}'); do
    case "$_d" in
        lo|docker*|veth*|wg*|lp-wg*|tun*|tailscale*|virbr*|sit*|ifb*) continue ;;
        br-*) case "$_d" in br-lan|br-lan.*|br-lan0) ;; *) continue ;; esac ;;
    esac
    candidates="$candidates $_d"
done

GW=$(detect_gateway)
WANIF=$(detect_wan_if)

# LAN 口选择优先级：br-lan → VLAN 子接口 → 普通网卡；跳过 WAN 口
picked=""
for _want in br-lan br-lan.1 lan0 lan0.1 eth0.1 eth0.2 eth1 end0 eth0; do
    for _d in $candidates; do
        [ "$_d" = "$_want" ] || continue
        [ "$_d" = "$WANIF" ] && continue
        picked="$_d"; break 2
    done
done
[ -z "$picked" ] && for _d in $candidates; do [ "$_d" != "$WANIF" ] && { picked="$_d"; break; }; done
# 旁路由（单口）：LAN 与 WAN 本来就是同一个接口
[ -z "$picked" ] && picked="$WANIF"
[ -z "$picked" ] && die "未找到带 IPv4 的 LAN 接口，请手动设置 LP_INTERFACE"

IFACES="$picked"
CIDRS=$(ip -4 route show dev "$picked" 2>/dev/null | awk '/proto kernel/ && /scope link/ {print $1; exit}')
IPADDR=$(ip -4 addr show dev "$picked" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
WAN_SUBNET=$(ip -4 route show dev "$WANIF" 2>/dev/null | awk '/proto kernel/ && /scope link/ {print $1; exit}')
LAN_SUBNET="$CIDRS"

# 拓扑判定：单口/LAN=WAN/同网段 → 旁路由；VLAN 子接口 → 单臂；否则双口主路由
if [ -n "$WANIF" ] && [ "$WANIF" = "$picked" ]; then
    TOPO=bypass
elif [ -n "$WANIF" ] && [ -n "$LAN_SUBNET" ] && [ "$LAN_SUBNET" = "$WAN_SUBNET" ]; then
    TOPO=bypass
elif echo "$candidates $WANIF" | grep -qE '(^| )[a-z0-9]+\.[0-9]+( |$)'; then
    TOPO=onearm
elif [ -n "$WANIF" ] && [ "$WANIF" != "$picked" ]; then
    TOPO=main
else
    TOPO=bypass
fi
case "$TOPO" in
    bypass) TOPO_DESC="旁路由（客户端手动指向本机；自动开启 SNAT）" ;;
    main)   TOPO_DESC="双口主路由（WAN 进 LAN 出）" ;;
    onearm) TOPO_DESC="单臂路由（单网卡 VLAN 子接口）" ;;
esac

# ---------------- 端口规划 ----------------
pick_port() {
    _p=$1
    _n=0
    while [ $_n -lt 20 ]; do
        if port_open "$_p"; then _p=$((_p + 1)); _n=$((_n + 1)); else echo "$_p"; return 0; fi
    done
    echo "$1"
}

P_MIXED=$(pick_port 7890)
P_REDIR=$(pick_port 7892)
P_TPROXY=$(pick_port 7893)
P_DNS=$(pick_port 1053)
P_API=$(pick_port 9090)

# ---------------- 渲染 ----------------
cat > "$LP_ENV" <<EOF
# lan-proxy 配置 —— 由 detect.sh 生成于 $(date '+%F %T')
# 任何字段都可以手工修改；改完执行 sh $LP_BASE/scripts/up.sh 生效

# ===== 基本 =====
LP_BASE=$LP_BASE
LP_MODE=warp                       # warp=Cloudflare WARP 免费出口；custom=自定义节点
LP_INTERFACE="$IFACES"             # 代理作用的 LAN 接口，空格分隔可多个
LP_LAN_CIDRS="$CIDRS"              # 代理作用的网段，空格分隔可多个
LP_PROXY_IP=$IPADDR                # 客户端应把网关/DNS 指向的地址
LP_GATEWAY=$GW                     # 上级网关（自动排除，防止绕环）
LP_WAN_IF=$WANIF                   # 上行接口（仅记录，供排障）
LP_WAN_INTERFACE=$WANIF            # WAN 接口（拓扑判定用）
LP_TOPOLOGY=$TOPO                  # bypass=旁路由 | main=双口主路由 | onearm=单臂路由
LP_MASQUERADE=auto                 # auto|1|0；旁路由自动开启 SNAT

# ===== 端口（全部可改，冲突时 detect 已自动顺延）=====
LP_MIXED_PORT=$P_MIXED             # http/socks5 显式代理
LP_REDIR_PORT=$P_REDIR             # TCP 透明代理
LP_TPROXY_PORT=$P_TPROXY           # UDP 透明代理
LP_DNS_PORT=$P_DNS                 # 劫持 53 后转交的 DNS 端口
LP_API_PORT=$P_API                 # mihomo 控制面板
LP_API_SECRET=${OLD_SECRET:-$(date +%s | md5sum 2>/dev/null | cut -c1-12)} # 面板密码

# ===== 排除目标（防止把本机/内网/上游入口劫持进代理）=====
LP_EXCLUDE_CIDRS="127.0.0.0/8 10.0.0.0/8 100.64.0.0/10 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4"
LP_EXCLUDE_IPS=""                  # 额外排除 IP，空格分隔
LP_UPSTREAM_CIDRS=""               # custom 模式下上游节点 IP/段
LP_AUTO_EXCLUDE_DOCKER=1
LP_AUTO_EXCLUDE_GATEWAY=1
LP_AUTO_EXCLUDE_SSH=1              # 远程部署时自动放过自己的 SSH 源 IP

# ===== WARP 出口（LP_MODE=warp 时必填；用 warp-keygen.sh 生成）=====
LP_WG_IF=lp-wg0
LP_WG_IP=172.16.0.2
LP_WG_CIDR=172.16.0.2/32
LP_WG_TABLE=111
LP_WG_FWMARK=2                     # 必须与 mihomo 节点 routing-mark 一致
LP_WG_MTU=1280
LP_WG_PRIVATE_KEY=${OLD_PRIV:-}    # 留空时请用 warp-keygen.sh 生成
LP_WG_PUBLIC_KEY=${OLD_PUB:-}
LP_WG_PEER_PUB=${OLD_PEER:-bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=}
LP_WG_ENDPOINT=162.159.195.1:2408
LP_WG_ENDPOINTS="162.159.195.1:2408 162.159.192.4:2408 188.114.96.2:2408 188.114.98.2:2408 162.159.193.1:2408"
LP_WG_ALLOWED_IPS="0.0.0.0/0,::/0"

# ===== 自定义节点（LP_MODE=custom 时使用）=====
LP_CUSTOM_PROXY_NAMES="MyProxy"    # 与 custom-proxies.yaml 里的 name 一致

# ===== TPROXY / 容器 / 防火墙 =====
LP_TPROXY_MARK=1
LP_TPROXY_TABLE=100
LP_CONTAINER=lan-proxy
LP_IMAGE=metacubex/mihomo:latest
LP_FW_BACKEND=auto                 # auto | nft | iptables
LP_NFT_TABLE=lan_proxy
LP_FW_ENABLED=1
LP_DNS_CAPTURE=1

# ===== 守护 =====
LP_GUARD_INTERVAL=60
LP_HEALTH_TARGET=https://www.gstatic.com/generate_204
EOF
chmod 600 "$LP_ENV"

# 提前放好自定义节点模板，切到 custom 模式即可直接编辑
[ -f "$LP_BASE/etc/custom-proxies.yaml" ] || \
    cp "$SD/../assets/custom-proxies.yaml.example" "$LP_BASE/etc/custom-proxies.yaml"

echo ""
echo "=== 探测结果 ==="
echo " LAN 接口  : $IFACES"
echo " LAN 网段  : ${CIDRS:-<未探测到，请手填>}"
echo " 本机 IP   : ${IPADDR:-<未探测到，请手填>}"
echo " 上级网关  : ${GW:-<无>}"
echo " 上行接口  : ${WANIF:-<无>}"
echo " 网络拓扑  : $TOPO — $TOPO_DESC"
echo " 端口      : mixed=$P_MIXED redir=$P_REDIR tproxy=$P_TPROXY dns=$P_DNS api=$P_API"
echo " 配置已写入: $LP_ENV"
echo ""

if [ "$AUTO" = "0" ]; then
    printf '现在编辑配置吗？[y/N] '
    read -r _ans
    case "$_ans" in
        y|Y|yes|YES) ${EDITOR:-vi} "$LP_ENV" ;;
    esac
fi

echo "下一步："
echo "  1) 若用 WARP：sh $SD/warp-keygen.sh   （生成 LP_WG_PRIVATE_KEY）"
echo "  2) 若用自定义节点：编辑 $LP_BASE/etc/custom-proxies.yaml 并设 LP_MODE=custom"
echo "  3) sh $SD/up.sh"
