#!/bin/sh

# EasyTier v16 全自动架构自适应启动脚本
# 适用于 Padavan/OpenWrt/老毛子等，节点信息从 easytier.txt 读取。
# 节点格式：node tcp://x.x.x.x:11010
# 新增功能：
# 1. 支持 proxy: 字段，自动加 -n <CIDR> 参数
# 2. 自动为代理网段添加防火墙转发规则（Padavan风格，防止重复添加）
# 3. 自动检测系统架构，支持手动指定
# 4. 注释与说明写入 easytier.txt

#!/bin/sh

# EasyTier start script (idempotent)
# Usage: sh easytier_start.sh <network-name> <network-secret>

ARCH="${ARCH:-mipsel}"
USERNAME="${HOSTNAME:-}"
PROXY_DEV="${PROXY_DEV:-tun0}"
VERSION="v2.3.2"

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

EASYTIER_DIR="./easytier"
EASYTIER_TXT="$SCRIPT_DIR/easytier.txt"
EASYTIER_BIN="$EASYTIER_DIR/easytier-core"
EASYTIER_CLI_BIN="$EASYTIER_DIR/easytier-cli"
PID_FILE="$EASYTIER_DIR/easytier-core.pid"
LOG_TAG="[easytier]"

log() {
    logger -t "$LOG_TAG" "$1" 2>/dev/null || echo "$1"
}

usage() {
    echo "Usage: $0 <network-name> <network-secret>"
}

ensure_args() {
    if [ $# -lt 2 ]; then
        usage
        exit 1
    fi
}

zip_name_by_arch() {
    case "$1" in
        amd64) echo "easytier-linux-amd64-$VERSION.zip" ;;
        arm64) echo "easytier-linux-arm64-$VERSION.zip" ;;
        arm) echo "easytier-linux-arm-$VERSION.zip" ;;
        mipsel) echo "easytier-linux-mipsel-$VERSION.zip" ;;
        mips) echo "easytier-linux-mips-$VERSION.zip" ;;
        *) echo "easytier-linux-$1-$VERSION.zip" ;;
    esac
}

zip_dir_by_arch() {
    case "$1" in
        amd64) echo "easytier-linux-amd64" ;;
        arm64) echo "easytier-linux-arm64" ;;
        arm) echo "easytier-linux-arm" ;;
        mipsel) echo "easytier-linux-mipsel" ;;
        mips) echo "easytier-linux-mips" ;;
        *) echo "easytier-linux-$1" ;;
    esac
}

ensure_txt_exists() {
    if [ -f "$EASYTIER_TXT" ]; then
        return
    fi

    MACHINE_ID=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c32)
    {
        echo "machine_id:$MACHINE_ID"
        echo "# Optional: proxy local subnet"
        echo "#proxy:192.168.100.0/24"
        echo "# One peer per line"
        echo "node tcp://public.easytier.cn:11010"
    } > "$EASYTIER_TXT"
}

read_machine_id() {
    MACHINE_ID=$(grep '^machine_id:' "$EASYTIER_TXT" 2>/dev/null | head -n1 | sed 's/^machine_id://')
    if [ -z "$MACHINE_ID" ]; then
        MACHINE_ID=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c32)
        echo "machine_id:$MACHINE_ID" >> "$EASYTIER_TXT"
    fi
}
read_proxy_net() {
    PROXY_NET=""
    if [ -f "$EASYTIER_TXT" ]; then
        PROXY_LINE=$(grep '^proxy:' "$EASYTIER_TXT" 2>/dev/null | head -n1)
        if [ -n "$PROXY_LINE" ]; then
            PROXY_NET=$(echo "$PROXY_LINE" | sed -e 's/^proxy://' -e 's/[[:space:]]*#.*$//' | tr -d ' ')
        fi
    fi
}

setup_forwarding_rules() {
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

    if [ -n "$PROXY_NET" ]; then
        /bin/iptables -C FORWARD -s "$PROXY_NET" -j ACCEPT 2>/dev/null || /bin/iptables -A FORWARD -s "$PROXY_NET" -j ACCEPT
        /bin/iptables -C FORWARD -d "$PROXY_NET" -j ACCEPT 2>/dev/null || /bin/iptables -A FORWARD -d "$PROXY_NET" -j ACCEPT
    fi

    /bin/iptables -C INPUT -i "$PROXY_DEV" -j ACCEPT 2>/dev/null || /bin/iptables -A INPUT -i "$PROXY_DEV" -j ACCEPT
    /bin/iptables -C FORWARD -i "$PROXY_DEV" -j ACCEPT 2>/dev/null || /bin/iptables -I FORWARD -i "$PROXY_DEV" -j ACCEPT
    /bin/iptables -C FORWARD -o "$PROXY_DEV" -j ACCEPT 2>/dev/null || /bin/iptables -I FORWARD -o "$PROXY_DEV" -j ACCEPT
    /bin/iptables -t nat -C POSTROUTING -o "$PROXY_DEV" -j MASQUERADE 2>/dev/null || /bin/iptables -t nat -I POSTROUTING -o "$PROXY_DEV" -j MASQUERADE
}

show_link_info() {
    if [ ! -x "$EASYTIER_CLI_BIN" ]; then
        return
    fi

    output=$($EASYTIER_CLI_BIN node 2>/dev/null)
    [ -n "$output" ] && echo "$output"
}

get_running_pid() {
    if [ -f "$PID_FILE" ]; then
        PID_FROM_FILE=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$PID_FROM_FILE" ] && kill -0 "$PID_FROM_FILE" 2>/dev/null; then
            echo "$PID_FROM_FILE"
            return
        fi
    fi

    PID_FROM_PIDOF=$(pidof easytier-core 2>/dev/null | awk '{print $1}')
    if [ -n "$PID_FROM_PIDOF" ] && kill -0 "$PID_FROM_PIDOF" 2>/dev/null; then
        echo "$PID_FROM_PIDOF"
        return
    fi

    echo ""
}

ensure_binary() {
    if [ -x "$EASYTIER_BIN" ] && [ -x "$EASYTIER_CLI_BIN" ]; then
        return
    fi

    ZIP_NAME=$(zip_name_by_arch "$ARCH")
    ZIP_DIR=$(zip_dir_by_arch "$ARCH")
    ZIP_URL="https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/$VERSION/$ZIP_NAME"

    mkdir -p "$EASYTIER_DIR"
    cd "$EASYTIER_DIR" || exit 1

    log "Downloading $ZIP_URL"
    wget -O "$ZIP_NAME" "$ZIP_URL" || {
        log "Download failed: $ZIP_URL"
        exit 1
    }

    unzip -o "$ZIP_NAME" || exit 1

    if [ -d "$ZIP_DIR" ]; then
        mv "$ZIP_DIR"/* ./
        rmdir "$ZIP_DIR"
    fi

    chmod +x easytier-core 2>/dev/null || true
    chmod +x easytier-cli 2>/dev/null || true

    cd - >/dev/null 2>&1 || true
}

start_easytier() {
    set -- "$EASYTIER_BIN" -d \
        --network-name "$NETWORK_NAME" \
        --network-secret "$NETWORK_SECRET" \
        --hostname "$USERNAME" \
        --machine-id "$MACHINE_ID"

    if [ -f "$EASYTIER_TXT" ]; then
        while IFS= read -r line; do
            case "$line" in
                ''|\#*)
                    ;;
                node\ *)
                    NODE_URL=${line#node }
                    [ -n "$NODE_URL" ] && set -- "$@" --peers "$NODE_URL"
                    ;;
            esac
        done < "$EASYTIER_TXT"
    fi

    [ -n "$PROXY_NET" ] && set -- "$@" -n "$PROXY_NET"

    "$@" &
    NEW_PID=$!
    echo "$NEW_PID" > "$PID_FILE"
    log "easytier-core started, pid=$NEW_PID"
}

ensure_args "$@"
NETWORK_NAME="$1"
NETWORK_SECRET="$2"

if [ -z "$USERNAME" ]; then
    USERNAME="$NETWORK_NAME"
fi

ensure_txt_exists
read_machine_id
read_proxy_net
setup_forwarding_rules

RUNNING_PID=$(get_running_pid)
if [ -n "$RUNNING_PID" ]; then
    log "easytier-core is already running (pid=$RUNNING_PID), skip starting"
    echo "easytier-core already running: pid=$RUNNING_PID"
    show_link_info
    exit 0
fi

ensure_binary
start_easytier
sleep 2
show_link_info

exit 0

