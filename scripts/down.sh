#!/bin/sh
# =====================================================================
#  down.sh —— 停止：先撤规则 → 停守护 → 停容器 → 清路由 → 拆隧道
#  顺序不可颠倒：规则留着而代理停了会把局域网 TCP 丢进黑洞。
# =====================================================================

LP_ENV=${LP_ENV:-/opt/lan-proxy/etc/proxy.env}
. "$(dirname "$0")/lib.sh"

need_root
D="$(dirname "$0")"

sh "$D/fw.sh" stop >/dev/null 2>&1 && log "透明代理规则已撤销"

if [ -x "/etc/init.d/lan-proxy-guard" ]; then
    /etc/init.d/lan-proxy-guard stop >/dev/null 2>&1
else
    sh "$D/guard.sh" stop >/dev/null 2>&1
fi

docker stop "$LP_CONTAINER" >/dev/null 2>&1
docker rm -f "$LP_CONTAINER" >/dev/null 2>&1
log "mihomo 容器已停止"

flush_route
[ "$LP_MODE" = "warp" ] && ip link del "$LP_WG_IF" 2>/dev/null
rm -f "$KEYFILE" "$LP_BASE/run/fw.sig" "$LP_BASE/run/fw.iptables"
echo "局域网代理已停止；透明规则、容器、策略路由与隧道接口均已清除"
