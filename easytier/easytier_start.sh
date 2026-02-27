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
############################################################
# EasyTier Supervisor (Embedded Friendly Edition)
# - Auto arch detect
# - Multi-source download fallback
# - Move binaries out of subdir
# - Binary self-check (file/ldd best-effort)
# - Peer health check
# - Restart cooldown
############################################################
ARCH="mipsel" #arm arm64 x86_64 mipsel mips     # Default to mipsel for embedded devices
VERSION="v2.3.2"
PROXY_DEV="${PROXY_DEV:-tun0}"
USERNAME="${HOSTNAME:-}"
RESTART_COOLDOWN=60
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

EASYTIER_DIR="$SCRIPT_DIR/easytier"
EASYTIER_TXT="$SCRIPT_DIR/easytier.txt"
EASYTIER_BIN="$EASYTIER_DIR/easytier-core"
EASYTIER_CLI_BIN="$EASYTIER_DIR/easytier-cli"
PID_FILE="$EASYTIER_DIR/easytier-core.pid"
RESTART_TS_FILE="$EASYTIER_DIR/last_restart.ts"

LOG_TAG="[easytier]"

log() {
    logger -t "$LOG_TAG" "$1" 2>/dev/null || echo "$LOG_TAG $1"
}

usage() {
    echo "Usage: $0 <network-name> <network-secret>"
}

ensure_args() {
    [ $# -lt 2 ] && usage && exit 1
}



############################################################
# Process
############################################################
get_running_pid() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && echo "$PID" && return
    fi

    PID=$(pidof easytier-core 2>/dev/null | awk '{print $1}')
    [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && echo "$PID" && return

    echo ""
}

kill_process() {
    [ -n "$1" ] && kill "$1" 2>/dev/null && sleep 1
}

############################################################
# Restart control
############################################################
restart_allowed() {
    NOW=$(date +%s)

    [ ! -f "$RESTART_TS_FILE" ] && return 0

    LAST=$(cat "$RESTART_TS_FILE" 2>/dev/null)
    [ -z "$LAST" ] && return 0

    DIFF=$((NOW - LAST))
    [ "$DIFF" -lt "$RESTART_COOLDOWN" ] && \
        log "Cooldown active (${DIFF}s < ${RESTART_COOLDOWN}s)" && return 1

    return 0
}

record_restart() {
    date +%s > "$RESTART_TS_FILE"
}

############################################################
# Peer health
############################################################
extract_peer_ips() {

    "$EASYTIER_CLI_BIN" peer 2>/dev/null \
    | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | sort -u
}
read_txt_config() {

    MACHINE_ID=""
    PROXY_NET=""
    PEER_ARGS=""

    [ ! -f "$EASYTIER_TXT" ] && return

    while IFS= read -r line; do

        case "$line" in

            machine_id:*)
                MACHINE_ID="${line#machine_id:}"
            ;;

            proxy:*)
                PROXY_NET="${line#proxy:}"
            ;;

            node\ *)
                NODE_URL="${line#node }"
                PEER_ARGS="$PEER_ARGS --peers $NODE_URL"
            ;;

        esac

    done < "$EASYTIER_TXT"
}
check_peers_alive() {

    [ ! -x "$EASYTIER_CLI_BIN" ] && return 1

    PEERS=$(extract_peer_ips)
    [ -z "$PEERS" ] && log "No peer detected" && return 1

    for ip in $PEERS; do
        if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            log "Peer reachable: $ip"
            return 0
        fi
    done

    log "All peers unreachable"
    return 1
}

############################################################
# Binary validation
############################################################
validate_binary() {

    [ ! -f "$EASYTIER_BIN" ] && return 1

    if command -v file >/dev/null 2>&1; then
        file "$EASYTIER_BIN" | grep -qi "ELF" || {
            log "Binary not ELF"
            return 1
        }
    fi

    if command -v ldd >/dev/null 2>&1; then
        ldd "$EASYTIER_BIN" >/dev/null 2>&1 || \
            log "Warning: ldd check failed (may be static)"
    fi

    chmod +x "$EASYTIER_BIN" "$EASYTIER_CLI_BIN" 2>/dev/null
    return 0
}

############################################################
# Download & ensure
############################################################
download_with_fallback() {

    ZIP="easytier-linux-$ARCH-$VERSION.zip"
    DIR="easytier-linux-$ARCH"

    URLS="
https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/$VERSION/$ZIP
https://github.com/EasyTier/EasyTier/releases/download/$VERSION/$ZIP
"

    for URL in $URLS; do
        log "Downloading from $URL"
        wget -O "$ZIP" "$URL" && return 0
        log "Failed: $URL"
    done

    return 1
}

ensure_binary() {

    if validate_binary; then
        return
    fi

    mkdir -p "$EASYTIER_DIR"
    cd "$EASYTIER_DIR" || exit 1

    download_with_fallback || {
        log "All download sources failed"
        exit 1
    }

    unzip -o "easytier-linux-$ARCH-$VERSION.zip" || exit 1

    DIR="easytier-linux-$ARCH"

    if [ -d "$DIR" ]; then
        log "Moving binaries from $DIR"
        mv "$DIR"/easytier-core .
        mv "$DIR"/easytier-cli .
        rm -rf "$DIR"
    fi

    validate_binary || {
        log "Binary validation failed"
        exit 1
    }

    cd - >/dev/null 2>&1
}

############################################################
# Network
############################################################
setup_forwarding_rules() {
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

    iptables -C INPUT -i "$PROXY_DEV" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -i "$PROXY_DEV" -j ACCEPT

    iptables -C FORWARD -i "$PROXY_DEV" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i "$PROXY_DEV" -j ACCEPT

    iptables -t nat -C POSTROUTING -o "$PROXY_DEV" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -I POSTROUTING -o "$PROXY_DEV" -j MASQUERADE
}

############################################################
# Start
############################################################
start_easytier() {

    log "Starting easytier-core"

    read_txt_config

    CMD="$EASYTIER_BIN -d \
        --network-name $NETWORK_NAME \
        --network-secret $NETWORK_SECRET \
        --hostname $USERNAME"

    [ -n "$MACHINE_ID" ] && CMD="$CMD --machine-id $MACHINE_ID"

    [ -n "$PROXY_NET" ] && CMD="$CMD -n $PROXY_NET"

    [ -n "$PEER_ARGS" ] && CMD="$CMD $PEER_ARGS"

    log "Exec: $CMD"

    eval "$CMD &"

    PID=$!
    echo "$PID" > "$PID_FILE"
}

restart_easytier() {

    restart_allowed || return

    OLD_PID=$(get_running_pid)
    kill_process "$OLD_PID"

    start_easytier
    record_restart
}

############################################################
# MAIN
############################################################
ensure_args "$@"
NETWORK_NAME="$1"
NETWORK_SECRET="$2"

[ -z "$USERNAME" ] && USERNAME="$NETWORK_NAME"
setup_forwarding_rules
ensure_binary

RUNNING_PID=$(get_running_pid)

if [ -z "$RUNNING_PID" ]; then
    log "Not running, starting..."
    start_easytier
    exit 0
fi

log "Running (pid=$RUNNING_PID), checking health..."

if check_peers_alive; then
    log "Healthy"
    exit 0
fi

log "Unhealthy, restarting..."
restart_easytier

exit 0
