#!/bin/sh

# EasyTier v16 全自动架构自适应启动脚本
# 适用于 Padavan/OpenWrt/老毛子等，节点信息从 easytier.txt 读取。
# 节点格式：node tcp://x.x.x.x:11010
# 新增功能：
# 1. 支持 proxy: 字段，自动加 -n <CIDR> 参数
# 2. 自动为代理网段添加防火墙转发规则（Padavan风格，防止重复添加）
# 3. 自动检测系统架构，支持手动指定
# 4. 注释与说明写入 easytier.txt


# === 日志输出函数 ===
log() {
    logger -t "$LOG_TAG" "$1"
}



USERNAME=""

if [ $# -lt 2 ]; then
    echo "用法: $0 <network-name> <network-secret> [arch]"
    log "  [arch] 可选，留空时自动检测。可选值：mipsel mips amd64 arm64 arm"
    exit 1
fi

NETWORK_NAME="$1"
NETWORK_SECRET="$2"

# 自动检测架构，支持用户手动指定
if [ -n "$3" ]; then
    ARCH="$3"
else
    ARCH_RAW=$(uname -m)
    case "$ARCH_RAW" in
        x86_64)   ARCH="amd64" ;;
        aarch64)  ARCH="arm64" ;;
        armv7*|armv6*|armhf) ARCH="arm" ;;
        mipsel)   ARCH="mipsel" ;;
        mips)     ARCH="mips" ;;
        *)        ARCH="mipsel" ;; # 默认
    esac
fi

if [ -z "$USERNAME" ]; then
    USERNAME="$NETWORK_NAME"
fi

EASYTIER_DIR="/tmp/easytier"
EASYTIER_TXT="./easytier.txt"

# 下载链接适配
case "$ARCH" in
    amd64)   ZIP_NAME="easytier-linux-amd64-v2.3.2.zip" ;;
    arm64)   ZIP_NAME="easytier-linux-arm64-v2.3.2.zip" ;;
    arm)     ZIP_NAME="easytier-linux-arm-v2.3.2.zip" ;;
    mipsel)  ZIP_NAME="easytier-linux-mipsel-v2.3.2.zip" ;;
    mips)    ZIP_NAME="easytier-linux-mips-v2.3.2.zip" ;;
    *)       ZIP_NAME="easytier-linux-$ARCH-v2.3.2.zip" ;;
esac
ZIP_URL="https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/v2.3.2/${ZIP_NAME}"

case "$ARCH" in
    amd64)   ZIP_DIR="easytier-linux-amd64" ;;
    arm64)   ZIP_DIR="easytier-linux-arm64" ;;
    arm)     ZIP_DIR="easytier-linux-arm" ;;
    mipsel)  ZIP_DIR="easytier-linux-mipsel" ;;
    mips)    ZIP_DIR="easytier-linux-mips" ;;
    *)       ZIP_DIR="easytier-linux-$ARCH" ;;
esac

EASYTIER_BIN="$EASYTIER_DIR/easytier-core"

# ---------- 生成/读取 machine_id，并初始化 easytier.txt 默认节点 ----------
if [ ! -f "$EASYTIER_TXT" ]; then
    MACHINE_ID=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c32)
    {
        log "machine_id:$MACHINE_ID"
        log "#若需要代理本地网络，在下面添加（仅一行生效）:"
        log "#proxy:192.168.100.0/24 "
        log "# 可添加更多节点，每行一个，例如："
        log "node tcp://public.easytier.cn:11010"
        

    } > "$EASYTIER_TXT"
fi

# ---------- 读取 machine_id ----------
MACHINE_ID=$(grep '^machine_id:' "$EASYTIER_TXT" | sed 's/^machine_id://')

# ---------- 读取节点列表 ----------
PEER_PARAMS=""
if [ -f "$EASYTIER_TXT" ]; then
    while IFS= read -r line; do
        case "$line" in
            node\ *)
                NODE_URL=${line#node }
                [ -n "$NODE_URL" ] && PEER_PARAMS="$PEER_PARAMS --peers \"$NODE_URL\""
                ;;
        esac
    done < "$EASYTIER_TXT"
fi

# ---------- 检查并读取 proxy: 配置 ----------
PROXY_NET=""
if [ -f "$EASYTIER_TXT" ]; then
    PROXY_LINE=$(grep '^proxy:' "$EASYTIER_TXT" | head -n1)
    if [ -n "$PROXY_LINE" ]; then
        # 去掉注释部分
        PROXY_NET=$(log "$PROXY_LINE" | sed -e 's/^proxy://' -e 's/[[:space:]]*#.*$//')
        PROXY_NET=$(log "$PROXY_NET" | tr -d ' ')
    fi
fi

if [ -n "$PROXY_NET" ]; then
    PROXY_PARAM="-n $PROXY_NET"
else
    PROXY_PARAM=""
fi

# ---------- Padavan方式开启网关转发 ----------
log 1 > /proc/sys/net/ipv4/ip_forward

# ---------- 自动添加防火墙转发规则，避免重复 ----------
if [ -n "$PROXY_NET" ]; then
    iptables -C FORWARD -s "$PROXY_NET" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "$PROXY_NET" -j ACCEPT
    iptables -C FORWARD -d "$PROXY_NET" -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "$PROXY_NET" -j ACCEPT
    log "已放行 $PROXY_NET 的FORWARD转发"
fi

# 检查并添加 INPUT 规则
iptables -C INPUT -i tun0 -j ACCEPT 2>/dev/null
if [ $? -ne 0 ]; then
    iptables -A INPUT -i tun0 -j ACCEPT
    log "已添加: iptables -A INPUT -i tun0 -j ACCEPT"
else
    log "规则已存在: iptables -A INPUT -i tun0 -j ACCEPT"
fi

# 检查并添加 FORWARD 规则
iptables -C FORWARD -i tun0 -j ACCEPT 2>/dev/null
if [ $? -ne 0 ]; then
    iptables -A FORWARD -i tun0 -j ACCEPT
    log "已添加: iptables -A FORWARD -i tun0 -j ACCEPT"
else
    log "规则已存在: iptables -A FORWARD -i tun0 -j ACCEPT"
fi





# ---------- 检查服务是否已运行 ----------
if pidof easytier-core > /dev/null 2>&1; then
    log "EasyTier 服务已经运行。"
    echo "EasyTier 服务已经运行。"
    exit 0
fi

# ---------- 下载与解压 EasyTier ----------
if [ ! -x "$EASYTIER_BIN" ]; then
    mkdir -p "$EASYTIER_DIR"
    cd "$EASYTIER_DIR"
    log "正在下载 EasyTier 二进制文件: $ZIP_URL"
    wget -O "$ZIP_NAME" "$ZIP_URL"
    if [ $? -ne 0 ]; then
        log "下载失败，请检查网络连接或下载地址。"
        exit 1
    fi

    log "正在解压..."
    unzip -o "$ZIP_NAME"
    if [ -d "$ZIP_DIR" ]; then
        mv "$ZIP_DIR"/* ./
        rmdir "$ZIP_DIR"
    fi
    chmod +x easytier-core 2>/dev/null
    cd - > /dev/null
fi

CMD="$EASYTIER_BIN -d --network-name \"$NETWORK_NAME\" --network-secret \"$NETWORK_SECRET\" --hostname \"$USERNAME\" --machine-id \"$MACHINE_ID\" $PEER_PARAMS $PROXY_PARAM"

log "启动命令："
log $CMD

eval $CMD

exit $?
