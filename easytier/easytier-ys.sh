#!/bin/sh
# -----------------------------------------------------------------------------
#  EasyTier 网对网全自动启动脚本（支持多节点）
#  用法：./easytier.sh <network-name> <network-secret>
#  说明：
#  1. 配置文件 easytier.txt 定义节点和本地网络
#  2. 支持多个节点配置
#  3. 自动配置网对网防火墙
# -----------------------------------------------------------------------------
set -e

# ---------- 用户可调变量 ----------
ARCH="${ARCH:-}"                 # 自动检测架构，可手动覆盖
USERNAME="${USERNAME:-}"         # 为空时默认取 network-name
PROXY_DEV="${PROXY_DEV:-tun0}"   # EasyTier 虚拟接口
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EASYTIER_DIR="/opt/app/easytier"
CONFIG_FILE="$SCRIPT_DIR/easytier.txt"
LOG_TAG="【easytier】"
ZIP_VER="2.3.2"

# ---------- 工具函数 ----------
log() { logger -t "$LOG_TAG" "$1"; }
die() { echo "$1" >&2; log "$1"; exit 1; }

# ---------- 参数检查 ----------
[ "$#" -lt 2 ] && die "用法：$0 <network-name> <network-secret>"
NETWORK_NAME="$1"
NETWORK_SECRET="$2"
USERNAME="${USERNAME:-$NETWORK_NAME}"

# ---------- 配置文件处理 ----------
if [ ! -f "$CONFIG_FILE" ]; then
    MACHINE_ID=$(tr -dc 'a-f0-9' </dev/urandom | head -c32)
    cat >"$CONFIG_FILE" <<EOF
# EasyTier 配置文件
machine_id:$MACHINE_ID

# 本地网络（必须配置）
proxy:192.168.1.0/24

# 节点配置（可添加多个）
node tcp://public.easytier.cn:11010
node udp://another.node.example.com:12010
EOF
    log "已创建配置文件: $CONFIG_FILE"
fi

# 读取机器ID
MACHINE_ID=$(grep '^machine_id:' "$CONFIG_FILE" | cut -d: -f2)

# 读取本地网络配置
LOCAL_NETWORK=$(grep '^proxy:' "$CONFIG_FILE" | head -n1 | cut -d: -f2- | sed 's/#.*//; s/ //g')
if [ -z "$LOCAL_NETWORK" ]; then
    die "配置文件中缺少 proxy: 配置项（格式：proxy:192.168.1.0/24）"
fi

# 验证本地网络格式
if ! echo "$LOCAL_NETWORK" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'; then
    die "本地网络格式错误: $LOCAL_NETWORK (应为 CIDR 格式，如 192.168.1.0/24)"
fi

# 读取节点配置
PEER_PARAMS=""
while IFS= read -r line; do
    case "$line" in
        node\ *)
            peer="${line#node }"
            PEER_PARAMS="$PEER_PARAMS --peers \"$peer\""
            log "添加节点: $peer"
            ;;
    esac
done < "$CONFIG_FILE"

if [ -z "$PEER_PARAMS" ]; then
    log "警告: 配置文件中未定义任何节点"
fi

# ---------- 自动检测架构 ----------
detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l|armv6l) echo "arm" ;;
        mips)    echo "mips" ;;
        mipsel)  echo "mipsel" ;;
        *)       die "无法识别的架构: $(uname -m)" ;;
    esac
}
[ -z "$ARCH" ] && ARCH=$(detect_arch)

# ---------- 下载 URL ----------
case "$ARCH" in
    amd64) ZIP_NAME="easytier-linux-x86_64-v${ZIP_VER}.zip" ;;
    arm64) ZIP_NAME="easytier-linux-aarch64-v${ZIP_VER}.zip" ;;
    arm)   ZIP_NAME="easytier-linux-arm-v${ZIP_VER}.zip" ;;
    mipsel)ZIP_NAME="easytier-linux-mipsel-v${ZIP_VER}.zip" ;;
    mips)  ZIP_NAME="easytier-linux-mips-v${ZIP_VER}.zip" ;;
    *)     die "不支持的架构: $ARCH" ;;
esac
ZIP_URL="https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/v${ZIP_VER}/${ZIP_NAME}"

# ---------- 开启 IPv4 转发 ----------
echo 1 > /proc/sys/net/ipv4/ip_forward

# ---------- 防火墙：网对网专用规则 ----------
NFT_INC="/usr/share/nftables.d/ruleset-post/99-easytier.nft"
mkdir -p "$(dirname "$NFT_INC")"

# 生成网对网专用防火墙规则
cat >"$NFT_INC.tmp" <<EOF
table inet fw4 {
    chain forward {
        # 允许转发本地网络流量
        ip saddr $LOCAL_NETWORK accept
        ip daddr $LOCAL_NETWORK accept
        
        # 允许通过虚拟接口的流量
        iifname "$PROXY_DEV" accept
        oifname "$PROXY_DEV" accept
    }
    
    chain postrouting {
        # 对从虚拟接口出去的流量进行 NAT
        oifname "$PROXY_DEV" masquerade
    }
}
EOF

# 应用规则（仅当有变化时）
if ! cmp -s "$NFT_INC.tmp" "$NFT_INC" 2>/dev/null; then
    mv "$NFT_INC.tmp" "$NFT_INC"
    log "应用网对网防火墙规则"
    /etc/init.d/firewall reload >/dev/null 2>&1 || log "防火墙重载失败（不影响运行）"
else
    rm -f "$NFT_INC.tmp"
    log "防火墙规则未变化"
fi

# ---------- 已运行检查 ----------
if pidof easytier-core >/dev/null; then
    log "EasyTier 已在运行"
    exit 0
fi

# ---------- 下载 & 解压 ----------
EASYTIER_BIN="$EASYTIER_DIR/easytier-core"
EASYTIER_CLI="$EASYTIER_DIR/easytier-cli"
if [ ! -x "$EASYTIER_BIN" ]; then
    mkdir -p "$EASYTIER_DIR"
    cd "$EASYTIER_DIR"
    log "下载 EasyTier: $ZIP_NAME"
    
    if command -v curl >/dev/null; then
        curl -fL "$ZIP_URL" -o "$ZIP_NAME" || die "下载失败"
    elif command -v wget >/dev/null; then
        wget -q "$ZIP_URL" -O "$ZIP_NAME" || die "下载失败"
    else
        die "需要 curl 或 wget"
    fi
    
    # 解压并扁平化目录结构
    unzip -o -j "$ZIP_NAME" '*/easytier-core' '*/easytier-cli' -d . >/dev/null
    rm -f "$ZIP_NAME"
    chmod +x easytier-core easytier-cli 2>/dev/null
    
    [ ! -x "$EASYTIER_BIN" ] && die "解压后找不到可执行文件"
fi

# ---------- 启动 EasyTier（网对网模式） ----------
log "启动 EasyTier 网对网模式: $NETWORK_NAME"
CMD="$EASYTIER_BIN -d \
  --network-name \"$NETWORK_NAME\" \
  --network-secret \"$NETWORK_SECRET\" \
  --hostname \"$USERNAME\" \
  --machine-id \"$MACHINE_ID\" \
  -n \"$LOCAL_NETWORK\" \
  $PEER_PARAMS"

log "启动命令: $CMD"
eval "$CMD" >/dev/null 2>&1 &

# 等待启动
sleep 5
if "$EASYTIER_CLI" node; then
    log "节点状态:"
    "$EASYTIER_CLI" list
    log "EasyTier 网对网模式启动成功"
else
    log "节点状态获取失败，请检查日志"
    exit 1
fi