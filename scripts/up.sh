#!/bin/sh
# =====================================================================
#  up.sh —— 一键启动：渲染配置 → 建隧道 → 起 mihomo → 配路由 → 下发透明规则
# =====================================================================

LP_ENV=${LP_ENV:-/opt/lan-proxy/etc/proxy.env}
. "$(dirname "$0")/lib.sh"

need_root
[ -f "$LP_ENV" ] || die "缺少 $LP_ENV，请先运行 detect.sh"
D="$(dirname "$0")"

log "====== 启动局域网透明代理 ======"

# 1) 渲染（每次启动都渲染，保证 env 改动生效）
sh "$D/render.sh" || die "配置渲染失败"
chmod 644 "$CONF" 2>/dev/null

# 2) 上游隧道（warp 模式：内核 WG，保留握手状态）
if [ "$LP_MODE" = "warp" ]; then
    [ -n "$LP_WG_PRIVATE_KEY" ] || die "LP_WG_PRIVATE_KEY 为空，请先运行 warp-keygen.sh"
    read_wg_key || die "私钥写入失败"
    setup_wg_iface || die "内核 WireGuard 接口创建失败（检查 kmod-wireguard / wireguard-tools）"
    setup_wg_peer "$LP_WG_ENDPOINT"
    _i=0
    while [ $_i -lt 15 ]; do
        sleep 2
        tunnel_ok && { log "上游隧道已握手"; break; }
        _i=$((_i + 1))
    done
    tunnel_ok || log "上游隧道尚未握手，守护进程会持续重试"
fi

# 3) 策略路由必须在容器启动前就位，否则首轮出站会走直连
ensure_route
route_ok && log "策略路由就绪" || err "策略路由异常：ip rule show && ip route show table $LP_WG_TABLE"

# 4) mihomo 容器（host 网络，挂载 etc 整个目录，config.yaml 与 geodata 一起进容器）
log "启动 mihomo 容器 ..."
docker rm -f "$LP_CONTAINER" >/dev/null 2>&1
docker run -d \
    --name "$LP_CONTAINER" \
    --restart unless-stopped \
    --network host \
    --cap-add NET_ADMIN \
    --cap-add SYS_MODULE \
    --device /dev/net/tun \
    -e TZ=Asia/Shanghai \
    -v "$LP_BASE/etc:/etc/mihomo:ro" \
    "$LP_IMAGE" -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$LP_CONTAINER"; then
    err "容器启动失败"; docker logs --tail 20 "$LP_CONTAINER" 2>&1; exit 1
fi

_i=0
while [ $_i -lt 40 ]; do
    sleep 1
    proxy_ready && { log "mihomo 端口就绪"; break; }
    _i=$((_i + 1))
done
proxy_ready || { err "mihomo 端口未就绪"; docker logs --tail 20 "$LP_CONTAINER" 2>&1; exit 1; }

# 5) 容器以 system:true 接管 WG 接口后再确认一次路由
ensure_route

# 6) 守护：负责路由自愈、隧道恢复、容器拉起、LAN 变化重载
if [ -x "/etc/init.d/lan-proxy-guard" ]; then
    /etc/init.d/lan-proxy-guard start >/dev/null 2>&1
else
    sh "$D/guard.sh" start >/dev/null 2>&1
fi

# 7) 透明规则（安全闸在 fw.sh 内部）
if [ "$LP_FW_ENABLED" = "1" ]; then
    if sh "$D/fw.sh" start >/dev/null 2>&1; then
        log "透明代理规则已生效"
    else
        err "透明规则未下发（显式代理模式仍可用）"
    fi
fi

echo
echo "=========================================="
echo " 局域网代理已启动"
echo "=========================================="
echo " 显式代理 : http://$LP_PROXY_IP:$LP_MIXED_PORT  /  socks5h://$LP_PROXY_IP:$LP_MIXED_PORT"
echo " 透明代理 : 客户端网关 + DNS 指向 $LP_PROXY_IP"
echo " DNS      : $LP_PROXY_IP:$LP_DNS_PORT"
echo " 面板     : http://$LP_PROXY_IP:$LP_API_PORT  (密码 $LP_API_SECRET)"
echo " 出口 IP  : $(egress_ip)"
echo " 状态     : sh $D/status.sh"
echo " 验收     : sh $D/verify.sh"
echo "=========================================="
