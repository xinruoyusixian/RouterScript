ZEROTIER_ONE="/opt/bin/zerotier-one"
ZEROTIER_CLI="$ZEROTIER_CLI"
LOG_TAG="【Zerotier】"
# === 日志输出函数 ===
log() {
    logger -t "$LOG_TAG" "$1"
}


#环境判断
evnCheck(){

#判断环境是否安装
if ! type /opt/bin/opkg&> /dev/null; then
    log "正在安装环境"
    wget -O  - http://bin.entware.net/mipselsf-k3.4/installer/generic.sh | /bin/sh
fi
#判断环境是否安装
if ! type $ZEROTIER_CLI&> /dev/null; then
    log "正在安装zerotier"
    /opt/bin/opkg  update
    /opt/bin/opkg install zerotier
fi

}


# === 参数检查函数 ===
check_args() {
    if [ -z "$1" ]; then
        echo "用法: $0 <zerotier network id>"
        log "未指定网络ID，退出"
        exit 1
    fi
    ZT_NETWORK_ID="$1"
}

# === 检查并启动 Zerotier-One 守护进程函数 ===
start_zerotier_one() {
    ZT_PID=$(pgrep -f zerotier-one)
    if [ -z "$ZT_PID" ]; then
        log "zerotier-one 未运行，启动 zerotier-one -d"
        if [ ! -x "$ZEROTIER_ONE" ]; then
            log "找不到 zerotier-one 可执行文件: $ZEROTIER_ONE"
            return 1
        fi
        /opt/bin/zerotier-one -d 
        sleep 2
    else
        log "zerotier-one 已在运行 (PID: $ZT_PID)"
    fi
}

# === 加入 Zerotier 网络函数 ===
join_network() {
    if ! $ZEROTIER_CLI listnetworks | grep -q "$ZT_NETWORK_ID"; then
        log "未加入网络，执行 join"
        $ZEROTIER_CLI join "$ZT_NETWORK_ID"
        sleep 2
    else
        log "已加入网络 $ZT_NETWORK_ID,$($ZEROTIER_CLI  info) "
    fi
}

# === 检查 Zerotier ONLINE 状态函数 ===
wait_online() {
    local i
    for i in 1 2 3 4 5; do
        ZT_INFO=$($ZEROTIER_CLI info 2>/dev/null)
        echo "$ZT_INFO" | grep -q "ONLINE" && break
        log "等待 Zerotier ONLINE ($i/5)"
        sleep 2
    done
    echo "$ZT_INFO" | grep -q "ONLINE"
    if [ $? -ne 0 ]; then
        log "Zerotier 状态不在线"
        return 1
    fi
    return 0
}

# === 获取 Zerotier 虚拟网卡名函数 ===
get_zt_interface() {
    ZT_INTERFACE=""
    for iface in $(ifconfig | sed -n 's/^\([a-zA-Z0-9]\{10\}\).*/\1/p'); do
        if echo "$iface" | grep -qvE '^(lo|eth|wlan|tailscale)' && echo "$iface" | grep -qE '^z'; then
            ZT_INTERFACE="$iface"
            break
        fi
    done
    if [ -z "$ZT_INTERFACE" ]; then
        log "未检测到 Zerotier 虚拟网卡"
        return 1
    fi
    log "检测到 Zerotier 虚拟网卡 $ZT_INTERFACE"
    return 0
}
# === iptables 防火墙规则添加函数 ===
add_iptables_rule() {
    # $1: 表（可选，默认为filter），$2: 链，$3: 方向（-i/-o），$4: 网卡名，$5: 动作（如ACCEPT/MASQUERADE），$6: 插入方式（-A/-I，默认-A）
    TABLE_OPT=""
    if [ -n "$1" ] && [ "$1" != "filter" ]; then
        TABLE_OPT="-t $1"
    fi
    CHAIN="$2"
    DIR="$3"
    IFACE="$4"
    ACTION="$5"
    APPEND="${6:--A}"

    if [ "$ACTION" = "MASQUERADE" ]; then
        iptables $TABLE_OPT -C $CHAIN $DIR "$IFACE" -j MASQUERADE 2>/dev/null
        EXIST=$?
    else
        iptables $TABLE_OPT -C $CHAIN $DIR "$IFACE" -j ACCEPT 2>/dev/null
        EXIST=$?
    fi

    if [ $EXIST -ne 0 ]; then
        iptables $TABLE_OPT $APPEND $CHAIN $DIR "$IFACE" -j "$ACTION"
        log "已添加 $CHAIN $DIR $IFACE $ACTION 规则"
    else
        log "$CHAIN $DIR $IFACE $ACTION 规则已存在"
    fi
}

# === 添加所有需要的防火墙规则函数 ===
setup_firewall() {
    add_iptables_rule filter INPUT -i "$ZT_INTERFACE" ACCEPT -A
    add_iptables_rule filter FORWARD -i "$ZT_INTERFACE" ACCEPT -I
    add_iptables_rule filter FORWARD -o "$ZT_INTERFACE" ACCEPT -I
    add_iptables_rule nat POSTROUTING -o "$ZT_INTERFACE" MASQUERADE -I
}

# =========== 主循环函数 ===========
mainloop() {
    check_args "$1"
    while true; do
        evnCheck
        start_zerotier_one
        join_network
        if wait_online; then
            if get_zt_interface; then
                setup_firewall
            fi
        fi
        sleep 60
    done
}

mainloop "$@"
