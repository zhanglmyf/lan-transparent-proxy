#!/bin/sh
# =====================================================================
#  guard.sh —— 守护：路由自愈 / 隧道恢复 / 容器拉起 / LAN 变化重载
#
#  「活动路由」含义：LAN 接口、网段、Docker 网段、网关、SSH 源变化后
#  自动重新渲染并原子重载防火墙规则，不需要人工干预。
#
#  WARP 铁律（踩坑沉淀）：
#   · 只做 `wg set peer ... endpoint` 原地更新，绝不 remove+add
#   · config.yaml 是端点的单一事实源，轮换后必须重启容器同步
#   · wg 输出格式：latest-handshakes="<pub>\t<epoch>"，transfer="<pub>\t<rx>\t<tx>"
# =====================================================================

LP_ENV=${LP_ENV:-/opt/lan-proxy/etc/proxy.env}
. "$(dirname "$0")/lib.sh"

need_root
D="$(dirname "$0")"
CHECK_INTERVAL=${LP_GUARD_INTERVAL:-60}
EP_GAP=8
EP_WAIT=10

restart_container() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$LP_CONTAINER" || return 1
    log "重启 mihomo 以同步端点配置"
    docker restart "$LP_CONTAINER" >/dev/null 2>&1
    _i=0
    while [ $_i -lt 25 ]; do
        sleep 1
        proxy_ready && { sleep 2; return 0; }
        _i=$((_i + 1))
    done
    err "mihomo 重启后端口未就绪"; return 1
}

check_container() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$LP_CONTAINER" && return 0
    log "mihomo 容器未运行，正在拉起"
    docker rm -f "$LP_CONTAINER" >/dev/null 2>&1
    docker run -d --name "$LP_CONTAINER" --restart unless-stopped --network host \
        --cap-add NET_ADMIN --cap-add SYS_MODULE --device /dev/net/tun \
        -e TZ=Asia/Shanghai -v "$LP_BASE/etc:/etc/mihomo:ro" \
        "$LP_IMAGE" -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1
    sleep 6
    ensure_route
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$LP_CONTAINER"
}

recover_tunnel() {
    [ "$LP_MODE" = "warp" ] || { check_container; return $?; }
    read_wg_key || { err "无法读取私钥"; return 1; }
    setup_iface() { setup_wg_iface; }
    setup_iface || return 1
    ensure_route
    CUR="$LP_WG_ENDPOINT"

    for EP in $LP_WG_ENDPOINTS; do
        log "尝试上游端点 $EP"
        set_config_endpoint "$EP" || continue
        setup_wg_peer "$EP"

        _i=0; _ok=0
        while [ $_i -lt "$EP_WAIT" ]; do
            sleep 2
            tunnel_ok && { _ok=1; break; }
            _i=$((_i + 1))
        done
        [ "$_ok" = "1" ] || { log "端点 $EP 无响应"; sleep "$EP_GAP"; continue; }

        if [ "$EP" != "$CUR" ]; then
            log "端点切换 $CUR -> $EP，同步容器配置"
            restart_container
            setup_wg_peer "$EP"
            ensure_route
        fi
        log "端点 $EP 恢复成功"
        return 0
    done
    err "所有候选端点均无响应"; return 1
}

# LAN 环境签名：接口/网段/排除集任一变化都要重载规则
signature() {
    _sig="$(printf '%s|%s|%s' "$LP_INTERFACE" "$LP_LAN_CIDRS" "$(build_exclude)" | md5sum 2>/dev/null | cut -d' ' -f1)"
    [ -n "$_sig" ] || _sig=$(printf '%s|%s' "$LP_INTERFACE" "$LP_LAN_CIDRS" | cksum | cut -d' ' -f1)
    echo "$_sig"
}

check_lan_change() {
    mkdir -p "$LP_BASE/run"
    _cur=$(signature)
    _old=$(cat "$LP_BASE/run/fw.sig" 2>/dev/null)
    if [ "$_cur" = "$_old" ]; then return 0; fi
    if [ -z "$_old" ]; then
        echo "$_cur" > "$LP_BASE/run/fw.sig"
        return 0
    fi
    log "检测到 LAN 环境变化，重新渲染并重载透明规则"
    if sh "$D/render.sh" >/dev/null 2>&1 && sh "$D/fw.sh" reload >/dev/null 2>&1; then
        echo "$_cur" > "$LP_BASE/run/fw.sig"
        log "透明规则已随 LAN 变化更新"
    else
        err "LAN 变化后重载规则失败，保留旧规则"
    fi
}

loop() {
    log "守护启动（巡检间隔 ${CHECK_INTERVAL}s，模式 $LP_MODE）"
    mkdir -p "$LP_BASE/run"
    echo "$(signature)" > "$LP_BASE/run/fw.sig"
    while true; do
        # ① 策略路由自愈
        if ! route_ok; then
            log "策略路由异常，正在修复"
            ensure_route
            route_ok && log "策略路由已修复" || err "策略路由修复失败"
        fi
        # ② 上游健康
        if [ "$LP_MODE" = "warp" ]; then
            tunnel_ok || { log "上游隧道未就绪，开始恢复"; recover_tunnel; }
        else
            proxy_ok || { log "代理出口异常，尝试重启容器"; restart_container; }
        fi
        # ③ 容器存活
        check_container || err "mihomo 容器拉起失败"
        # ④ LAN 变化 → 活动路由重载
        [ "$LP_FW_ENABLED" = "1" ] && check_lan_change
        sleep "$CHECK_INTERVAL"
    done
}

case "${1:-}" in
    loop) loop ;;
    start)
        if pgrep -f "guard.sh loop" >/dev/null 2>&1; then
            echo "守护已在运行"
        else
            mkdir -p "$LP_BASE/run"
            (sh "$D/guard.sh" loop >> "$LP_BASE/run/guard.log" 2>&1 &)
            echo "守护已启动，日志：$LP_BASE/run/guard.log"
        fi
        ;;
    stop)
        for p in $(pgrep -f "guard.sh loop" 2>/dev/null); do kill "$p" 2>/dev/null; done
        echo "守护已停止"
        ;;
    status)
        if [ "$LP_MODE" = "warp" ]; then
            tunnel_ok && echo "隧道状态 : 正常" || echo "隧道状态 : 未就绪"
            route_ok && echo "策略路由 : 正常" || echo "策略路由 : 异常"
        fi
        proxy_ok && echo "代理出口 : 正常" || echo "代理出口 : 异常"
        echo "出口 IP  : $(egress_ip)"
        echo "容器     : $(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -w "$LP_CONTAINER" || echo '未运行')"
        [ "$LP_MODE" = "warp" ] && { echo "端点     : $LP_WG_ENDPOINT"; wg show "$LP_WG_IF" 2>/dev/null; }
        ;;
    once)
        ensure_route
        if [ "$LP_MODE" = "warp" ]; then
            read_wg_key && setup_wg_iface && setup_wg_peer "$LP_WG_ENDPOINT" && \
            (tunnel_ok && echo "隧道正常" || { recover_tunnel && echo "已恢复"; })
        else
            proxy_ok && echo "代理出口正常" || echo "代理出口异常"
        fi
        ;;
    recover) recover_tunnel ;;
    *) echo "用法: $0 {start|stop|status|once|recover|loop}"; exit 1 ;;
esac
