#!/bin/sh

# 修复版OpenWrt网络出口切换脚本

SCRIPT_NAME="network-switcher-fixed"
LOCK_FILE="/var/lock/network-switcher-fixed.lock"
LOG_FILE="/var/log/network-switcher-fixed.log"
STATE_FILE="/var/state/network-switcher-fixed.state"

# 接口配置
WAN_INTERFACE="wan"
WWAN_INTERFACE="wwan"

# 日志函数
log() {
    #echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1"
    logger -t "$SCRIPT_NAME" "$1"
   
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

# 修复的IP地址检测函数
get_interface_ip() {
    local interface="$1"
    local ip=$(ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.ipv4-address[0].address' 2>/dev/null)
    echo "$ip"
}

# 修复的接口状态检测
get_interface_status() {
    local interface="$1"
    if ubus call network.interface."$interface" status >/dev/null 2>&1; then
        ubus call network.interface."$interface" status | jsonfilter -e '@.up'
    else
        echo "false"
    fi
}

# 修复的网络连通性测试
test_network_connectivity() {
    local interface="$1"
    local device=""
    
    # 获取接口对应的设备名
    if [ "$interface" = "$WAN_INTERFACE" ]; then
        device="wan"
    else
        device="phy1-sta0"  # 根据您的配置
    fi
    
    log "测试接口 $interface (设备: $device) 的网络连通性"
    
    local success_count=0
    local test_targets="8.8.8.8 1.1.1.1 223.5.5.5"
    
    for target in $test_targets; do
        if ping -I "$device" -c 2 -W 5 "$target" >/dev/null 2>&1; then
            log "通过 $interface($device) 成功ping通 $target"
            success_count=$((success_count + 1))
            break  # 只要有一个成功就认为网络正常
        else
            log "通过 $interface($device) 无法ping通 $target"
        fi
    done
    
    [ "$success_count" -ge 1 ]
}

# 获取当前默认路由的接口
get_current_default_interface() {
    ip route show default | head -1 | awk '{print $5}'
}

# 切换网络接口
switch_interface() {
    local target_interface="$1"
    local current_interface=$(get_current_default_interface)
    
    log "当前默认接口: $current_interface, 目标接口: $target_interface"
    
    # 如果已经是目标接口，直接返回
    if [ "$current_interface" = "phy1-sta0" ] && [ "$target_interface" = "$WWAN_INTERFACE" ]; then
        log "已经是WWAN接口，无需切换"
        echo "✓ 已经是WWAN接口，无需切换"
        return 0
    elif [ "$current_interface" = "wan" ] && [ "$target_interface" = "$WAN_INTERFACE" ]; then
        log "已经是WAN接口，无需切换"
        echo "✓ 已经是WAN接口，无需切换"
        return 0
    fi
    
    log "开始切换网络接口到: $target_interface"
    
    # 基于路由的切换，而不是重启接口
    if [ "$target_interface" = "$WAN_INTERFACE" ]; then
        # 切换到WAN：删除WWAN的默认路由，确保WAN的路由优先级更高
        log "切换到WAN接口"
        ip route del default via 192.168.0.1 dev phy1-sta0 metric 20 2>/dev/null
        # 添加回WAN的默认路由（如果不存在）
        ip route replace default via 192.168.1.1 dev wan metric 10
        echo "✓ 已切换到WAN接口"
    else
        # 切换到WWAN：删除WAN的默认路由，使用WWAN的路由
        log "切换到WWAN接口"
        ip route del default via 192.168.1.1 dev wan metric 10 2>/dev/null
        # 确保WWAN的默认路由存在
        ip route replace default via 192.168.0.1 dev phy1-sta0 metric 20
        echo "✓ 已切换到WWAN接口"
    fi
    
    # 验证切换结果
    sleep 2
    local new_interface=$(get_current_default_interface)
    log "切换后默认接口: $new_interface"
    
    if [ "$target_interface" = "$WWAN_INTERFACE" ] && [ "$new_interface" = "phy1-sta0" ]; then
        log "切换到WWAN成功"
        return 0
    elif [ "$target_interface" = "$WAN_INTERFACE" ] && [ "$new_interface" = "wan" ]; then
        log "切换到WAN成功"
        return 0
    else
        log "切换验证失败"
        return 1
    fi
}

# 自动故障检测和切换
auto_switch() {
    log "开始自动网络检测"
    
    local current_interface=$(get_current_default_interface)
    log "当前默认接口: $current_interface"
    
    # 测试当前接口的网络连通性
    if [ "$current_interface" = "wan" ]; then
        if test_network_connectivity "$WAN_INTERFACE"; then
            log "WAN接口网络正常"
            return 0
        else
            log "WAN接口网络异常，尝试切换到WWAN"
            if switch_interface "$WWAN_INTERFACE"; then
                log "自动切换到WWAN成功"
            else
                log "自动切换到WWAN失败"
            fi
        fi
    elif [ "$current_interface" = "phy1-sta0" ]; then
        if test_network_connectivity "$WWAN_INTERFACE"; then
            log "WWAN接口网络正常"
            return 0
        else
            log "WWAN接口网络异常，尝试切换到WAN"
            if switch_interface "$WAN_INTERFACE"; then
                log "自动切换到WAN成功"
            else
                log "自动切换到WAN失败"
            fi
        fi
    else
        log "未知的当前接口: $current_interface，尝试切换到WAN"
        switch_interface "$WAN_INTERFACE"
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
        
        if [ "$status" = "true" ]; then
            echo "接口状态: ✓ UP"
            echo "IP地址: $ip"
            
            # 测试连通性
            if test_network_connectivity "$interface"; then
                echo "网络连通性: ✓ 正常"
            else
                echo "网络连通性: ✗ 异常"
            fi
        else
            echo "接口状态: ✗ DOWN"
        fi
    done
    
    # 显示路由表
    echo -e "\n--- 路由表摘要 ---"
    ip route show | grep -E "(default|dev wan|dev phy1-sta0)"
}

# 显示帮助信息
show_help() {
    echo "修复版OpenWrt网络出口切换脚本"
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
    echo "示例:"
    echo "  $0 auto              # 自动故障切换"
    echo "  $0 status            # 显示状态"
    echo "  $0 switch wan        # 切换到WAN"
    echo "  $0 switch wwan       # 切换到WWAN"
}

# 测试函数
test_connectivity() {
    echo "=== 网络连通性测试 ==="
    show_status
}

# 主函数
main() {
    acquire_lock
    trap release_lock EXIT
    
    case "$1" in
        auto)
            auto_switch
            ;;
        status)
            show_status
            ;;
        switch)
            case "$2" in
                wan)
                    switch_interface "$WAN_INTERFACE"
                    ;;
                wwan)
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
            test_connectivity
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo "错误: 未知命令 '$1'"
            echo "使用 '$0 help' 查看帮助信息"
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"