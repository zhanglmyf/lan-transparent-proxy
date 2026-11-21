#!/bin/sh
# =====================================================================
#  fw.sh —— 局域网透明代理规则（原子下发 / 原子回滚 / 双后端）
#
#  安全设计：
#   1. 独立 nft table / iptables 自定义链，不碰fw4/docker 自己的规则
#   2. nft -f 原子加载；iptables-restore -n 原子加载自定义链
#   3. 安全闸：代理端口没监听就拒绝下发，绝不把全网流量丢进黑洞
#   4. 规则顺序：DNS 重定向 → 排除 → TCP 重定向；mangle 排除 → DNS 放行 → UDP TPROXY
# =====================================================================

LP_ENV=${LP_ENV:-/opt/lan-proxy/etc/proxy.env}
. "$(dirname "$0")/lib.sh"

need_root
BACKEND=$(fw_backend)

apply_nft() {
    [ -f "$LP_BASE/etc/fw.nft" ] || die "缺少 fw.nft，请先运行 render.sh"
    proxy_ready || die "安全闸：mihomo 端口未就绪，拒绝下发透明代理规则"
    nft delete table ip "$LP_NFT_TABLE" 2>/dev/null
    if ! nft -f "$LP_BASE/etc/fw.nft"; then
        nft delete table ip "$LP_NFT_TABLE" 2>/dev/null
        die "nft 规则写入失败，已回滚"
    fi
    # TPROXY 策略路由：先删再加，保证只有一条
    ip rule del fwmark "$LP_TPROXY_MARK" lookup "$LP_TPROXY_TABLE" 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table "$LP_TPROXY_TABLE" 2>/dev/null
    ip rule add fwmark "$LP_TPROXY_MARK" lookup "$LP_TPROXY_TABLE" 2>/dev/null || {
        nft delete table ip "$LP_NFT_TABLE" 2>/dev/null; die "TPROXY 策略路由添加失败，已回滚"; }
    ip route add local 0.0.0.0/0 dev lo table "$LP_TPROXY_TABLE" 2>/dev/null

    _n=$(nft list table ip "$LP_NFT_TABLE" 2>/dev/null | grep -c 'iifname')
    _r=$(ip rule list 2>/dev/null | grep -c "fwmark $LP_TPROXY_MARK lookup $LP_TPROXY_TABLE")
    if [ "$_n" -lt 5 ] || [ "$_r" -ne 1 ]; then
        nft delete table ip "$LP_NFT_TABLE" 2>/dev/null; die "自检失败（规则 $_n 条 / 路由 $_r 条），已回滚"
    fi
    log "nft 规则已生效（作用域 $_n 条，TPROXY 路由 $_r 条）"
}

apply_iptables() {
    proxy_ready || die "安全闸：mihomo 端口未就绪，拒绝下发透明代理规则"
    # 先摘掉旧跳转（无匹配时返回非 0，忽略），再由 restore 原子重建
    iptables -t nat -D PREROUTING -j LP_PRE 2>/dev/null
    iptables -t mangle -D PREROUTING -j LP_PRE_M 2>/dev/null
    iptables -t nat -D POSTROUTING -j LP_POST 2>/dev/null

    _tmp="$LP_BASE/run/fw.iptables"
    mkdir -p "$LP_BASE/run"
    {
        echo '*nat'
        echo ':LP_PRE - [0:0]'
        echo '-A PREROUTING -j LP_PRE'
        if [ "$LP_DNS_CAPTURE" = "1" ]; then
            for _i in $LP_INTERFACE; do
                for _c in $LP_LAN_CIDRS; do
                    echo "-A LP_PRE -i $_i -s $_c -p udp --dport 53 -j REDIRECT --to-ports $LP_DNS_PORT"
                    echo "-A LP_PRE -i $_i -s $_c -p tcp --dport 53 -j REDIRECT --to-ports $LP_DNS_PORT"
                done
            done
        fi
        for _i in $LP_INTERFACE; do
            for _c in $LP_LAN_CIDRS; do
                for _e in $(build_exclude); do
                    echo "-A LP_PRE -i $_i -s $_c -d $_e -j RETURN"
                done
                echo "-A LP_PRE -i $_i -s $_c -p tcp -j REDIRECT --to-ports $LP_REDIR_PORT"
            done
        done
        if masquerade_on; then
            echo ':LP_POST - [0:0]'
            echo '-A POSTROUTING -j LP_POST'
            for _i in $LP_INTERFACE; do
                for _c in $LP_LAN_CIDRS; do
                    for _e in $(build_exclude); do
                        echo "-A LP_POST -i $_i -s $_c -d $_e -j RETURN"
                    done
                    echo "-A LP_POST -i $_i -s $_c -j MASQUERADE"
                done
            done
        fi
        echo 'COMMIT'
        echo '*mangle'
        echo ':LP_PRE_M - [0:0]'
        echo '-A PREROUTING -j LP_PRE_M'
        for _i in $LP_INTERFACE; do
            for _c in $LP_LAN_CIDRS; do
                for _e in $(build_exclude); do
                    echo "-A LP_PRE_M -i $_i -s $_c -d $_e -j RETURN"
                done
                echo "-A LP_PRE_M -i $_i -s $_c -p udp --dport 53 -j RETURN"
                echo "-A LP_PRE_M -i $_i -s $_c -p udp --dport $LP_DNS_PORT -j RETURN"
                echo "-A LP_PRE_M -i $_i -s $_c -p udp -j TPROXY --on-port $LP_TPROXY_PORT --tproxy-mark $LP_TPROXY_MARK"
            done
        done
        echo 'COMMIT'
    } > "$_tmp"

    if ! iptables-restore -n < "$_tmp"; then
        rm -f "$_tmp"; die "iptables 规则写入失败"
    fi
    ip rule del fwmark "$LP_TPROXY_MARK" lookup "$LP_TPROXY_TABLE" 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table "$LP_TPROXY_TABLE" 2>/dev/null
    ip rule add fwmark "$LP_TPROXY_MARK" lookup "$LP_TPROXY_TABLE" 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table "$LP_TPROXY_TABLE" 2>/dev/null
    log "iptables 规则已生效（后端 iptables）"
}

remove_nft() {
    nft delete table ip "$LP_NFT_TABLE" 2>/dev/null && log "nft 表 $LP_NFT_TABLE 已删除"
    ip rule del fwmark "$LP_TPROXY_MARK" lookup "$LP_TPROXY_TABLE" 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table "$LP_TPROXY_TABLE" 2>/dev/null
}

remove_iptables() {
    iptables -t nat -D PREROUTING -j LP_PRE 2>/dev/null
    iptables -t mangle -D PREROUTING -j LP_PRE_M 2>/dev/null
    iptables -t nat -D POSTROUTING -j LP_POST 2>/dev/null
    iptables -t nat -F LP_PRE 2>/dev/null; iptables -t nat -X LP_PRE 2>/dev/null
    iptables -t nat -F LP_POST 2>/dev/null; iptables -t nat -X LP_POST 2>/dev/null
    iptables -t mangle -F LP_PRE_M 2>/dev/null; iptables -t mangle -X LP_PRE_M 2>/dev/null
    ip rule del fwmark "$LP_TPROXY_MARK" lookup "$LP_TPROXY_TABLE" 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table "$LP_TPROXY_TABLE" 2>/dev/null
    log "iptables 链已清除"
}

case "${1:-}" in
    start|apply|reload)
        [ "$LP_FW_ENABLED" = "1" ] || { log "LP_FW_ENABLED=0，跳过"; exit 0; }
        # 安全闸必须先于任何规则操作，与后端类型无关
        proxy_ready || die "安全闸：mihomo 端口未就绪，拒绝下发透明代理规则"
        case "$BACKEND" in
            nft)      apply_nft ;;
            iptables) apply_iptables ;;
            *)        die "未找到 nft 或 iptables，无法启用透明代理（显式代理仍可用）" ;;
        esac
        ;;
    stop|remove)
        case "$BACKEND" in
            nft)      remove_nft ;;
            iptables) remove_iptables ;;
        esac
        ;;
    status)
        case "$BACKEND" in
            nft) nft list table ip "$LP_NFT_TABLE" 2>/dev/null && echo "--- 规则生效中 ---" || echo "--- 规则未启用 ---" ;;
            iptables) iptables -t nat -L LP_PRE -n --line-numbers 2>/dev/null || echo "--- 规则未启用 ---" ;;
        esac
        ip rule list 2>/dev/null | grep "lookup $LP_TPROXY_TABLE" || true
        ;;
    counters)
        case "$BACKEND" in
            nft) nft list table ip "$LP_NFT_TABLE" 2>/dev/null | grep -E 'comment|counter' ;;
            *)   iptables -t nat -L LP_PRE -n -v 2>/dev/null ;;
        esac
        ;;
    *) echo "用法: $0 {start|stop|status|counters}"; exit 1 ;;
esac
