#!/bin/sh
# =====================================================================
#  install-init.sh —— 安装开机自启（OpenWrt procd / systemd 自动识别）
#  只写 init 文件，不自动启用；由使用者决定何时 enable。
# =====================================================================

LP_ENV=${LP_ENV:-/opt/lan-proxy/etc/proxy.env}
. "$(dirname "$0")/lib.sh"

need_root
[ -f "$LP_ENV" ] || die "缺少 $LP_ENV，请先运行 detect.sh"
B="$LP_BASE/scripts"

if [ -f /etc/openwrt_release ]; then
    echo "检测到 OpenWrt/iStoreOS，安装 procd 服务 ..."
    cat > /etc/init.d/lan-proxy <<EOF
#!/bin/sh /etc/rc.common
START=95
STOP=10
start() { sh $B/up.sh >/dev/null 2>&1; }
stop()  { sh $B/down.sh >/dev/null 2>&1; }
restart() { stop; sleep 2; start; }
EOF
    cat > /etc/init.d/lan-proxy-guard <<EOF
#!/bin/sh /etc/rc.common
START=96
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh $B/guard.sh loop
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param file $LP_ENV
    procd_close_instance
}
service_triggers() { procd_add_reload_trigger "network"; }
EOF
    chmod +x /etc/init.d/lan-proxy /etc/init.d/lan-proxy-guard
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/99-lan-proxy <<EOF
#!/bin/sh
[ "\$ACTION" = "ifup" ] || exit 0
sleep 10
LP_ENV=$LP_ENV . $B/lib.sh
if port_open "\$LP_REDIR_PORT" && port_open "\$LP_DNS_PORT"; then
    sh $B/fw.sh reload >/dev/null 2>&1
fi
EOF
    chmod +x /etc/hotplug.d/iface/99-lan-proxy
    echo ""
    echo "已写入："
    echo "  /etc/init.d/lan-proxy"
    echo "  /etc/init.d/lan-proxy-guard"
    echo "  /etc/hotplug.d/iface/99-lan-proxy"
    echo "启用命令："
    echo "  /etc/init.d/lan-proxy enable && /etc/init.d/lan-proxy-guard enable"

elif [ -d /etc/systemd/system ] && cmd_exists systemctl; then
    echo "检测到 systemd，安装 service 单元 ..."
    cat > /etc/systemd/system/lan-proxy.service <<EOF
[Unit]
Description=LAN Transparent Proxy (mihomo)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh $B/up.sh
ExecStop=/bin/sh $B/down.sh

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/lan-proxy-guard.service <<EOF
[Unit]
Description=LAN Transparent Proxy Guard
After=lan-proxy.service docker.service
Requires=lan-proxy.service

[Service]
Type=simple
ExecStart=/bin/sh $B/guard.sh loop
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo ""
    echo "已写入："
    echo "  /etc/systemd/system/lan-proxy.service"
    echo "  /etc/systemd/system/lan-proxy-guard.service"
    echo "启用命令："
    echo "  systemctl enable --now lan-proxy lan-proxy-guard"

else
    die "未识别的 init 系统；请手动把 up.sh/down.sh/guard.sh 接入你的开机启动机制"
fi
