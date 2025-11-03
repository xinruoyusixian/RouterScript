#!/bin/sh

# ==============================================
# 智能网络切换脚本 - 修复版
# 修复命令找不到问题，增强兼容性
# ==============================================

# 设置完整的环境变量
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
export SHELL="/bin/sh"
export HOME="/root"
export USER="root"

# 切换到tmp目录确保可写
cd /tmp

# 基础配置
WAN_INTERFACE="wan"
WWAN_INTERFACE="wwan"

# 多ping目标提高可靠性
PING_TARGETS="8.8.8.8 1.1.1.1 223.5.5.5"
PING_COUNT=1
PING_TIMEOUT=2
SWITCH_WAIT=2

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

# 获取接口设备名 - 修复版本
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
            wan) device="eth0" ;;  # 常见WAN设备名
            wwan) device="wlan0" ;; # 常见WWAN设备名
        esac
    fi
    
    echo "$device"
}

# 获取接口网关 - 修复版本
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
        log "设备 $device 不是UP状态"
        return 1
    fi
    
    # 对每个目标进行ping测试
    for target in $PING_TARGETS; do
        log "测试 $interface($device) -> $target"
        if ping -I "$device" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1; then
            log "✓ $interface 通过 $target 检测正常"
            return 0
        fi
    done
    
    log "✗ $interface 所有目标检测失败"
    return 1
}

# 检查接口基本状态
check_interface_basic() {
    local interface="$1"
    local device=$(get_interface_device "$interface")
    local gateway=$(get_interface_gateway "$interface")
    
    if [ -z "$device" ]; then
        log "接口 $interface 没有对应的网络设备"
        return 1
    fi
    
    if [ -z "$gateway" ]; then
        log "接口 $interface 没有网关"
        return 1
    fi
    
    if ! ip link show "$device" 2>/dev/null | grep -q "state UP"; then
        log "设备 $device 不是UP状态"
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
    local wan_device=$(get_interface_device "$WAN_INTERFACE")
    local wwan_device=$(get_interface_device "$WWAN_INTERFACE")
    
    if [ -z "$current_device" ]; then
        echo "unknown"
        return
    fi
    
    if [ "$current_device" = "$wan_device" ]; then
        echo "$WAN_INTERFACE"
    elif [ "$current_device" = "$wwan_device" ]; then
        echo "$WWAN_INTERFACE"
    else
        echo "unknown"
    fi
}

# 核心自动切换逻辑
auto_switch() {
    log "开始智能网络切换检查"
    
    local current_interface=$(get_current_logical_interface)
    log "当前接口: $current_interface"
    
    # 情况1: 当前是WAN接口
    if [ "$current_interface" = "$WAN_INTERFACE" ]; then
        if check_connectivity "$WAN_INTERFACE"; then
            log "✓ WAN接口网络正常，保持现状"
            return 0
        else
            log "⚠ WAN接口网络异常，检查WWAN接口"
            if check_interface_basic "$WWAN_INTERFACE" && check_connectivity "$WWAN_INTERFACE"; then
                log "✓ WWAN接口正常，执行切换"
                if perform_switch "$WWAN_INTERFACE"; then
                    echo "$WWAN_INTERFACE" > "$STATE_FILE"
                    log "✓ 切换到WWAN成功"
                    return 0
                fi
            else
                log "✗ WWAN接口也不可用，无法切换"
            fi
        fi
    
    # 情况2: 当前是WWAN接口  
    elif [ "$current_interface" = "$WWAN_INTERFACE" ]; then
        # 先检查WWAN是否正常
        if check_connectivity "$WWAN_INTERFACE"; then
            # WAN优先策略：即使WWAN正常，如果WAN恢复就切回
            if check_interface_basic "$WAN_INTERFACE" && check_connectivity "$WAN_INTERFACE"; then
                log "✓ WAN接口已恢复，切回WAN"
                if perform_switch "$WAN_INTERFACE"; then
                    echo "$WAN_INTERFACE" > "$STATE_FILE"
                    log "✓ 切回WAN成功"
                    return 0
                fi
            else
                log "✓ WWAN接口正常，保持现状"
                return 0
            fi
        else
            log "⚠ WWAN接口异常，检查WAN接口"
            if check_interface_basic "$WAN_INTERFACE" && check_connectivity "$WAN_INTERFACE"; then
                log "✓ WAN接口正常，切换回WAN"
                if perform_switch "$WAN_INTERFACE"; then
                    echo "$WAN_INTERFACE" > "$STATE_FILE"
                    log "✓ 切换到WAN成功"
                    return 0
                fi
            else
                log "✗ 两个接口都不可用"
            fi
        fi
    
    # 情况3: 未知当前接口或无默认路由
    else
        log "⚠ 未知当前接口或无默认路由，尝试恢复"
        # 优先尝试WAN
        if check_interface_basic "$WAN_INTERFACE" && check_connectivity "$WAN_INTERFACE"; then
            if perform_switch "$WAN_INTERFACE"; then
                echo "$WAN_INTERFACE" > "$STATE_FILE"
                log "✓ 恢复WAN默认路由成功"
                return 0
            fi
        fi
        # 其次尝试WWAN
        if check_interface_basic "$WWAN_INTERFACE" && check_connectivity "$WWAN_INTERFACE"; then
            if perform_switch "$WWAN_INTERFACE"; then
                echo "$WWAN_INTERFACE" > "$STATE_FILE"
                log "✓ 恢复WWAN默认路由成功"
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
        log "✗ 目标接口 $target_interface 不可用,接口未切换"
    fi
}

# 显示状态
show_status() {
    echo "=== 网络状态 ==="
    echo "当前接口: $(get_current_logical_interface)"
    echo "当前设备: $(get_current_default_interface)"
    
    for interface in "$WAN_INTERFACE" "$WWAN_INTERFACE"; do
        echo -e "\n--- $interface ---"
        local device=$(get_interface_device "$interface")
        local gateway=$(get_interface_gateway "$interface")
        echo "设备: $device"
        echo "网关: $gateway"
        echo "基本状态: $(check_interface_basic "$interface" && echo '✓' || echo '✗')"
        echo "网络连通: $(check_connectivity "$interface" && echo '✓' || echo '✗')"
    done
}

# 显示帮助
show_help() {
    echo "智能网络切换脚本"
    echo "用法: $0 [auto|status|switch wan|switch wwan|test]"
    echo ""
    echo "命令:"
    echo "  auto        - 自动切换 (WAN优先)"
    echo "  status      - 显示网络状态"
    echo "  switch wan  - 强制切换到WAN"
    echo "  switch wwan - 强制切换到WWAN"
    echo "  test        - 测试所有接口连通性"
    echo ""
    echo "配置:"
    echo "  WAN接口: $WAN_INTERFACE"
    echo "  WWAN接口: $WWAN_INTERFACE"
    echo "  检测目标: $PING_TARGETS"
}

# 测试功能
test_connectivity() {
    echo "=== 网络连通性测试 ==="
    for interface in "$WAN_INTERFACE" "$WWAN_INTERFACE"; do
        echo -e "\n测试 $interface:"
        if check_interface_basic "$interface"; then
            echo "✓ 基本状态正常"
            if check_connectivity "$interface"; then
                echo "✓ 网络连通正常"
            else
                echo "✗ 网络连通异常"
            fi
        else
            echo "✗ 基本状态异常"
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
        switch)
            case "$2" in
                wan) manual_switch "$WAN_INTERFACE" ;;
                wwan) manual_switch "$WWAN_INTERFACE" ;;
                *) echo "错误: 请指定 wan 或 wwan"; exit 1 ;;
            esac
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
