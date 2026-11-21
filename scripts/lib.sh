#!/bin/sh
# =====================================================================
#  lan-proxy 公共库 —— 所有脚本的唯一配置入口与共享函数
#
#  设计原则：
#   · 所有路径、接口、网段、端口、出口参数都来自 proxy.env，脚本零硬编码
#   · 只依赖 POSIX sh + ip/nft（或 iptables）+ docker，兼容 OpenWrt busybox
#   · 路由操作全部幂等；ip rule del 即使无匹配也返回 0，必须计数校验
# =====================================================================

LP_ENV=${LP_ENV:-/opt/lan-proxy/etc/proxy.env}
[ -f "$LP_ENV" ] && . "$LP_ENV"

: "${LP_BASE:=/opt/lan-proxy}"
: "${LP_MODE:=warp}"                 # warp | custom
: "${LP_INTERFACE:=br-lan}"          # 空格分隔，可多个
: "${LP_LAN_CIDRS:=192.168.1.0/24}"  # 空格分隔，代理作用域
: "${LP_PROXY_IP:=}"                 # 本机 LAN 地址；空=自动取第一个接口地址
: "${LP_GATEWAY:=}"
: "${LP_TOPOLOGY:=auto}"             # auto | bypass | main | onearm
: "${LP_MASQUERADE:=auto}"           # auto | 1 | 0；旁路由通常需要 SNAT
: "${LP_WAN_INTERFACE:=}"            # WAN 接口（旁路由/单臂识别用）

# ----------- 网络拓扑 -----------
# bypass = 旁路由：设备不在流量主路径，客户端手动把网关/DNS 指向本机
# main   = 双口主路由：WAN 进 LAN 出，本机是客户端的默认网关
# onearm = 单臂路由：单网卡上用 VLAN 子接口同时跑 WAN 与 LAN
subnet_of() {
    ip -4 route show dev "$1" 2>/dev/null | awk '/proto kernel/ && /scope link/ {print $1; exit}'
}

detect_topology() {
    [ "$LP_TOPOLOGY" != "auto" ] && { echo "$LP_TOPOLOGY"; return 0; }
    _wan=${LP_WAN_INTERFACE:-$(detect_wan_if)}
    [ -z "$_wan" ] && { echo bypass; return 0; }
    # LAN 与 WAN 是同一个接口 → 旁路由（单口
    for _l in $LP_INTERFACE; do
        [ "$_l" = "$_wan" ] && { echo bypass; return 0; }
    done
    # 单臂：任一接口是 VLAN 子接口（eth0.2 / br-lan.10）
    case "$LP_INTERFACE $_wan" in
        *.*[0-9]*) echo onearm; return 0 ;;
    esac
    # LAN/WAN 同网段 → 旁路由（双口接到同一二层）
    _ls=$(subnet_of $(echo $LP_INTERFACE | awk '{print $1}'))
    _ws=$(subnet_of "$_wan")
    [ -n "$_ls" ] && [ "$_ls" = "$_ws" ] && { echo bypass; return 0; }
    echo main
}

masquerade_on() {
    [ "$LP_MASQUERADE" = "1" ] && return 0
    [ "$LP_MASQUERADE" = "0" ] && return 1
    [ "$(detect_topology)" = "bypass" ]
}

: "${LP_MIXED_PORT:=7890}"
: "${LP_REDIR_PORT:=7892}"
: "${LP_TPROXY_PORT:=7893}"
: "${LP_DNS_PORT:=1053}"
: "${LP_API_PORT:=9090}"
: "${LP_API_SECRET:=lanproxy}"

: "${LP_EXCLUDE_CIDRS:=127.0.0.0/8 10.0.0.0/8 100.64.0.0/10 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4}"
: "${LP_EXCLUDE_IPS:=}"
: "${LP_UPSTREAM_CIDRS:=}"           # custom 模式下上游节点 IP/段，避免回环
: "${LP_AUTO_EXCLUDE_DOCKER:=1}"
: "${LP_AUTO_EXCLUDE_GATEWAY:=1}"
: "${LP_AUTO_EXCLUDE_SSH:=1}"        # 远程操作时自动排除自己的 SSH 源 IP

: "${LP_WG_IF:=lp-wg0}"
: "${LP_WG_IP:=172.16.0.2}"
: "${LP_WG_CIDR:=172.16.0.2/32}"
: "${LP_WG_TABLE:=111}"
: "${LP_WG_FWMARK:=2}"
: "${LP_WG_MTU:=1280}"
: "${LP_WG_PRIVATE_KEY:=}"
: "${LP_WG_PUBLIC_KEY:=}"
: "${LP_WG_PEER_PUB:=}"
: "${LP_WG_ENDPOINT:=162.159.195.1:2408}"
: "${LP_WG_ENDPOINTS:=162.159.195.1:2408 162.159.192.4:2408 188.114.96.2:2408 188.114.98.2:2408 162.159.193.1:2408}"
: "${LP_WG_ALLOWED_IPS:=0.0.0.0/0,::/0}"

: "${LP_TPROXY_MARK:=1}"
: "${LP_TPROXY_TABLE:=100}"

: "${LP_CONTAINER:=lan-proxy}"
: "${LP_IMAGE:=metacubex/mihomo:latest}"
: "${LP_CONFIG:=${LP_BASE}/etc/mihomo.yaml}"
: "${LP_KEYFILE:=${LP_BASE}/run/wg.key}"

: "${LP_FW_BACKEND:=auto}"           # auto | nft | iptables
: "${LP_NFT_TABLE:=lan_proxy}"
: "${LP_FW_ENABLED:=1}"
: "${LP_DNS_CAPTURE:=1}"

: "${LP_GUARD_INTERVAL:=60}"
: "${LP_HEALTH_TARGET:=https://www.gstatic.com/generate_204}"

DATA="$LP_BASE"
CONF="$LP_CONFIG"
KEYFILE="$LP_KEYFILE"

log()  { echo "[lan-proxy] $(date '+%H:%M:%S') $*"; }
err()  { echo "[lan-proxy][ERR] $(date '+%H:%M:%S') $*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
    [ "$(id -u)" = "0" ] || die "需要 root 权限：$0"
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

listen_output() {
    if cmd_exists ss; then ss -lnt 2>/dev/null
    else netstat -lnt 2>/dev/null; fi
}

port_open() {
    [ -n "$1" ] || return 1
    listen_output | awk -v p=":$1" '$4 ~ p"$" || $4 ~ p":" {found=1} END{exit !found}'
}

proxy_ready() {
    port_open "$LP_MIXED_PORT" && port_open "$LP_REDIR_PORT" && port_open "$LP_DNS_PORT"
}

# 把空格分隔的列表渲染成 nftables 集合；空列表返回 { }
cidr_set() {
    _s=""
    for _x in $1; do
        [ -n "$_s" ] && _s="$_s, "
        _s="$_s$_x"
    done
    printf '{ %s }' "$_s"
}

iface_set() {
    _s=""
    for _x in $1; do
        [ -n "$_s" ] && _s="$_s, "
        _s="$_s\"$_x\""
    done
    printf '{ %s }' "$_s"
}

# ---------------- 网络自动探测 ----------------

route_default() {
    ip route show default 2>/dev/null | head -1
}

detect_gateway() {
    route_default | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}

detect_wan_if() {
    route_default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

detect_lan_ip() {
    for _i in $LP_INTERFACE; do
        _a=$(ip -4 addr show dev "$_i" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
        [ -n "$_a" ] && { echo "$_a"; return 0; }
    done
}

detect_lan_cidrs() {
    for _i in $LP_INTERFACE; do
        ip -4 route show dev "$_i" 2>/dev/null | awk '/proto kernel/ && /scope link/ {print $1; exit}'
    done
}

detect_docker_nets() {
    cmd_exists docker || return 0
    docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
}

# 从 SSH 环境变量取客户端源 IP（只取第一个地址字段）
ssh_source_ip() {
    [ "${LP_AUTO_EXCLUDE_SSH:-1}" = "1" ] || return 0
    if [ -n "${SSH_CONNECTION:-}" ]; then
        set -- $SSH_CONNECTION
        echo "$1"
    elif [ -n "${SSH_CLIENT:-}" ]; then
        set -- $SSH_CLIENT
        echo "$1"
    fi
}

# 当前应排除的全部目标：内置私网 + 用户自定义 + Docker + 网关 + 本机 + 上游 + SSH 源
build_exclude() {
    _ex="$LP_EXCLUDE_CIDRS $LP_EXCLUDE_IPS $LP_UPSTREAM_CIDRS"
    [ "${LP_AUTO_EXCLUDE_DOCKER:-1}" = "1" ] && _ex="$_ex $(detect_docker_nets)"
    [ "${LP_AUTO_EXCLUDE_GATEWAY:-1}" = "1" ] && [ -n "$LP_GATEWAY" ] && _ex="$_ex $LP_GATEWAY/32"
    [ -n "$LP_PROXY_IP" ] && _ex="$_ex $LP_PROXY_IP/32"
    [ "${LP_MODE}" = "warp" ] && _ex="$_ex 162.159.192.0/24 162.159.193.0/24 162.159.195.0/24 188.114.96.0/24 188.114.98.0/24"
    _src=$(ssh_source_ip)
    [ -n "$_src" ] && _ex="$_ex $_src/32"
    # 去重并压成一行
    printf '%s\n' $_ex | awk '!seen[$0]++' | tr '\n' ' '
}

# ---------------- 防火墙后端 ----------------
fw_backend() {
    if [ "$LP_FW_BACKEND" = "auto" ]; then
        if cmd_exists nft && nft list tables >/dev/null 2>&1; then echo nft
        elif cmd_exists iptables-save; then echo iptables
        else echo none; fi
    else
        echo "$LP_FW_BACKEND"
    fi
}

# ---------------- WireGuard 与策略路由 ----------------

read_wg_key() {
    [ -n "$LP_WG_PRIVATE_KEY" ] || return 1
    mkdir -p "$LP_BASE/run"
    printf '%s\n' "$LP_WG_PRIVATE_KEY" > "$KEYFILE"
    chmod 600 "$KEYFILE"
}

current_endpoint() { echo "$LP_WG_ENDPOINT"; }

set_config_endpoint() {
    _ep="$1"
    _h=${_ep%:*}; _p=${_ep#*:}
    [ -n "$_h" ] && [ -n "$_p" ] || return 1
    [ -f "$CONF" ] || return 1
    sed -i "s|^\([[:space:]]*\)server:.*|\1server: $_h|; s|^\([[:space:]]*\)port:.*|\1port: $_p|" "$CONF" 2>/dev/null || return 1
    grep -q "server: $_h" "$CONF" || return 1
    # 同步到 env，保证下次渲染一致
    if [ -f "$LP_ENV" ]; then
        sed -i "s|^LP_WG_ENDPOINT=.*|LP_WG_ENDPOINT=$_ep|" "$LP_ENV"
    fi
    return 0
}

# 幂等建立策略路由。切记：ip rule del 无匹配时同样返回 0，必须计数确认。
ensure_route() {
    [ "${LP_MODE}" = "warp" ] || return 0
    _i=0
    while [ $_i -lt 10 ]; do
        ip rule del fwmark 0x$LP_WG_FWMARK lookup "$LP_WG_TABLE" 2>/dev/null
        [ "$(ip rule list 2>/dev/null | grep "lookup $LP_WG_TABLE" | grep -c fwmark)" -eq 0 ] && break
        _i=$((_i + 1))
    done
    _i=0
    while [ $_i -lt 10 ]; do
        ip rule del from "$LP_WG_IP" lookup "$LP_WG_TABLE" 2>/dev/null
        [ "$(ip rule list 2>/dev/null | grep "lookup $LP_WG_TABLE" | grep -c "from $LP_WG_IP")" -eq 0 ] && break
        _i=$((_i + 1))
    done
    ip rule add fwmark 0x$LP_WG_FWMARK lookup "$LP_WG_TABLE" 2>/dev/null
    ip rule add from "$LP_WG_IP" lookup "$LP_WG_TABLE" 2>/dev/null
    ip route replace default dev "$LP_WG_IF" table "$LP_WG_TABLE" 2>/dev/null
}

route_ok() {
    [ "${LP_MODE}" = "warp" ] || return 0
    _a=$(ip rule list 2>/dev/null | grep "lookup $LP_WG_TABLE" | grep -c fwmark)
    _b=$(ip rule list 2>/dev/null | grep "lookup $LP_WG_TABLE" | grep -c "from $LP_WG_IP")
    _c=$(ip route show table "$LP_WG_TABLE" 2>/dev/null | grep -c "default dev $LP_WG_IF")
    [ "$_a" = "1" ] && [ "$_b" = "1" ] && [ "$_c" = "1" ]
}

flush_route() {
    _i=0
    while [ $_i -lt 10 ]; do
        ip rule del fwmark 0x$LP_WG_FWMARK lookup "$LP_WG_TABLE" 2>/dev/null
        [ "$(ip rule list 2>/dev/null | grep "lookup $LP_WG_TABLE" | grep -c fwmark)" -eq 0 ] && break
        _i=$((_i + 1))
    done
    _i=0
    while [ $_i -lt 10 ]; do
        ip rule del from "$LP_WG_IP" lookup "$LP_WG_TABLE" 2>/dev/null
        [ "$(ip rule list 2>/dev/null | grep "lookup $LP_WG_TABLE" | grep -c "from $LP_WG_IP")" -eq 0 ] && break
        _i=$((_i + 1))
    done
    ip route flush table "$LP_WG_TABLE" 2>/dev/null
}

# 建立/复用内核 WG 接口。已存在时绝不删除重建，保留握手状态。
setup_wg_iface() {
    if ip link show "$LP_WG_IF" >/dev/null 2>&1; then
        ip addr add "$LP_WG_CIDR" dev "$LP_WG_IF" 2>/dev/null
        wg set "$LP_WG_IF" private-key "$KEYFILE" 2>/dev/null
        ip link set "$LP_WG_IF" up mtu "$LP_WG_MTU" 2>/dev/null
        return 0
    fi
    ip link add "$LP_WG_IF" type wireguard 2>/dev/null || {
        err "创建 $LP_WG_IF 失败（缺 kmod-wireguard / wireguard-tools）"; return 1; }
    ip addr add "$LP_WG_CIDR" dev "$LP_WG_IF" 2>/dev/null
    wg set "$LP_WG_IF" private-key "$KEYFILE" 2>/dev/null || { ip link del "$LP_WG_IF" 2>/dev/null; return 1; }
    ip link set "$LP_WG_IF" up mtu "$LP_WG_MTU" 2>/dev/null
}

# 原地更新 peer（绝不 remove+add：会让握手重传计数清零）
setup_wg_peer() {
    _ep="${1:-$LP_WG_ENDPOINT}"
    wg set "$LP_WG_IF" peer "$LP_WG_PEER_PUB" \
        allowed-ips "$LP_WG_ALLOWED_IPS" \
        endpoint "$_ep" \
        persistent-keepalive 25 2>/dev/null
}

# wg 输出格式：latest-handshakes = "<pub>\t<epoch>"; transfer = "<pub>\t<rx>\t<tx>"
tunnel_ok() {
    ip link show "$LP_WG_IF" >/dev/null 2>&1 || return 1
    wg show "$LP_WG_IF" latest-handshakes 2>/dev/null | grep -q "$LP_WG_PEER_PUB" || return 1
    _rx=$(wg show "$LP_WG_IF" transfer 2>/dev/null | grep "$LP_WG_PEER_PUB" | awk '{print $2}')
    [ -n "$_rx" ] && [ "$_rx" != "0" ] || return 1
    _hs=$(wg show "$LP_WG_IF" latest-handshakes 2>/dev/null | grep "$LP_WG_PEER_PUB" | awk '{print $2}')
    [ -n "$_hs" ] && [ "$_hs" -gt 0 ] 2>/dev/null || return 1
    _age=$(( $(date +%s) - _hs ))
    [ "$_age" -lt 600 ]
}

# 端到端健康（直接走显式代理，不碰本机路由）
proxy_ok() {
    env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        curl -s -o /dev/null -w '%{http_code}' -m 20 \
        -x "socks5h://127.0.0.1:$LP_MIXED_PORT" "$LP_HEALTH_TARGET" 2>/dev/null | grep -q '^2'
}

egress_ip() {
    _i=0
    while [ $_i -lt 3 ]; do
        _r=$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
             curl -s -m 15 -x "socks5h://127.0.0.1:$LP_MIXED_PORT" https://api.ipify.org 2>/dev/null)
        [ -n "$_r" ] && { echo "$_r"; return 0; }
        sleep 3
        _i=$((_i + 1))
    done
}
