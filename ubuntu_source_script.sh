#!/bin/bash

# 配置常量
BACKUP_DIR="/etc/apt"
BACKUP_PREFIX="sources.list.bak."
SYSTEM_NAME="Ubuntu 24.04 LTS"
SYSTEM_VERSION="noble"
SOURCES_FILE="/etc/apt/sources.list"
# 镜像源列表 - 在此添加新源会自动在菜单中生成选项
MIRRORS=(
    "http://archive.ubuntu.com/ubuntu/|官方源"
    "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|清华源"
    "http://mirrors.aliyun.com/ubuntu/|阿里源"
    "http://mirrors.tencent.com/ubuntu/|腾讯源"
    # 示例：添加新源只需在这里增加一行
    # "https://mirrors.ustc.edu.cn/ubuntu/|中科大源"
)
# 网络连通性判断阈值(毫秒)
CONNECTIVITY_THRESHOLD=300

# 检查并获取sudo权限
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo "需要管理员权限，即将请求sudo密码..."
        if ! sudo -v; then
            echo "错误：获取sudo权限失败，请确保当前用户有sudo权限" >&2
            exit 1
        fi
    fi
}

# 查看当前源配置
view_current_sources() {
    echo -e "\n=== 当前软件源配置（$SOURCES_FILE） ==="
    if [ -f "$SOURCES_FILE" ]; then
        sudo cat "$SOURCES_FILE" | grep -v '^#\|^$' || {
            echo "（配置文件为空或仅包含注释）"
        }
        echo -e "\n注：仅显示非注释和非空行，完整内容请查看 $SOURCES_FILE"
    else
        echo "错误：源配置文件 $SOURCES_FILE 不存在"
    fi
}

# 检查镜像源网络连通性并返回延迟(毫秒)，返回-1表示不可达
check_mirror_connectivity() {
    local mirror_url="$1"
    # 提取域名部分（去除协议和路径）
    local host=$(echo "$mirror_url" | sed -E 's/^https?:\/\/([^/]+).*/\1/')
    
    echo -n "正在检查与 $host 的网络连通性..." >&2
    # 使用ping命令测试连通性并获取平均延迟
    local ping_result
    ping_result=$(ping -c 3 -W 1 "$host" 2>/dev/null | awk '/rtt/ {print $4}' | cut -d '/' -f 2)
    
    if [ -z "$ping_result" ]; then
        echo " 不可达" >&2
        echo "-1"  # 不可达
    else
        echo " 平均延迟: ${ping_result}ms" >&2
        echo "$ping_result"  # 返回平均延迟
    fi
}

# 自动选择最快的源
select_fastest_mirror() {
    echo -e "\n=== 正在测试所有镜像源的网络速度 ===" >&2
    local fastest_mirror=""
    local fastest_name=""
    local fastest_latency=999999  # 初始化为一个很大的值
    
    for mirror in "${MIRRORS[@]}"; do
        # 分割镜像URL和名称
        local url=$(echo "$mirror" | cut -d '|' -f 1)
        local name=$(echo "$mirror" | cut -d '|' -f 2)
        
        # 获取延迟
        local latency
        latency=$(check_mirror_connectivity "$url") 
        
        # 只考虑可达的镜像源
        if [ "$latency" != "-1" ] && [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            # 比较延迟，找到最快的
            if (( $(echo "$latency < $fastest_latency" | bc -l) )); then
                fastest_latency="$latency"
                fastest_mirror="$url"
                fastest_name="$name"
            fi
        fi
    done
    
    if [ -z "$fastest_mirror" ]; then
        echo -e "\n错误：所有镜像源均不可达，请检查网络连接" >&2
        return 1
    fi
    
    echo -e "\n最快的镜像源是: $fastest_name (平均延迟: ${fastest_latency}ms)" >&2
    echo "$fastest_mirror|$fastest_name"  # 返回最快源的URL和名称
    return 0
}

# 切换到指定源（通用函数）
switch_to_mirror() {
    local mirror_url="$1"
    local mirror_name="$2"
    
    # 检查连通性
    local latency
    latency=$(check_mirror_connectivity "$mirror_url")
    # 检查是否可达
    if [ "$latency" = "-1" ]; then
        read -p "该镜像源完全不可达，是否仍要强制切换? (Y/n) " confirm
        # 回车默认y
        if [ -z "$confirm" ] || [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            :  # 继续执行切换
        else
            echo "已取消切换到$mirror_name"
            return 1
        fi
    # 检查延迟是否过高
    elif (( $(echo "$latency > $CONNECTIVITY_THRESHOLD" | bc -l) )); then
        read -p "$mirror_name 连通性不佳（延迟 ${latency}ms），是否仍要切换? (Y/n) " confirm
        # 回车默认y
        if [ -z "$confirm" ] || [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            :  # 继续执行切换
        else
            echo "已取消切换到$mirror_name"
            return 1
        fi
    fi
        
    return 0
}

# 备份当前源配置
backup_sources() {
    local suffix="${1:-$(date +%Y-%m-%d_%H:%M:%S)}"
    local backup_file="${BACKUP_DIR}/${BACKUP_PREFIX}${suffix}"
    if [ -f "$SOURCES_FILE" ]; then
        sudo cp "$SOURCES_FILE" "$backup_file" && {
            echo "已备份当前源配置到: $backup_file"
        } || {
            echo "备份操作失败"
        }
    fi
}

# 写入源配置通用函数
write_source_config() {
    local mirror_url="$1"
    sudo tee "$SOURCES_FILE" << EOF > /dev/null
# Ubuntu $SYSTEM_VERSION 软件源 - $mirror_url
deb ${mirror_url} ${SYSTEM_VERSION} main restricted universe multiverse
deb ${mirror_url} ${SYSTEM_VERSION}-updates main restricted universe multiverse
deb ${mirror_url} ${SYSTEM_VERSION}-backports main restricted universe multiverse
deb ${mirror_url} ${SYSTEM_VERSION}-security main restricted universe multiverse

# 源码源 (可选，默认注释)
# deb-src ${mirror_url} ${SYSTEM_VERSION} main restricted universe multiverse
# deb-src ${mirror_url} ${SYSTEM_VERSION}-updates main restricted universe multiverse
# deb-src ${mirror_url} ${SYSTEM_VERSION}-backports main restricted universe multiverse
# deb-src ${mirror_url} ${SYSTEM_VERSION}-security main restricted universe multiverse
EOF
}

# 更新源缓存
update_cache() {
    echo "正在更新软件源缓存..."
    if sudo apt update -y; then
        echo "源缓存更新完成！"
    else
        echo "源缓存更新失败，请检查网络或源配置"
    fi
}

# 系统升级
system_upgrade_prompt() {
    echo -e "\n=== 系统升级提示 ==="
    echo "1. 此操作将升级系统中所有可更新的软件包"
    echo "2. 可能需要大量网络流量，耗时取决于网络速度"
    read -p "是否继续执行系统升级? (Y/n) " confirm
    # 回车默认y
    if [ -z "$confirm" ] || [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        echo "开始系统升级..."
        if sudo apt upgrade -y; then
            echo "系统升级完成！"
        else
            echo "系统升级过程中出现错误"
        fi    
    else
        echo "已取消系统升级操作"
        echo "您可以稍后手动运行 'sudo apt upgrade' 来升级系统"
    fi
}

# 显示主菜单并处理选择
main() {
    while true; do
        clear
        echo "======================================"
        echo "        Ubuntu 软件源管理工具"
        echo "        适用于 $SYSTEM_NAME"
        echo "======================================"
        # 固定选项：查看当前源
        echo "1. 查看当前软件源配置"
        # 固定选项：自动选择最快源
        echo "2. 自动选择最快的源"
        
        # 动态生成镜像源选项
        local mirror_index=3  # 镜像源选项从3开始
        for mirror in "${MIRRORS[@]}"; do
            local name=$(echo "$mirror" | cut -d '|' -f 2)
            local url=$(echo "$mirror" | cut -d '|' -f 1)
            local host=$(echo "$url" | sed -E 's/^https?:\/\/([^/]+).*/\1/')
            echo "${mirror_index}. 切换到$name (${host})"
            ((mirror_index++))
        done
        
        # 固定选项：备份管理
        echo "${mirror_index}. 备份管理（查看/恢复/删除）"
        # 固定选项：退出
        echo "0. 退出程序"
        echo "======================================"
        read -p "请输入选项 (0-${mirror_index}，直接回车退出): " choice

        # 直接回车退出程序
        [ -z "$choice" ] && { echo "退出程序..."; exit 0; }

        check_sudo

        # 处理固定选项
        if [ "$choice" -eq 1 ]; then
            view_current_sources
        elif [ "$choice" -eq 2 ]; then
            echo "您选择了自动选择最快的源"
            local fastest_mirror
            fastest_mirror=$(select_fastest_mirror)

            echo "测试结果: $fastest_mirror"
            
            if [ -n "$fastest_mirror" ]; then
                local url=$(echo "$fastest_mirror" | cut -d '|' -f 1)
                local name=$(echo "$fastest_mirror" | cut -d '|' -f 2)
                
                read -p "是否切换到最快的 $name? (Y/n) " confirm
                # 回车默认y
                if [ -z "$confirm" ] || [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    backup_sources
                    write_source_config "$url"
                    update_cache
                    system_upgrade_prompt
                else
                    echo "已取消切换到最快源"
                fi
            fi
        elif [ "$choice" -eq 0 ]; then
            echo "退出程序..."
            exit 0
        elif [ "$choice" -eq "$mirror_index" ]; then
            backup_submenu
            continue
        else
            # 处理动态镜像源选项
            local mirror_choice=$((choice - 3))  # 计算在MIRRORS中的索引
            if [ "$mirror_choice" -ge 0 ] && [ "$mirror_choice" -lt "${#MIRRORS[@]}" ]; then
                local mirror="${MIRRORS[$mirror_choice]}"
                local url=$(echo "$mirror" | cut -d '|' -f 1)
                local name=$(echo "$mirror" | cut -d '|' -f 2)
                
                echo "您选择了切换到$name"
                if switch_to_mirror "$url" "$name"; then
                    backup_sources
                    write_source_config "$url"
                    update_cache
                    system_upgrade_prompt
                fi
            else
                echo "无效选项，请输入 0-${mirror_index} 之间的数字"
            fi
        fi

        echo -e "\n按任意键返回主菜单..."
        read -n 1
    done
}

# ================备份子菜单======================

# 列出所有备份文件
list_backups() {
    echo -e "\n=== 已存在的源配置备份 ==="
    local backups
    backups=$(sudo find "$BACKUP_DIR" -maxdepth 1 -type f -name "${BACKUP_PREFIX}*" | sort -r)
    
    if [ -z "$backups" ]; then
        echo "未找到任何备份文件"
        return
    fi
    
    local index=1
    while IFS= read -r backup; do
        local timestamp=$(basename "$backup" | sed "s/${BACKUP_PREFIX}//")
        local size=$(sudo du -h "$backup" | awk '{print $1}')
        echo "${index}. 时间: ${timestamp}  大小: ${size}  路径: ${backup}"
        ((index++))
    done <<< "$backups"
}

# 恢复指定备份
restore_backup() {
    list_backups
    local backups
    backups=$(sudo find "$BACKUP_DIR" -maxdepth 1 -type f -name "${BACKUP_PREFIX}*" | sort -r)
    
    [ -z "$backups" ] && { echo "没有可恢复的备份文件"; return; }
    
    read -p "请输入要恢复的备份编号: " num
    
    local backup_array=()
    while IFS= read -r backup; do
        backup_array+=("$backup")
    done <<< "$backups"
    
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#backup_array[@]}" ]; then
        echo "无效的编号"
        return
    fi
    
    local selected_backup="${backup_array[$((num - 1))]}"
    echo "即将恢复备份: $selected_backup"
    read -p "恢复会覆盖当前源配置，是否继续? (Y/n) " confirm
    # 回车默认y
    if [ -z "$confirm" ] || [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        sudo cp "$selected_backup" "$SOURCES_FILE" && {
            echo "备份恢复成功！"
            update_cache
        } || {
            echo "恢复操作失败"
        }
        system_upgrade_prompt
    else
        echo "已取消恢复操作"
    fi
}

# 删除指定备份
delete_backup() {
    list_backups
    local backups
    backups=$(sudo find "$BACKUP_DIR" -maxdepth 1 -type f -name "${BACKUP_PREFIX}*" | sort -r)
    
    [ -z "$backups" ] && { echo "没有可删除的备份文件"; return; }
    
    read -p "请输入要删除的备份编号（输入 0 删除所有备份）: " num
    
    # 处理删除单个备份
    local backup_array=()
    while IFS= read -r backup; do
        backup_array+=("$backup")
    done <<< "$backups"
    
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 0 ] || [ "$num" -gt "${#backup_array[@]}" ]; then
        echo "无效的编号"
        return
    fi

     # 处理删除所有备份
    if [ "$num" -eq 0 ]; then
        echo "即将删除所有备份文件，共 $(echo "$backups" | wc -l) 个"
        read -p "此操作不可恢复，是否确认? (Y/n) " confirm
        # 回车默认y
        if [ -z "$confirm" ] || [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            sudo rm "${BACKUP_DIR}/${BACKUP_PREFIX}"* && {
                echo "所有备份已删除"
            } || {
                echo "删除操作失败"
            }
        else
            echo "已取消删除所有备份"
        fi
        return
    fi
    
    local selected_backup="${backup_array[$((num - 1))]}"
    echo "即将删除备份: $selected_backup"
    read -p "删除后无法恢复，是否确认? (Y/n) " confirm
    # 回车默认y
    if [ -z "$confirm" ] || [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        sudo rm "$selected_backup" && {
            echo "备份已删除"
        } || {
            echo "删除操作失败"
        }
    else
        echo "已取消删除操作"
    fi
}

# 备份管理子菜单
backup_submenu() {
    while true; do
        clear
        echo "======================================"
        echo "        备份管理子菜单"
        echo "======================================"
        echo "1. 查看所有源配置备份"
        echo "2. 恢复指定备份"
        echo "3. 删除指定备份"
        echo "0. 返回主菜单"
        echo "======================================"
        read -p "请输入选项 (0-3，直接回车返回主菜单): " choice

        # 直接回车返回主菜单
        [ -z "$choice" ] && { echo "返回主菜单..."; return; }

        case $choice in
            1)
                list_backups
                ;;
            2)
                restore_backup
                ;;
            3)
                delete_backup
                ;;
            0)
                echo "返回主菜单..."
                return
                ;;
            *)
                echo "无效选项，请输入 0-3 之间的数字"
                ;;
        esac

        echo -e "\n按任意键返回备份管理菜单..."
        read -n 1
    done
}

# 启动主菜单
main
