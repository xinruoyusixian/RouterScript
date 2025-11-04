#!/bin/sh

# ==============================================
# 智能网络切换脚本 - 可配置主接口版
# 支持动态设置主接口，增强灵活性
# ==============================================

# 设置完整的环境变量
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
export SHELL="/bin/sh"
export HOME="/root"
export USER="root"

# 切换到tmp目录确保可写
cd /tmp

# ==============================================
# 可配置参数 - 根据需要修改这些变量
# ==============================================

# 主接口配置（优先使用的接口）
PRIMARY_INTERFACE="wan"    # 修改这里设置主接口
SECONDARY_INTERFACE="wwan" # 修改这里设置备用接口

# 多ping目标提高可靠性
PING_TARGETS="8.8.8.8 1.1.1.1 223.5.5.5"
PING_COUNT=1
PING_TIMEOUT=2
SWITCH_WAIT=2

# ==============================================
# 脚本核心逻辑 - 以下部分通常不需要修改
# ==============================================

# 状态文件
STATE_FILE="/var/state/network-switcher.state"
LOG_TAG="network-switcher"

# 创建必要目录
mkdir -p /var/state /var/log 2>/dev/null

# 验证命令是否存在
check_command() {
    for cmd in $1; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "错误: 命令 $cmd 不存在" >&2
            return 1
        fi
    done
    return 0
}

# 验证必要命令
if ! check_command "ubus ip ping grep awk head"; then
    echo "错误: 缺少必要命令，请检查系统环境" >&2
    exit 1
fi

# 简洁的日志函数
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 输出到控制台
    echo "[$timestamp] $message"
    
    # 尝试写入系统日志
    if command -v logger >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "$message"
    fi
    
    # 写入文件日志
    echo "[$timestamp] $message" >> "/var/log/${LOG_TAG}.log" 2>/dev/null
}

# 获取接口设备名
get_interface_device() {
    local interface="$1"
    local device=""
    
    # 方法1: 使用ubus (OpenWrt标准方式)
    if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
        device=$(ubus call "network.interface.$interface" status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
    fi
    
    # 方法2: 使用ifstatus命令
    if [ -z "$device" ] && command -v ifstatus >/dev/null 2>&1; then
        device=$(ifstatus "$interface" 2>/dev/null | grep -o '"l3_device":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    
    # 方法3: 从网络配置推断
    if [ -z "$device" ]; then
        case "$interface" in
            wan) device="eth0" ;;   # 常见WAN设备名
            wwan) device="wlan0" ;; # 常见WWAN设备名
            *) device="$interface" ;; # 其他接口使用接口名作为设备名
        esac
    fi
    
    echo "$device"
}

# 获取接口网关
get_interface_gateway() {
    local interface="$1"
    local gateway=""
    
    # 方法1: 使用ubus
    if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
        gateway=$(ubus call "network.interface.$interface" status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
    fi
    
    # 方法2: 使用路由表
    if [ -z "$gateway" ]; then
        local device=$(get_interface_device "$interface")
        if [ -n "$device" ]; then
            gateway=$(ip route show dev "$device" 2>/dev/null | awk '/default via/ {print $3}' | head -1)
        fi
    fi
    
    echo "$gateway"
}

# 多目标网络连通性检查
check_connectivity() {
    local interface="$1"
    local device=$(get_interface_device "$interface")
    
    if [ -z "$device" ]; then
        log "无法获取接口 $interface 的设备名"
        return 1
    fi
    
    # 检查设备状态
    if ! ip link show "$device" 2>/dev/null | grep -q "state UP"; then
        ip link set "$device" up  #尝试启动一次设备
        log "设备 $device 不是UP状态,尝试UP一次"
        return 1
    fi
    # 对每个目标进行ping测试
    for target in $PING_TARGETS; do
        if ping -I "$device" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1; then
            log "✓ $interface ($device)通过 $target 检测正常"
            return 0
        else
            log "✓ $interface ($device)通过 $target 检测失败，尝试重启接口"
            ifdown "$interface"
            sleep 3
            ifup "$interface"
        fi
    done
    
    log "✗ $interface 所有目标检测失败"
    return 1
}

check_interface_basic() {
    local interface=$1
    local device=$(get_interface_device "$interface")
    local gateway

    # 1. 设备名都没配
    [ -z "$device" ] && \
        { log "接口 $interface 没有对应的网络设备"; return 1; }

    # 2. 设备根本不存在（被内核删掉或名字写错）
    if ! ip link show "$device" &>/dev/null; then
        log "设备 $device 不存在 "
        return 1
    fi


    # 4. 设备 UP 但没网关，再尝试一次 DHCP
    gateway=$(get_interface_gateway "$interface")
    if [ -z "$gateway" ]; then
        log "接口 $interface 缺少网关"
        return 1
    fi

    return 0
}

# 执行路由切换
perform_switch() {
    local target_interface="$1"
    local gateway=$(get_interface_gateway "$target_interface")
    local device=$(get_interface_device "$target_interface")
    
    if [ -z "$gateway" ] || [ -z "$device" ]; then
        log "切换失败: 无法获取 $target_interface 的网关或设备"
        return 1
    fi
    
    log "切换到 $target_interface (网关: $gateway, 设备: $device)"
    
    # 删除所有默认路由，添加新路由
    ip route del default 2>/dev/null
    ip route add default via "$gateway" dev "$device"
    
    sleep "$SWITCH_WAIT"
    return 0
}

# 获取当前默认路由接口
get_current_default_interface() {
    ip route show default 2>/dev/null | head -1 | awk '{print $5}'
}

# 确定当前逻辑接口
get_current_logical_interface() {
    local current_device=$(get_current_default_interface)
    local primary_device=$(get_interface_device "$PRIMARY_INTERFACE")
    local secondary_device=$(get_interface_device "$SECONDARY_INTERFACE")
    
    if [ -z "$current_device" ]; then
        echo "unknown"
        return
    fi
    
    if [ "$current_device" = "$primary_device" ]; then
        echo "$PRIMARY_INTERFACE"
    elif [ "$current_device" = "$secondary_device" ]; then
        echo "$SECONDARY_INTERFACE"
    else
        echo "unknown"
    fi
}

# 核心自动切换逻辑
auto_switch() {
    log "开始智能网络切换检查 [主接口: $PRIMARY_INTERFACE, 备用接口: $SECONDARY_INTERFACE]"
    
    local current_interface=$(get_current_logical_interface)
    log "当前接口: $current_interface"
    
    # 情况1: 当前是主接口
    if [ "$current_interface" = "$PRIMARY_INTERFACE" ]; then
        if check_connectivity "$PRIMARY_INTERFACE"; then
            log "✓ 主接口网络正常，保持现状"
            return 0
        else
            log "⚠ 主接口网络异常，检查备用接口"
            if check_interface_basic "$SECONDARY_INTERFACE" && check_connectivity "$SECONDARY_INTERFACE"; then
                log "✓ 备用接口正常，执行切换"
                if perform_switch "$SECONDARY_INTERFACE"; then
                    echo "$SECONDARY_INTERFACE" > "$STATE_FILE"
                    log "✓ 切换到备用接口成功"
                    return 0
                fi
            else
                log "✗ 备用接口也不可用，无法切换"
            fi
        fi
    
    # 情况2: 当前是备用接口  
    elif [ "$current_interface" = "$SECONDARY_INTERFACE" ]; then
        # 先检查备用接口是否正常
        if check_connectivity "$SECONDARY_INTERFACE"; then
            # 主接口优先策略：即使备用接口正常，如果主接口恢复就切回
            if check_interface_basic "$PRIMARY_INTERFACE" && check_connectivity "$PRIMARY_INTERFACE"; then
                log "✓ 主接口已恢复，切回主接口"
                if perform_switch "$PRIMARY_INTERFACE"; then
                    echo "$PRIMARY_INTERFACE" > "$STATE_FILE"
                    log "✓ 切回主接口成功"
                    return 0
                fi
            else
                log "✓ 备用接口正常，保持现状"
                return 0
            fi
        else
            log "⚠ 备用接口异常，检查主接口"
            if check_interface_basic "$PRIMARY_INTERFACE" && check_connectivity "$PRIMARY_INTERFACE"; then
                log "✓ 主接口正常，切换回主接口"
                if perform_switch "$PRIMARY_INTERFACE"; then
                    echo "$PRIMARY_INTERFACE" > "$STATE_FILE"
                    log "✓ 切换到主接口成功"
                    return 0
                fi
            else
                log "✗ 两个接口都不可用"
            fi
        fi
    
    # 情况3: 未知当前接口或无默认路由
    else
        log "⚠ 未知当前接口或无默认路由，尝试恢复"
        # 优先尝试主接口
        if check_interface_basic "$PRIMARY_INTERFACE" && check_connectivity "$PRIMARY_INTERFACE"; then
            if perform_switch "$PRIMARY_INTERFACE"; then
                echo "$PRIMARY_INTERFACE" > "$STATE_FILE"
                log "✓ 恢复主接口默认路由成功"
                return 0
            fi
        fi
        # 其次尝试备用接口
        if check_interface_basic "$SECONDARY_INTERFACE" && check_connectivity "$SECONDARY_INTERFACE"; then
            if perform_switch "$SECONDARY_INTERFACE"; then
                echo "$SECONDARY_INTERFACE" > "$STATE_FILE"
                log "✓ 恢复备用接口默认路由成功"
                return 0
            fi
        fi
        log "✗ 无法恢复任何网络连接"
        return 1
    fi
    
    return 0
}

# 手动切换
manual_switch() {
    local target_interface="$1"
    
    if check_interface_basic "$target_interface" && check_connectivity "$target_interface"; then
        if perform_switch "$target_interface"; then
            echo "$target_interface" > "$STATE_FILE"
            log "✓ 手动切换到 $target_interface 成功"
        else
            log "✗ 手动切换到 $target_interface 失败"
        fi
    else
        log "✗ 目标接口 $target_interface 不可用，接口未切换"
    fi
}

# 显示状态
show_status() {
    echo "=== 网络状态 ==="
    echo "主接口: $PRIMARY_INTERFACE"
    echo "备用接口: $SECONDARY_INTERFACE"
    echo "当前接口: $(get_current_logical_interface)"
    echo "当前设备: $(get_current_default_interface)"
    
    for interface in "$PRIMARY_INTERFACE" "$SECONDARY_INTERFACE"; do
        echo -e "\n--- $interface ---"
        local device=$(get_interface_device "$interface")
        local gateway=$(get_interface_gateway "$interface")
        echo "设备: $device"
        echo "网关: $gateway"
        echo "基本状态: $(check_interface_basic "$interface" >/dev/null 2>&1 && echo '✓' || echo '✗')"
        echo "网络连通: $(check_connectivity "$interface" >/dev/null 2>&1 && echo '✓' || echo '✗')"
    done
}

# 显示帮助
show_help() {
    echo "智能网络切换脚本"
    echo "用法: $0 [auto|status|main|backup|test]"
    echo ""
    echo "命令:"
    echo "  auto             - 自动切换 (主接口优先)"
    echo "  status           - 显示网络状态"
    echo "  main   - 强制切换到主接口"
    echo "  backup - 强制切换到备用接口"
    echo "  test             - 测试所有接口连通性"
    echo ""
    echo "当前配置:"
    echo "  主接口: $PRIMARY_INTERFACE"
    echo "  备用接口: $SECONDARY_INTERFACE"
    echo "  检测目标: $PING_TARGETS"
    echo ""
    echo "修改配置: 编辑脚本前部的 PRIMARY_INTERFACE 和 SECONDARY_INTERFACE 变量"
}

# 测试功能
test_connectivity() {
    echo "=== 网络连通性测试 ==="
    for interface in "$PRIMARY_INTERFACE" "$SECONDARY_INTERFACE"; do
        echo -e "\n测试 $interface:"
        if check_interface_basic "$interface"; then
            echo "✓ 基本状态正常"
            if check_connectivity "$interface"; then
                echo "✓ 网络连通正常"
            else
                echo "✗ 网络连通异常"
            fi
        else
            echo "✗ 基本状态异常,尝试ifup一次 $interface"
            ifup "$interface"
        fi
    done
}

# 主函数
main() {
    case "$1" in
        auto)
            auto_switch
            ;;
        status)
            show_status
            ;;
        main)
            manual_switch "$PRIMARY_INTERFACE"
            ;;
        backup)
            manual_switch "$SECONDARY_INTERFACE"
            ;;
        test)
            test_connectivity
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
