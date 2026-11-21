#!/bin/sh
# =====================================================================
#  render.sh —— 把 proxy.env 渲染成 mihomo 配置与 nftables 规则文件
#
#  产出（均在 $LP_BASE/etc/）：
#    mihomo.yaml   供容器挂载
#    fw.nft        供 fw.sh 原子加载
#
#  不启动任何服务，不改动系统状态。改完配置重新 render + up 即可。
# =====================================================================

LP_ENV=${LP_ENV:-/opt/lan-proxy/etc/proxy.env}
. "$(dirname "$0")/lib.sh"

[ -f "$LP_ENV" ] || die "缺少配置 $LP_ENV，请先运行 detect.sh"
D="$(dirname "$0")/.."
mkdir -p "$LP_BASE/etc" "$LP_BASE/rules" "$LP_BASE/geodata"

# ---------------- 节点块 ----------------
if [ "$LP_MODE" = "warp" ]; then
    [ -n "$LP_WG_PRIVATE_KEY" ] || die "LP_WG_PRIVATE_KEY 为空，请先运行 warp-keygen.sh"
    WG_HOST=${LP_WG_ENDPOINT%:*}
    WG_PORT=${LP_WG_ENDPOINT##*:}
    PROXIES=$(sed \
        -e "s|@@WG_HOST@@|$WG_HOST|g" \
        -e "s|@@WG_PORT@@|$WG_PORT|g" \
        -e "s|@@WG_PRIV@@|$LP_WG_PRIVATE_KEY|g" \
        -e "s|@@WG_PUB@@|$LP_WG_PUBLIC_KEY|g" \
        -e "s|@@WG_PEER@@|$LP_WG_PEER_PUB|g" \
        -e "s|@@WG_IP@@|$LP_WG_IP|g" \
        -e "s|@@WG_MTU@@|$LP_WG_MTU|g" \
        -e "s|@@WG_FWMARK@@|$LP_WG_FWMARK|g" \
        "$D/assets/warp-proxy.yaml.tmpl")
    MEMBERS="      - WARP"
else
    CF="$LP_BASE/etc/custom-proxies.yaml"
    [ -f "$CF" ] || die "LP_MODE=custom 但缺少 $CF"
    PROXIES=$(cat "$CF")
    MEMBERS=""
    for _n in $LP_CUSTOM_PROXY_NAMES; do
        [ -n "$MEMBERS" ] && MEMBERS="$MEMBERS
"
        MEMBERS="$MEMBERS      - $_n"
    done
fi

# ---------------- 分流规则（geodata 有无两档）----------------
if [ -f "$LP_BASE/etc/country.mmdb" ] && [ -f "$LP_BASE/etc/geosite.dat" ]; then
    RULES="  - GEOIP,private,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,PROXY"
    GEOIP_FILTER=true
    log "检测到 geodata，启用 GEOIP 分流"
else
    RULES="  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - MATCH,PROXY"
    GEOIP_FILTER=false
    err "未找到 $LP_BASE/etc/{country.mmdb,geosite.dat}，使用简化分流（仅私网直连，其余全走代理）。下载后放入该目录并重新 render。"
fi

# ---------------- 渲染 mihomo.yaml ----------------
# 简单标量占位符用 sed；多行块（节点/成员/规则）用 awk 注入，
# 避免 sed 的 s 命令遇到换行时报 "unterminated s command"。
sed -e "s|@@MIXED_PORT@@|$LP_MIXED_PORT|g" \
    -e "s|@@REDIR_PORT@@|$LP_REDIR_PORT|g" \
    -e "s|@@TPROXY_PORT@@|$LP_TPROXY_PORT|g" \
    -e "s|@@DNS_PORT@@|$LP_DNS_PORT|g" \
    -e "s|@@API_PORT@@|$LP_API_PORT|g" \
    -e "s|@@API_SECRET@@|$LP_API_SECRET|g" \
    -e "s|geoip: true|geoip: $GEOIP_FILTER|g" \
    "$D/assets/mihomo.yaml.tmpl" > "$LP_BASE/etc/mihomo.yaml.tmp"

awk -v proxies="$PROXIES" -v members="$MEMBERS" -v rules="$RULES" '
    $0 == "@@PROXIES@@"      { print proxies; next }
    $0 == "@@PROXY_MEMBERS@@" { print members; next }
    $0 == "@@RULES@@"        { print rules; next }
    { print }
' "$LP_BASE/etc/mihomo.yaml.tmp" > "$CONF"
rm -f "$LP_BASE/etc/mihomo.yaml.tmp"
chmod 600 "$CONF"

# ---------------- 渲染 nft 规则 ----------------
EXCL=$(cidr_set "$(build_exclude)")
SRCS=$(cidr_set "$LP_LAN_CIDRS")
IFACE=$(iface_set "$LP_INTERFACE")
TOPO=$(detect_topology)

# 旁路由需要 SNAT：客户端把网关指向本机，回包必须回到本机才能形成对称路径。
# 双口主路由默认不做 SNAT，保留客户端真实 IP。
if masquerade_on; then
    MASQ_CHAIN="
    chain postrouting_nat {
        type nat hook postrouting priority srcnat; policy accept;
        iifname $IFACE ip saddr $SRCS ip daddr != $EXCL counter masquerade comment \"lp-masquerade\"
    }"
    log "拓扑 $TOPO：已启用 SNAT/masquerade"
else
    MASQ_CHAIN=""
    log "拓扑 $TOPO：不启用 SNAT（保留客户端源 IP）"
fi

cat > "$LP_BASE/etc/fw.nft" <<EOF
# 由 render.sh 生成于 $(date '+%F %T')，请勿手改
table ip $LP_NFT_TABLE {
    chain prerouting_nat {
        type nat hook prerouting priority dstnat - 10; policy accept;
EOF

if [ "$LP_DNS_CAPTURE" = "1" ]; then
cat >> "$LP_BASE/etc/fw.nft" <<EOF
        # ① DNS 重定向必须在排除规则之前（否则本机地址被 return，拿到污染解析）
        iifname $IFACE ip saddr $SRCS udp dport 53 counter redirect to :$LP_DNS_PORT comment "lp-dns-udp"
        iifname $IFACE ip saddr $SRCS tcp dport 53 counter redirect to :$LP_DNS_PORT comment "lp-dns-tcp"
EOF
fi

cat >> "$LP_BASE/etc/fw.nft" <<EOF
        # ② 受保护目标：本机/内网/Docker/上游入口/SSH 源
        iifname $IFACE ip saddr $SRCS ip daddr $EXCL counter return comment "lp-exclude"
        # ③ TCP 透明代理必须在排除之后，否则 SSH 与容器发布端口会被劫持
        iifname $IFACE ip saddr $SRCS meta l4proto tcp counter redirect to :$LP_REDIR_PORT comment "lp-tcp"
    }
    chain prerouting_mangle {
        type filter hook prerouting priority mangle - 10; policy accept;
        iifname $IFACE ip saddr $SRCS ip daddr $EXCL counter return comment "lp-m-exclude"
        iifname $IFACE ip saddr $SRCS udp dport { 53, $LP_DNS_PORT } counter return comment "lp-m-dns"
        iifname $IFACE ip saddr $SRCS meta l4proto udp counter tproxy to 127.0.0.1:$LP_TPROXY_PORT meta mark set $LP_TPROXY_MARK comment "lp-udp"
    }
$MASQ_CHAIN
}
EOF

log "渲染完成：$CONF / $LP_BASE/etc/fw.nft"
log "作用域  ：接口 $LP_INTERFACE 网段 $LP_LAN_CIDRS"
log "排除集  ：$(build_exclude)"
