#!/bin/sh

# ==============================================
# 网络切换脚本 - 智能版（Auto优先WAN，Switch按指定）
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

    echo "$message"
    
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

# 获取接口IP地址
get_interface_ip() {
    local interface="$1"
    local ip=$(ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.ipv4-address[0].address' 2>/dev/null)
    echo "$ip"
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

# 检查接口是否适合切换（状态+连通性）
is_interface_ready_for_switch() {
    local interface="$1"
    
    log "检查接口 $interface 是否适合切换"
    
    # 检查基本可用性
    if ! is_interface_available "$interface"; then
        log "✗ 接口 $interface 基本状态不可用"
        return 1
    fi
    
    # 检查网络连通性
    if ! test_network_connectivity "$interface"; then
        log "✗ 接口 $interface 网络连通性测试失败"
        return 1
    fi
    
    log "✓ 接口 $interface 适合切换"
    return 0
}

# 执行实际的路由切换
perform_route_switch() {
    local target_interface="$1"
    local gateway=""
    local device=""
    
    log "执行路由切换到: $target_interface"
    
    if [ "$target_interface" = "$WAN_INTERFACE" ]; then
        # 切换到WAN
        gateway=$(get_interface_gateway "$WAN_INTERFACE")
        device=$(get_interface_device "$WAN_INTERFACE")
        
        if [ -z "$gateway" ] || [ -z "$device" ]; then
            log "错误: 无法获取WAN接口的网关或设备信息"
            return 1
        fi
        
        log "设置WAN默认路由 - 网关: $gateway, 设备: $device, 优先级: $WAN_METRIC"
        
        # 删除WWAN的默认路由，添加WAN的默认路由
        ip route del default via $(get_interface_gateway "$WWAN_INTERFACE") dev $(get_interface_device "$WWAN_INTERFACE") metric $WWAN_METRIC 2>/dev/null
        ip route replace default via "$gateway" dev "$device" metric $WAN_METRIC
        
    else
        # 切换到WWAN
        gateway=$(get_interface_gateway "$WWAN_INTERFACE")
        device=$(get_interface_device "$WWAN_INTERFACE")
        
        if [ -z "$gateway" ] || [ -z "$device" ]; then
            log "错误: 无法获取WWAN接口的网关或设备信息"
            return 1
        fi
        
        log "设置WWAN默认路由 - 网关: $gateway, 设备: $device, 优先级: $WWAN_METRIC"
        
        # 删除WAN的默认路由，添加WWAN的默认路由
        ip route del default via $(get_interface_gateway "$WAN_INTERFACE") dev $(get_interface_device "$WAN_INTERFACE") metric $WAN_METRIC 2>/dev/null
        ip route replace default via "$gateway" dev "$device" metric $WWAN_METRIC
    fi
    
    # 等待路由表更新
    log "等待路由表更新..."
    sleep $SWITCH_WAIT_TIME
    
    return 0
}

# 验证切换结果
verify_switch() {
    local target_interface="$1"
    local expected_device=""
    
    log "验证切换到 $target_interface 的结果"
    
    # 获取目标接口的设备名
    expected_device=$(get_interface_device "$target_interface")
    if [ -z "$expected_device" ]; then
        log "无法获取目标接口的设备名"
        return 1
    fi
    
    # 检查当前默认路由是否指向目标设备
    local current_interface=$(get_current_default_interface)
    if [ "$current_interface" != "$expected_device" ]; then
        log "切换验证失败: 当前接口 $current_interface ≠ 目标接口 $expected_device"
        return 1
    fi
    
    log "✓ 路由切换验证成功"
    
    # 验证网络连通性
    if test_network_connectivity "$target_interface"; then
        log "✓ 网络连通性验证成功"
        return 0
    else
        log "✗ 网络连通性验证失败"
        return 1
    fi
}

# 回滚到指定接口
rollback_to_interface() {
    local target_interface="$1"
    local reason="$2"
    
    log "执行回滚到 $target_interface，原因: $reason"
    
    # 检查回滚目标是否可用
    if ! is_interface_ready_for_switch "$target_interface"; then
        log "✗ 回滚目标 $target_interface 不可用，无法回滚"
        return 1
    fi
    
    # 执行回滚
    if perform_route_switch "$target_interface" && verify_switch "$target_interface"; then
        log "✓ 回滚到 $target_interface 成功"
        echo "$target_interface" > "$STATE_FILE"
        return 0
    else
        log "✗ 回滚到 $target_interface 失败"
        return 1
    fi
}

# 增强的切换网络接口函数（预检查+验证+回滚）
switch_interface() {
    local target_interface="$1"
    local current_interface=$(get_current_default_interface)
    local current_logical_interface=""
    
    log "开始切换流程: 目标接口 = $target_interface"
    
    # 确定当前逻辑接口
    local wan_device=$(get_interface_device "$WAN_INTERFACE")
    local wwan_device=$(get_interface_device "$WWAN_INTERFACE")
    
    if [ "$current_interface" = "$wan_device" ]; then
        current_logical_interface="$WAN_INTERFACE"
    elif [ "$current_interface" = "$wwan_device" ]; then
        current_logical_interface="$WWAN_INTERFACE"
    fi
    
    log "当前接口: $current_interface ($current_logical_interface)"
    
    # 如果已经是目标接口，检查网络状态
    if [ "$current_logical_interface" = "$target_interface" ]; then
        if test_network_connectivity "$target_interface"; then
            log "已经是目标接口 $target_interface 且网络正常，无需切换"
            echo "✓ 已经是目标接口且网络正常"
            return 0
        else
            log "虽然是目标接口但网络异常，继续切换流程"
        fi
    fi
    
    # ========== 预检查阶段 ==========
    log "=== 预检查阶段 ==="
    
    # 检查目标接口是否适合切换
    if ! is_interface_ready_for_switch "$target_interface"; then
        log "✗ 切换失败: 目标接口 $target_interface 不适合切换"
        echo "错误: 目标接口 $target_interface 不可用或网络异常"
        return 1
    fi
    
    log "✓ 预检查通过: 目标接口 $target_interface 状态良好"
    
    # ========== 执行切换阶段 ==========
    log "=== 执行切换阶段 ==="
    
    # 记录切换前的状态（用于回滚）
    local rollback_interface="$current_logical_interface"
    
    # 执行路由切换
    if ! perform_route_switch "$target_interface"; then
        log "✗ 路由切换执行失败"
        return 1
    fi
    
    # ========== 验证阶段 ==========
    log "=== 验证阶段 ==="
    
    if verify_switch "$target_interface"; then
        log "✓ 切换到 $target_interface 成功"
        echo "$target_interface" > "$STATE_FILE"
        echo "✓ 切换到 $target_interface 成功"
        return 0
    else
        log "⚠ 切换验证失败，执行回滚"
        
        # ========== 回滚阶段 ==========
        if [ -n "$rollback_interface" ] && [ "$rollback_interface" != "$target_interface" ]; then
            if rollback_to_interface "$rollback_interface" "切换验证失败"; then
                echo "⚠ 切换到 $target_interface 失败，已回滚到 $rollback_interface"
                return 1
            else
                log "✗ 回滚失败，尝试切换到另一个可用接口"
                # 尝试另一个接口作为兜底
                local fallback_interface=""
                if [ "$target_interface" = "$WAN_INTERFACE" ]; then
                    fallback_interface="$WWAN_INTERFACE"
                else
                    fallback_interface="$WAN_INTERFACE"
                fi
                
                if is_interface_ready_for_switch "$fallback_interface"; then
                    if perform_route_switch "$fallback_interface" && verify_switch "$fallback_interface"; then
                        log "✓ 兜底切换到 $fallback_interface 成功"
                        echo "$fallback_interface" > "$STATE_FILE"
                        echo "⚠ 切换到 $target_interface 失败，已兜底切换到 $fallback_interface"
                        return 1
                    fi
                fi
            fi
        fi
        
        log "✗ 所有恢复尝试均失败"
        echo "错误: 切换到 $target_interface 失败且无法恢复"
        return 1
    fi
}

# 兜底函数：确保至少有一个可用的默认路由
ensure_fallback_route() {
    log "执行兜底路由检查"
    
    local current_interface=$(get_current_default_interface)
    local wan_ready=$(is_interface_ready_for_switch "$WAN_INTERFACE" && echo "true" || echo "false")
    local wwan_ready=$(is_interface_ready_for_switch "$WWAN_INTERFACE" && echo "true" || echo "false")
    
    log "当前接口: $current_interface, WAN就绪: $wan_ready, WWAN就绪: $wwan_ready"
    
    # 检查当前是否有默认路由
    if [ -z "$current_interface" ]; then
        log "⚠ 没有默认路由，尝试恢复"
        
        # 优先尝试WAN
        if [ "$wan_ready" = "true" ]; then
            log "尝试恢复WAN默认路由"
            if perform_route_switch "$WAN_INTERFACE" && verify_switch "$WAN_INTERFACE"; then
                log "✓ 已恢复WAN默认路由"
                echo "$WAN_INTERFACE" > "$STATE_FILE"
                return 0
            fi
        fi
        
        # 其次尝试WWAN
        if [ "$wwan_ready" = "true" ]; then
            log "尝试恢复WWAN默认路由"
            if perform_route_switch "$WWAN_INTERFACE" && verify_switch "$WWAN_INTERFACE"; then
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
    
    if [ -n "$current_logical_interface" ] && ! is_interface_ready_for_switch "$current_logical_interface"; then
        log "⚠ 当前接口 $current_logical_interface 不可用，尝试切换到备用接口"
        
        if [ "$current_logical_interface" = "$WAN_INTERFACE" ] && [ "$wwan_ready" = "true" ]; then
            switch_interface "$WWAN_INTERFACE"
        elif [ "$current_logical_interface" = "$WWAN_INTERFACE" ] && [ "$wan_ready" = "true" ]; then
            switch_interface "$WAN_INTERFACE"
        else
            log "✗ 没有可用的备用接口"
        fi
    fi
    
    return 0
}

# 智能自动切换（WAN优先策略）
auto_switch() {
    log "开始智能自动网络切换 - WAN优先策略"
    
    # 先执行兜底检查
    ensure_fallback_route
    
    local current_interface=$(get_current_default_interface)
    log "当前默认接口: $current_interface"
    
    # 确定当前逻辑接口
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
    
    # 检查各接口状态
    local wan_ready=$(is_interface_ready_for_switch "$WAN_INTERFACE" && echo "true" || echo "false")
    local wwan_ready=$(is_interface_ready_for_switch "$WWAN_INTERFACE" && echo "true" || echo "false")
    
    log "接口就绪状态 - WAN: $wan_ready, WWAN: $wwan_ready"
    
    # ========== WAN优先决策逻辑 ==========
    
    # 情况1: WAN就绪 - 无论当前是什么接口，都优先使用WAN
    if [ "$wan_ready" = "true" ]; then
        if [ "$current_logical_interface" = "$WAN_INTERFACE" ]; then
            if test_network_connectivity "$WAN_INTERFACE"; then
                log "✓ 当前已是WAN接口且网络正常，保持现状"
                return 0
            else
                log "当前是WAN接口但网络异常，重新切换到WAN"
            fi
        fi
        
        log "WAN接口就绪，优先切换到WAN"
        if switch_interface "$WAN_INTERFACE"; then
            log "✓ 自动切换到WAN成功"
            return 0
        else
            log "✗ 自动切换到WAN失败，尝试WWAN"
            # 继续尝试WWAN
        fi
    fi
    
    # 情况2: WWAN就绪 - 当WAN不可用时使用WWAN
    if [ "$wwan_ready" = "true" ]; then
        if [ "$current_logical_interface" = "$WWAN_INTERFACE" ]; then
            if test_network_connectivity "$WWAN_INTERFACE"; then
                log "✓ 当前已是WWAN接口且网络正常，保持现状"
                return 0
            else
                log "当前是WWAN接口但网络异常，重新切换到WWAN"
            fi
        fi
        
        log "WWAN接口就绪，切换到WWAN"
        if switch_interface "$WWAN_INTERFACE"; then
            log "✓ 自动切换到WWAN成功"
            return 0
        else
            log "✗ 自动切换到WWAN失败"
        fi
    fi
    
    # 情况3: 所有接口都不就绪
    log "✗ 所有接口都不就绪，无法自动切换"
    ensure_fallback_route
    return 1
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
        local ready=$(is_interface_ready_for_switch "$interface" && echo "✓ 就绪" || echo "✗ 未就绪")
        
        echo "接口状态: $status"
        echo "基本可用: $available"
        echo "切换就绪: $ready"
        echo "IP地址: $ip"
        echo "设备名: $device"
        echo "网关: $gateway"
    done
    
    # 显示路由表
    echo -e "\n--- 路由表摘要 ---"
    ip route show | grep -E "(default|dev $(get_interface_device "$WAN_INTERFACE")|dev $(get_interface_device "$WWAN_INTERFACE"))" | head -10
    
    # 显示状态
    echo -e "\n--- 系统状态 ---"
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
        echo -n "基本可用性: "
        if is_interface_available "$interface"; then
            echo "✓ 可用"
            echo -n "切换就绪: "
            if is_interface_ready_for_switch "$interface"; then
                echo "✓ 就绪"
            else
                echo "✗ 未就绪"
            fi
        else
            echo "✗ 不可用"
        fi
    done
    
    echo -e "\n=== 兜底机制测试 ==="
    ensure_fallback_route
}

# 显示帮助信息
show_help() {
    echo "智能版OpenWrt网络出口切换脚本"
    echo ""
    echo "用法: $0 [命令]"
    echo ""
    echo "命令:"
    echo "  auto        - 自动检测并切换网络 (WAN优先策略)"
    echo "  status      - 显示当前网络状态"
    echo "  switch wan  - 手动切换到WAN接口"
    echo "  switch wwan - 手动切换到WWAN接口"
    echo "  test        - 测试网络连通性"
    echo "  help        - 显示此帮助信息"
    echo ""
    echo "策略说明:"
    echo "  auto 命令: 始终优先使用WAN接口，只有当WAN不可用时才使用WWAN"
    echo "  switch 命令: 严格按照用户指定的接口切换，不进行优先级判断"
    echo ""
    echo "配置说明:"
    echo "  测试IP: $PING_TARGETS"
    echo "  WAN接口: $WAN_INTERFACE, Metric: $WAN_METRIC (主接口)"
    echo "  WWAN接口: $WWAN_INTERFACE, Metric: $WWAN_METRIC (备用接口)"
    echo ""
    echo "增强功能:"
    echo "  - 预检查机制: 切换前验证目标接口状态"
    echo "  - WAN优先策略: auto命令始终优先WAN"
    echo "  - 手动指定: switch命令按用户指定执行"
    echo "  - 切换后验证: 确保切换后网络正常"
    echo "  - 回滚机制: 切换失败时自动回滚"
    echo ""
    echo "示例:"
    echo "  $0 auto              # 自动切换(WAN优先)"
    echo "  $0 status            # 显示状态"
    echo "  $0 switch wan        # 强制切换到WAN"
    echo "  $0 switch wwan       # 强制切换到WWAN"
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
            log "执行自动切换模式 (WAN优先)"
            auto_switch
            ;;
        status)
            log "执行状态检查"
            show_status
            ;;
        switch)
            case "$2" in
                wan)
                    log "手动切换到WAN (用户指定)"
                    switch_interface "$WAN_INTERFACE"
                    ;;
                wwan)
                    log "手动切换到WWAN (用户指定)"
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
