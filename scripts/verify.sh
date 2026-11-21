#!/bin/sh
# =====================================================================
#  verify.sh —— 端到端验收（完全隔离在设备内部）
#
#  绝不修改本机/管理电脑的路由。用 docker 起一个测试容器模拟局域网
#  客户端，只针对该容器 IP 下发临时 nft 规则，结束后全部清理。
#
#  验证：DNS 劫持 → fake-ip；境外站经透明代理；国内站直连；UDP 路径。
# =====================================================================

LP_ENV=${LP_ENV:-/opt/lan-proxy/etc/proxy.env}
. "$(dirname "$0")/lib.sh"

need_root
D="$(dirname "$0")"
NET_NAME=lp-verify-net
CLIENT=lp-verify-client
TEST_TABLE=lp_verify

cleanup() {
    echo ""
    echo "=== 清理验收环境 ==="
    nft delete table ip "$TEST_TABLE" 2>/dev/null && echo " 已删除临时 nft 表" || echo " 临时 nft 表不存在"
    docker rm -f "$CLIENT" >/dev/null 2>&1 && echo " 已删除测试容器" || echo " 测试容器不存在"
    docker network rm "$NET_NAME" >/dev/null 2>&1 && echo " 已删除测试网络" || echo " 测试网络不存在"
}
trap cleanup EXIT INT TERM

proxy_ready || die "mihomo 端口未就绪，先执行 up.sh"
cmd_exists nft || die "验收需要 nftables"
GW=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
[ -n "$GW" ] || GW=172.17.0.1

echo "=== 1. 准备隔离测试容器 ==="
docker rm -f "$CLIENT" >/dev/null 2>&1
docker network rm "$NET_NAME" >/dev/null 2>&1
docker run -d --name "$CLIENT" --network bridge --dns "$GW" \
    --entrypoint /bin/sleep "$LP_IMAGE" 900 >/dev/null 2>&1 || die "测试容器启动失败"
TEST_IP=$(docker inspect "$CLIENT" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
[ -n "$TEST_IP" ] || die "未取得测试容器 IP"
echo " 容器 IP=$TEST_IP  网关/DNS=$GW"

echo ""
echo "=== 2. 下发仅匹配测试容器的临时规则 ==="
EXCL=$(cidr_set "$(build_exclude)")
nft delete table ip "$TEST_TABLE" 2>/dev/null
nft -f - <<EOF || die "临时规则写入失败"
table ip $TEST_TABLE {
    chain prerouting_nat {
        type nat hook prerouting priority dstnat - 10; policy accept;
        ip saddr $TEST_IP udp dport 53 counter redirect to :$LP_DNS_PORT comment "verify-dns-udp"
        ip saddr $TEST_IP tcp dport 53 counter redirect to :$LP_DNS_PORT comment "verify-dns-tcp"
        ip saddr $TEST_IP ip daddr $EXCL counter return comment "verify-exclude"
        ip saddr $TEST_IP meta l4proto tcp counter redirect to :$LP_REDIR_PORT comment "verify-tcp"
    }
    chain prerouting_mangle {
        type filter hook prerouting priority mangle - 10; policy accept;
        ip saddr $TEST_IP ip daddr $EXCL counter return comment "verify-m-exclude"
        ip saddr $TEST_IP udp dport { 53, $LP_DNS_PORT } counter return comment "verify-m-dns"
        ip saddr $TEST_IP meta l4proto udp counter tproxy to 127.0.0.1:$LP_TPROXY_PORT meta mark set $LP_TPROXY_MARK comment "verify-udp"
    }
}
EOF
echo " 临时规则已生效"

echo ""
echo "=== 3. DNS 劫持（境外域名应返回 fake-ip 198.18.x.x）==="
docker exec "$CLIENT" nslookup www.google.com 2>&1 | sed 's/^/  /'
echo "  --- 国内域名 ---"
docker exec "$CLIENT" nslookup www.baidu.com 2>&1 | sed 's/^/  /'

echo ""
echo "=== 4. 出口 IP（应为代理出口地址）==="
docker exec "$CLIENT" wget -q -O - -T 20 https://api.ipify.org 2>&1 | sed 's/^/  /'
echo ""

echo ""
echo "=== 5. 境外站点（经透明代理）==="
for u in https://www.gstatic.com/generate_204 https://github.com/; do
    printf '  %-42s ' "$u"
    docker exec "$CLIENT" wget -q -O /dev/null -T 20 "$u" 2>&1 && echo OK || echo FAIL
done

echo ""
echo "=== 6. 国内站点（应直连）==="
for u in http://www.baidu.com/ https://www.qq.com/; do
    printf '  %-42s ' "$u"
    docker exec "$CLIENT" wget -q -O /dev/null -T 15 "$u" 2>&1 && echo OK || echo FAIL
done

echo ""
echo "=== 7. 规则计数器（确认流量确实命中）==="
nft list table ip "$TEST_TABLE" 2>/dev/null | grep -E 'comment' | sed 's/^/  /'

echo ""
echo "=== 8. 容器日志（最近 15 条）==="
docker logs --tail 15 "$LP_CONTAINER" 2>&1 | sed 's/^/  /'
