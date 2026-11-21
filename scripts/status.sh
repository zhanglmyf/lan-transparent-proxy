#!/bin/sh
# 状态总览：配置 / 隧道 / 容器 / 规则 / 出口
LP_ENV=${LP_ENV:-/opt/lan-proxy/etc/proxy.env}
. "$(dirname "$0")/lib.sh"

echo "=== lan-proxy 状态 ==="
echo " 模式        : $LP_MODE"
echo " 作用域      : $LP_INTERFACE / $LP_LAN_CIDRS"
echo " 本机地址    : ${LP_PROXY_IP:-$(detect_lan_ip)}"
echo " 端口        : mixed=$LP_MIXED_PORT redir=$LP_REDIR_PORT tproxy=$LP_TPROXY_PORT dns=$LP_DNS_PORT api=$LP_API_PORT"
echo " 代理端口    : $(proxy_ready && echo 就绪 || echo 未就绪)"
echo " 容器        : $(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -w "$LP_CONTAINER" || echo 未运行)"
[ "$LP_MODE" = "warp" ] && {
    echo " 隧道        : $(tunnel_ok && echo 正常 || echo 未就绪)"
    echo " 策略路由    : $(route_ok && echo 正常 || echo 异常)"
    echo " 上游端点    : $LP_WG_ENDPOINT"
}
echo " 出口 IP     : $(egress_ip || echo 获取失败)"
echo " 排除目标    : $(build_exclude)"
echo " 防火墙后端  : $(fw_backend)"
echo ""
echo "--- 透明规则摘要 ---"
sh "$(dirname "$0")/fw.sh" status 2>/dev/null | head -20
echo ""
echo "--- 守护 ---"
pgrep -f "guard.sh loop" >/dev/null 2>&1 && echo " 运行中" || echo " 未运行"
