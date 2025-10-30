#!/bin/sh

# ==============================================
# 网络切换脚本 - 增强版（含接口状态验证和兜底机制）
# ==============================================

# 强制设置完整的环境变量
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
export HOME="/root"
export USER="root"
export LOGNAME="root"
export SHELL="/bin/sh"

# 设置umask
umask 0022

# 切换到根目录，确保路径一致
cd /tmp

# ==============================================
# 配置区域 - 在这里修改测试IP和其他配置
# ==============================================

# 网络连通性测试目标（可修改）
PING_TARGETS="8.8.8.8 1.1.1.1 223.5.5.5 114.114.114.114"

# 接口配置（根据实际情况调整）
WAN_INTERFACE="wan"
WWAN_INTERFACE="wwan"

# 路由metric值（数值越小优先级越高）
WAN_METRIC="10"
WWAN_METRIC="20"

# 测试参数
PING_COUNT="3"
PING_TIMEOUT="3"
SWITCH_WAIT_TIME="3"

# 日志和状态文件
SCRIPT_NAME="network-switcher-fixed"
LOCK_FILE="/var/lock/network-switcher-fixed.lock"
LOG_FILE="/var/log/network-switcher-fixed.log"
STATE_FILE="/var/state/network-switcher-fixed.state"
DEBUG_LOG="/tmp/network-switcher-debug.log"

# ==============================================
# 初始化部分
# ==============================================

# 创建必要的目录
mkdir -p /var/lock /var/log /var/state

# 初始化调试日志
echo "=== 脚本开始执行 ===" > $DEBUG_LOG
echo "时间: $(date)" >> $DEBUG_LOG
echo "用户: $(whoami 2>/dev/null || echo '未知')" >> $DEBUG_LOG
echo "PID: $$" >> $DEBUG_LOG
echo "参数: $@" >> $DEBUG_LOG
echo "PATH: $PATH" >> $DEBUG_LOG

# 验证关键命令
for cmd in ubus ip ping nslookup logger; do
    if command -v $cmd >/dev/null 2>&1; then
        echo "✓ $cmd: $(command -v $cmd)" >> $DEBUG_LOG
    else
        echo "✗ $cmd: 未找到" >> $DEBUG_LOG
    fi
done

# ==============================================
# 函数定义部分
# ==============================================

# 日志函数
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 写入文件日志
    echo "[$timestamp] $message" >> "$LOG_FILE"
    
    # 写入系统日志
    logger -t "$SCRIPT_NAME" "$message" 2>/dev/null
    
    # 写入调试日志
    echo "[$timestamp] $message" >> $DEBUG_LOG
}

# 锁定函数
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && [ -d "/proc/$lock_pid" ]; then
            log "另一个实例正在运行 (PID: $lock_pid)，退出"
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# 获取接口状态
get_interface_status() {
    local interface="$1"
    if ubus call network.interface."$interface" status >/dev/null 2>&1; then
        ubus call network.interface."$interface" status | jsonfilter -e '@.up' 2>/dev/null || echo "false"
    else
        echo "false"
    fi
}

# 增强的获取接口IP地址函数
get_interface_ip() {
    local interface="$1"
    local device=""
    
    # 方法1: 通过ubus获取
    local ip=$(ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.ipv4-address[0].address' 2>/dev/null)
    
    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi
    
    # 方法2: 通过设备名从ip命令获取
    device=$(get_interface_device "$interface")
    if [ -n "$device" ]; then
        ip=$(ip addr show dev "$device" 2>/dev/null | grep -o 'inet [0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | awk '{print $2}' | head -1)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    fi
    
    # 方法3: 通过路由表推断
    local gateway=$(get_interface_gateway "$interface")
    if [ -n "$gateway" ]; then
        # 如果有网关，说明接口应该有IP，返回一个占位符
        echo "动态获取"
        return 0
    fi
    
    echo ""
}

# 修复的接口可用性检查
is_interface_available() {
    local interface="$1"
    local device=""
    
    # 获取设备名
    device=$(get_interface_device "$interface")
    if [ -z "$device" ]; then
        log "接口 $interface 没有对应的设备"
        return 1
    fi
    
    # 检查设备是否存在且是UP状态
    if ! ip link show "$device" 2>/dev/null | grep -q "state UP"; then
        log "设备 $device 不是UP状态"
        return 1
    fi
    
    # 检查是否有默认路由指向这个设备（或者接口有网关）
    local gateway=$(get_interface_gateway "$interface")
    if [ -z "$gateway" ]; then
        log "接口 $interface 没有网关"
        return 1
    fi
    
    # 检查路由表中是否有到这个设备的路由
    if ip route show | grep -q "dev $device"; then
        log "✓ 接口 $interface 可用 (设备$device UP, 有网关$gateway, 有路由)"
        return 0
    else
        log "接口 $interface 没有相关路由"
        return 1
    fi
}

# 获取接口的网关
get_interface_gateway() {
    local interface="$1"
    ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null
}

# 获取接口的设备名
get_interface_device() {
    local interface="$1"
    ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null
}

# 获取当前默认路由的接口
get_current_default_interface() {
    ip route show default 2>/dev/null | head -1 | awk '{print $5}'
}

# 修复的网络连通性测试
test_network_connectivity() {
    local interface="$1"
    local device=""
    
    # 获取接口对应的设备名
    device=$(get_interface_device "$interface")
    if [ -z "$device" ]; then
        log "无法获取接口 $interface 的设备名"
        return 1
    fi
    
    log "测试接口 $interface (设备: $device) 的网络连通性"
    
    local success_count=0
    local test_targets="$PING_TARGETS"
    
    for target in $test_targets; do
        log "尝试ping $target 通过 $device..."
        if ping -I "$device" -c $PING_COUNT -W $PING_TIMEOUT "$target" >/dev/null 2>&1; then
            log "✓ 通过 $interface($device) 成功ping通 $target"
            success_count=$((success_count + 1))
            break  # 只要有一个成功就认为网络正常
        else
            log "✗ 通过 $interface($device) 无法ping通 $target"
        fi
    done
    
    if [ "$success_count" -ge 1 ]; then
        log "✓ 接口 $interface 网络连通性正常"
        return 0
    else
        log "✗ 接口 $interface 网络连通性异常"
        return 1
    fi
}

# 修复的切换网络接口函数（增加接口状态验证）
switch_interface() {
    local target_interface="$1"
    local current_interface=$(get_current_default_interface)
    
    log "当前默认接口: $current_interface, 目标接口: $target_interface"
    
    # 验证目标接口是否可用
    if ! is_interface_available "$target_interface"; then
        log "✗ 拒绝切换：目标接口 $target_interface 不可用（状态为DOWN或无IP地址）"
        echo "错误: 目标接口 $target_interface 不可用"
        return 1
    fi
    
    # 如果已经是目标接口，检查网络是否正常
    local target_device=$(get_interface_device "$target_interface")
    if [ "$current_interface" = "$target_device" ] && [ -n "$target_device" ]; then
        if test_network_connectivity "$target_interface"; then
            log "已经是$target_interface接口且网络正常，无需切换"
            echo "✓ 已经是$target_interface接口且网络正常"
            return 0
        else
            log "虽然是$target_interface接口但网络异常，继续切换流程"
        fi
    fi
    
    log "开始切换网络接口到: $target_interface"
    
    # 动态获取网关和设备名，而不是硬编码
    local gateway device
    if [ "$target_interface" = "$WAN_INTERFACE" ]; then
        # 获取WAN接口的网关和设备
        gateway=$(get_interface_gateway "$WAN_INTERFACE")
        device=$(get_interface_device "$WAN_INTERFACE")
        if [ -z "$gateway" ] || [ -z "$device" ]; then
            log "错误: 无法获取WAN接口的网关或设备信息"
            return 1
        fi
        log "切换到WAN接口 - 网关: $gateway, 设备: $device"
        
        # 删除WWAN的默认路由，添加WAN的默认路由
        ip route del default via $(get_interface_gateway "$WWAN_INTERFACE") dev $(get_interface_device "$WWAN_INTERFACE") metric $WWAN_METRIC 2>/dev/null
        ip route replace default via "$gateway" dev "$device" metric $WAN_METRIC
        echo "✓ 已切换到WAN接口"
    else
        # 获取WWAN接口的网关和设备
        gateway=$(get_interface_gateway "$WWAN_INTERFACE")
        device=$(get_interface_device "$WWAN_INTERFACE")
        if [ -z "$gateway" ] || [ -z "$device" ]; then
            log "错误: 无法获取WWAN接口的网关或设备信息"
            return 1
        fi
        log "切换到WWAN接口 - 网关: $gateway, 设备: $device"
        
        # 删除WAN的默认路由，添加WWAN的默认路由
        ip route del default via $(get_interface_gateway "$WAN_INTERFACE") dev $(get_interface_device "$WAN_INTERFACE") metric $WAN_METRIC 2>/dev/null
        ip route replace default via "$gateway" dev "$device" metric $WWAN_METRIC
        echo "✓ 已切换到WWAN接口"
    fi
    
    # 等待路由表更新
    log "等待路由表更新..."
    sleep $SWITCH_WAIT_TIME
    
    # 更严格的验证：不仅要检查路由，还要验证网络连通性
    local new_interface=$(get_current_default_interface)
    log "切换后默认接口: $new_interface"
    
    # 验证路由切换成功
    local route_success=false
    local target_device=$(get_interface_device "$target_interface")
    if [ "$new_interface" = "$target_device" ]; then
        route_success=true
    fi
    
    if [ "$route_success" = "true" ]; then
        log "路由切换成功，验证网络连通性..."
        # 验证网络连通性
        if test_network_connectivity "$target_interface"; then
            log "✓ 切换到 $target_interface 成功且网络正常"
            # 保存状态
            echo "$target_interface" > "$STATE_FILE"
            return 0
        else
            log "⚠ 路由切换成功但网络不通，尝试回退"
            # 回退到原来的接口
            if [ "$target_interface" = "$WWAN_INTERFACE" ]; then
                switch_interface "$WAN_INTERFACE"
            else
                switch_interface "$WWAN_INTERFACE"
            fi
            return 1
        fi
    else
        log "✗ 路由切换失败"
        return 1
    fi
}

# 兜底函数：确保至少有一个可用的默认路由
ensure_fallback_route() {
    log "执行兜底路由检查"
    
    local current_interface=$(get_current_default_interface)
    local wan_available=$(is_interface_available "$WAN_INTERFACE" && echo "true" || echo "false")
    local wwan_available=$(is_interface_available "$WWAN_INTERFACE" && echo "true" || echo "false")
    
    log "当前接口: $current_interface, WAN可用: $wan_available, WWAN可用: $wwan_available"
    
    # 检查当前是否有默认路由
    if [ -z "$current_interface" ]; then
        log "⚠ 没有默认路由，尝试恢复"
        
        # 优先尝试WAN
        if [ "$wan_available" = "true" ]; then
            log "尝试恢复WAN默认路由"
            local wan_gateway=$(get_interface_gateway "$WAN_INTERFACE")
            local wan_device=$(get_interface_device "$WAN_INTERFACE")
            if [ -n "$wan_gateway" ] && [ -n "$wan_device" ]; then
                ip route replace default via "$wan_gateway" dev "$wan_device" metric $WAN_METRIC
                log "✓ 已恢复WAN默认路由"
                echo "$WAN_INTERFACE" > "$STATE_FILE"
                return 0
            fi
        fi
        
        # 其次尝试WWAN
        if [ "$wwan_available" = "true" ]; then
            log "尝试恢复WWAN默认路由"
            local wwan_gateway=$(get_interface_gateway "$WWAN_INTERFACE")
            local wwan_device=$(get_interface_device "$WWAN_INTERFACE")
            if [ -n "$wwan_gateway" ] && [ -n "$wwan_device" ]; then
                ip route replace default via "$wwan_gateway" dev "$wwan_device" metric $WWAN_METRIC
                log "✓ 已恢复WWAN默认路由"
                echo "$WWAN_INTERFACE" > "$STATE_FILE"
                return 0
            fi
        fi
        
        log "✗ 无法恢复任何默认路由"
        return 1
    fi
    
    # 如果当前接口不可用，但另一个接口可用，则切换
    local current_logical_interface=""
    local wan_device=$(get_interface_device "$WAN_INTERFACE")
    local wwan_device=$(get_interface_device "$WWAN_INTERFACE")
    
    if [ "$current_interface" = "$wan_device" ]; then
        current_logical_interface="$WAN_INTERFACE"
    elif [ "$current_interface" = "$wwan_device" ]; then
        current_logical_interface="$WWAN_INTERFACE"
    fi
    
    if [ -n "$current_logical_interface" ] && ! is_interface_available "$current_logical_interface"; then
        log "⚠ 当前接口 $current_logical_interface 不可用，尝试切换到备用接口"
        
        if [ "$current_logical_interface" = "$WAN_INTERFACE" ] && [ "$wwan_available" = "true" ]; then
            switch_interface "$WWAN_INTERFACE"
        elif [ "$current_logical_interface" = "$WWAN_INTERFACE" ] && [ "$wan_available" = "true" ]; then
            switch_interface "$WAN_INTERFACE"
        else
            log "✗ 没有可用的备用接口"
        fi
    fi
    
    return 0
}

# 修复的自动故障检测和切换（增加兜底机制）
auto_switch() {
    log "开始自动网络检测"
    
    # 先执行兜底检查
    ensure_fallback_route
    
    local current_interface=$(get_current_default_interface)
    log "当前默认接口: $current_interface"
    
    # 确定当前使用的是哪个逻辑接口
    local current_logical_interface=""
    local wan_device=$(get_interface_device "$WAN_INTERFACE")
    local wwan_device=$(get_interface_device "$WWAN_INTERFACE")
    
    if [ "$current_interface" = "$wan_device" ]; then
        current_logical_interface="$WAN_INTERFACE"
    elif [ "$current_interface" = "$wwan_device" ]; then
        current_logical_interface="$WWAN_INTERFACE"
    else
        log "未知的当前接口: $current_interface"
        # 尝试从状态文件读取
        if [ -f "$STATE_FILE" ]; then
            current_logical_interface=$(cat "$STATE_FILE")
            log "从状态文件恢复当前接口: $current_logical_interface"
        else
            current_logical_interface="$WAN_INTERFACE"  # 默认假设
        fi
    fi
    
    log "当前逻辑接口: $current_logical_interface"
    
    # 检查当前接口是否可用
    if ! is_interface_available "$current_logical_interface"; then
        log "✗ 当前接口 $current_logical_interface 不可用，强制切换到备用接口"
        current_logical_interface=""  # 标记为需要强制切换
    fi
    
    # 如果当前接口可用，测试网络连通性
    if [ -n "$current_logical_interface" ] && test_network_connectivity "$current_logical_interface"; then
        log "✓ $current_logical_interface 接口网络正常"
        return 0
    else
        log "✗ $current_logical_interface 接口网络异常或不可用，尝试切换到备用接口"
        
        # 确定备用接口
        local backup_interface
        if [ "$current_logical_interface" = "$WAN_INTERFACE" ] || [ -z "$current_logical_interface" ]; then
            backup_interface="$WWAN_INTERFACE"
        else
            backup_interface="$WAN_INTERFACE"
        fi
        
        log "准备切换到备用接口: $backup_interface"
        
        # 检查备用接口是否可用
        if is_interface_available "$backup_interface"; then
            log "备用接口 $backup_interface 状态正常，开始切换"
            if switch_interface "$backup_interface"; then
                log "✓ 自动切换到 $backup_interface 成功"
                return 0
            else
                log "✗ 自动切换到 $backup_interface 失败"
                # 切换失败时再次执行兜底检查
                ensure_fallback_route
                return 1
            fi
        else
            log "✗ 备用接口 $backup_interface 不可用，无法切换"
            # 两个接口都不可用时，确保至少有一个默认路由
            ensure_fallback_route
            return 1
        fi
    fi
}

# 显示状态
show_status() {
    echo "=== 网络状态报告 ==="
    
    # 显示当前默认路由
    local default_interface=$(get_current_default_interface)
    echo "当前默认出口: $default_interface"
    
    # 显示各接口状态
    for interface in "$WAN_INTERFACE" "$WWAN_INTERFACE"; do
        echo -e "\n--- $interface 状态 ---"
        local status=$(get_interface_status "$interface")
        local ip=$(get_interface_ip "$interface")
        local device=$(get_interface_device "$interface")
        local gateway=$(get_interface_gateway "$interface")
        local available=$(is_interface_available "$interface" && echo "✓ 可用" || echo "✗ 不可用")
        
        echo "接口状态: $status"
        echo "可用性: $available"
        echo "IP地址: $ip"
        echo "设备名: $device"
        echo "网关: $gateway"
        
        # 如果接口可用，测试连通性
        if is_interface_available "$interface"; then
            echo -n "网络连通性: "
            if test_network_connectivity "$interface"; then
                echo "✓ 正常"
            else
                echo "✗ 异常"
            fi
        fi
    done
    
    # 显示路由表
    echo -e "\n--- 路由表摘要 ---"
    ip route show | grep -E "(default|dev $(get_interface_device "$WAN_INTERFACE")|dev $(get_interface_device "$WWAN_INTERFACE"))" | head -10
    
    # 显示兜底状态
    echo -e "\n--- 兜底状态 ---"
    if [ -f "$STATE_FILE" ]; then
        echo "保存的状态: $(cat "$STATE_FILE")"
    else
        echo "保存的状态: 无"
    fi
}

# 测试函数
test_connectivity() {
    echo "=== 网络连通性测试 ==="
    show_status
    echo -e "\n=== 详细连通性测试 ==="
    
    for interface in "$WAN_INTERFACE" "$WWAN_INTERFACE"; do
        echo -e "\n测试 $interface:"
        if is_interface_available "$interface"; then
            echo "✓ $interface 接口可用"
            if test_network_connectivity "$interface"; then
                echo "✓ $interface 网络正常"
            else
                echo "✗ $interface 网络异常"
            fi
        else
            echo "✗ $interface 接口不可用"
        fi
    done
    
    echo -e "\n=== 兜底机制测试 ==="
    ensure_fallback_route
}

# 显示帮助信息
show_help() {
    echo "增强版OpenWrt网络出口切换脚本（含接口状态验证和兜底机制）"
    echo ""
    echo "用法: $0 [命令]"
    echo ""
    echo "命令:"
    echo "  auto        - 自动检测并切换网络 (用于cron定时任务)"
    echo "  status      - 显示当前网络状态"
    echo "  switch wan  - 手动切换到WAN接口"
    echo "  switch wwan - 手动切换到WWAN接口"
    echo "  test        - 测试网络连通性"
    echo "  help        - 显示此帮助信息"
    echo ""
    echo "配置说明:"
    echo "  测试IP: $PING_TARGETS"
    echo "  WAN接口: $WAN_INTERFACE, Metric: $WAN_METRIC"
    echo "  WWAN接口: $WWAN_INTERFACE, Metric: $WWAN_METRIC"
    echo ""
    echo "增强功能:"
    echo "  - 接口状态验证：拒绝切换到DOWN状态的接口"
    echo "  - 兜底机制：确保网络恢复后路由正常"
    echo "  - 状态保存：记录当前的网络选择"
    echo ""
    echo "示例:"
    echo "  $0 auto              # 自动故障切换"
    echo "  $0 status            # 显示状态"
    echo "  $0 switch wan        # 切换到WAN"
    echo "  $0 switch wwan       # 切换到WWAN"
}

# ==============================================
# 主函数
# ==============================================

main() {
    # 记录脚本开始
    log "=== 脚本启动 ==="
    log "命令: $0 $@"
    
    acquire_lock
    trap release_lock EXIT
    
    case "$1" in
        auto)
            log "执行自动切换模式"
            auto_switch
            ;;
        status)
            log "执行状态检查"
            show_status
            ;;
        switch)
            case "$2" in
                wan)
                    log "手动切换到WAN"
                    switch_interface "$WAN_INTERFACE"
                    ;;
                wwan)
                    log "手动切换到WWAN"
                    switch_interface "$WWAN_INTERFACE"
                    ;;
                *)
                    echo "错误: 请指定要切换的接口 (wan 或 wwan)"
                    echo "用法: $0 switch [wan|wwan]"
                    exit 1
                    ;;
            esac
            ;;
        test)
            log "执行连通性测试"
            test_connectivity
            ;;
        help|--help|-h)
            show_help
            ;;
        "")
            echo "错误: 需要指定命令"
            show_help
            exit 1
            ;;
        *)
            echo "错误: 未知命令 '$1'"
            echo "使用 '$0 help' 查看帮助信息"
            exit 1
            ;;
    esac
    
    local result=$?
    log "脚本执行完成，退出码: $result"
    return $result
}

# 执行主函数
main "$@"
