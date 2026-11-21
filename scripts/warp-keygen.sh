#!/bin/sh
# =====================================================================
#  warp-keygen.sh —— 生成/导入 WARP WireGuard 身份
#
#  优先从已有 warp.conf 导入（离线、最可靠）；其次调用 wgcf 生成。
#  只写 proxy.env，不改动系统其他部分。
#
#  用法：
#    sh warp-keygen.sh [warp.conf 路径]
# =====================================================================

LP_ENV=${LP_ENV:-/opt/lan-proxy/etc/proxy.env}
. "$(dirname "$0")/lib.sh"

need_root
[ -f "$LP_ENV" ] || die "缺少 $LP_ENV，请先运行 detect.sh"
CONF_IN=${1:-$LP_BASE/etc/warp.conf}

if [ ! -f "$CONF_IN" ] && cmd_exists wgcf; then
    echo "未找到 warp.conf，使用 wgcf 注册并生成 ..."
    ( cd "$LP_BASE/etc" && wgcf register --accept-tos && wgcf generate ) || die "wgcf 生成失败"
    CONF_IN="$LP_BASE/etc/wgcf-profile.conf"
fi

[ -f "$CONF_IN" ] || cat <<EOF >&2
未找到 WARP 配置文件。请用以下任一方式准备：

 A) 已有 WARP 账户：把 WireGuard 配置保存为 $LP_BASE/etc/warp.conf
    格式类似：
      [Interface]
      PrivateKey = xxxx
      Address = 172.16.0.2/32
      [Peer]
      PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
      Endpoint = 162.159.195.1:2408

 B) 安装 wgcf（https://github.com/ViRb3/wgcf）后重新运行本脚本：
    wgcf register --accept-tos && wgcf generate

 C) 已有私钥的场合，直接手工填入 proxy.env 的 LP_WG_PRIVATE_KEY /
    LP_WG_PUBLIC_KEY，并用 \`echo <私钥> | wg pubkey\` 推导公钥。
EOF
[ -f "$CONF_IN" ] || die "没有可用的 WARP 身份"

PRIV=$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$CONF_IN" | head -1)
PUB=$(sed -n 's/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*//p' "$CONF_IN" | head -1)
ENDPOINT=$(sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' "$CONF_IN" | head -1)
PEER=$(awk '/^\[Peer\]/{f=1;next} /^\[/{f=0} f && /^[[:space:]]*PublicKey/{sub(/^[^=]*=[[:space:]]*/,"");print;exit}' "$CONF_IN")
WGIP=$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$CONF_IN" | head -1 | cut -d/ -f1)

[ -n "$PRIV" ] || die "配置中未找到 PrivateKey"
[ -n "$PUB" ] || PUB=$(printf '%s\n' "$PRIV" | wg pubkey 2>/dev/null)
[ -n "$PUB" ] || die "无法推导本地公钥（需要 wireguard-tools 的 wg）"
[ -n "$PEER" ] || PEER="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
[ -n "$ENDPOINT" ] || ENDPOINT="$LP_WG_ENDPOINT"
[ -n "$WGIP" ] || WGIP="$LP_WG_IP"

# 写入 proxy.env（只替换这些键，不覆盖其他配置）
for kv in \
    "LP_WG_PRIVATE_KEY=$PRIV" \
    "LP_WG_PUBLIC_KEY=$PUB" \
    "LP_WG_PEER_PUB=$PEER" \
    "LP_WG_ENDPOINT=$ENDPOINT" \
    "LP_WG_IP=$WGIP" \
    "LP_WG_CIDR=$WGIP/32"; do
    k=${kv%%=*}
    v=${kv#*=}
    if grep -q "^$k=" "$LP_ENV"; then
        sed -i "s|^$k=.*|$k=$v|" "$LP_ENV"
    else
        printf '\n%s=%s\n' "$k" "$v" >> "$LP_ENV"
    fi
done
chmod 600 "$LP_ENV"

echo ""
echo "=== WARP 身份已导入 ==="
echo " 本地私钥 : ${PRIV:0:8}...(已隐藏)"
echo " 本地公钥 : $PUB"
echo " 对端公钥 : $PEER"
echo " 端点     : $ENDPOINT"
echo " 隧道地址 : $WGIP/32"
echo ""
echo "下一步：sh $LP_BASE/scripts/up.sh"
