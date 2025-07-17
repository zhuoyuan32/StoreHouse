#!/bin/bash
#
# Sing-Box & Mihomo 多功能一体化安装与管理脚本 (重构注释最终版)
#

#set -e
#set -o pipefail

readonly COMMON_UTILS_PATH="/usr/local/bin/tools/common.sh"
if [ -f "$COMMON_UTILS_PATH" ]; then
    source "$COMMON_UTILS_PATH"
else
    # 如果找不到依赖库，打印清晰的错误信息并退出。
    echo -e "\033[31m✖ 致命错误: 依赖库缺失: $COMMON_UTILS_PATH\033[0m" >&2
    exit 1
fi

# --- 全局常量定义 ---
# 将不应改变的变量定义为只读常量，增加代码的健壮性。
DIRPATH="/usr/local/bin/tools"
YQ_BIN_PATH="/usr/local/bin/yq"
readonly SUB_HOST="https://sub-singbox.herozmy.com"
readonly SINGBOX_CONFIG_TPL="&file=https://raw.githubusercontent.com/zhuoyuan32/StoreHouse/refs/heads/latest/config/sing-box/sing-box.json"
readonly LOCAL_IP=$(hostname -I | awk '{print $1}')

# --- 主调度器 (脚本入口) ---
main() {
    # 步骤 1: 检查所有必需的系统依赖。
    
    
    # 步骤 2: 根据传入的第一个命令行参数，决定执行哪个任务。
    case "$1" in
        update_core)   task_update_core ;;       # 更新核心
        update_ui)     task_update_ui ;;         # 更新UI面板
        update_home)   task_install_hy2_home ;;   # 更新回家配置 (注意：此处调用主任务函数)
        switch_core)   task_switch_core ;;       # 切换核心
        mihomo)        
            check_proxy_conflict "mihomo"
            task_install_mihomo ;;    # 安装Mihomo
        switch_nft)    setup_nftables && _activate_nftables_rules ;;
        *)             
            check_proxy_conflict "sing-box"
            task_interactive_install ;; # 如果没有参数，默认执行交互式安装
    esac
}

switch_nftables() {
    echo "请选择要应用的 Nftable 模式："
    echo "1) Redirect+Tproxy"
    echo "2) Tproxy"
  #  echo "3) Default_Redirect+Tproxy (使用 nft_tproxy_redirect.conf)"
  #  echo "4) Default_Tproxy (使用 nft_tproxy.conf)"
    echo ""

    local nft_choice
    while true; do
        # 提示用户，并说明默认选项
        read -p "输入选项 [1-2] (回车默认1): " nft_choice
        
        # 检查是否为空（回车）
        if [[ -z "$nft_choice" ]]; then
            nft_choice="1" # 设置默认值为1
            log_info "未输入选项，默认选择 1) Redirect+Tproxy."
        fi

        # 验证输入是否有效 (1-3)
        if [[ "$nft_choice" =~ ^[1-2]$ ]]; then
            break # 有效输入，退出循环
        else
            log_error "无效选项：'$nft_choice'。请输入 1 到 2 之间的数字。"
        fi
    done

    local NFT_CONF_DEST="/etc/nftables.conf"
    local RON_REDIRECT_CONF="/usr/local/bin/tools/ron_tproxy_redirect.conf"
    local RON_TPROXY_CONF="/usr/local/bin/tools/ron_tproxy.conf"
    local DEFAULT_REDIRECT_CONF="/usr/local/bin/tools/nft-tproxy-redirect.conf"
    local DEFAULT_TPROXY_CONF="/usr/local/bin/tools/nft-tproxy.conf" # 尽管注释掉了，但变量保留


    _apply_nftables_config() {
        local source_file="$1"
        local mode_name="$2"

        log_info "选择 $mode_name 模式。正在复制配置文件..."

        if [ ! -f "$source_file" ]; then
            log_error "源配置文件 '$source_file' 不存在。请确认路径是否正确。"
            return 1
        fi

        if ! cp "$source_file" "$NFT_CONF_DEST"; then
            log_error "复制 '$source_file' 到 '$NFT_CONF_DEST' 失败。请检查权限。"
            return 1
        fi
        sleep 1
        log_success "$mode_name 配置已成功配置到 '$NFT_CONF_DEST'。"
        # !!! 移除这里的 _activate_nftables_rules 调用 !!!
        return 0 # 返回复制操作的状态
    }

    case "$nft_choice" in
        1)
            _apply_nftables_config "$RON_REDIRECT_CONF" "Redirect+Tproxy"
            ;;
        2)
            _apply_nftables_config "$RON_TPROXY_CONF" "Tproxy"
            ;;
       # 3)
        #    _apply_nftables_config "$DEFAULT_REDIRECT_CONF" "Default_Redirect"
       #     ;;

        # 4)
        #    _apply_nftables_config "$DEFAULT_TPROXY_CONF" "Default_Tproxy"
        #    ;;
        *)
            # 理论上这里的代码不会被执行到，因为前面已经验证过输入
            log_error "内部错误：无效选项 '$nft_choice'。"
            ;;
    esac
    return $? # 返回 _apply_nftables_config 的状态
}
_activate_nftables_rules() {
    local mode_name="$1"
    local NFT_CONF_DEST="/etc/nftables.conf" # 确保路径一致

    log_info "正在重启 nftables 服务并刷新规则以应用 $mode_name 模式..."

    if ! systemctl restart nftables; then
        log_error "重启 nftables 服务失败。请检查 '$NFT_CONF_DEST' 文件内容及 nftables 服务状态。"
        return 1
    fi
    log_success "nftables 服务已成功重启。"

    log_info "正在通过 nft -f 命令强制加载规则..."
    if ! nft -f "$NFT_CONF_DEST"; then
        log_error "nft -f '$NFT_CONF_DEST' 命令执行失败。可能存在配置语法错误或服务问题。"
        return 1
    fi
    log_success "nft -f '$NFT_CONF_DEST' 命令执行成功。"
    log_success "$mode_name 模式已成功应用。"
    return 0
}
# ==============================================================================
# SECTION: 任务层 (Tasks) -yq
# ==============================================================================
# 任务：安装 yq
task_install_yq(){
    log_info "开始安装 yq..."

    # 1. 检查 wget 是否安装
    if ! command -v wget &>/dev/null; then
        log_info "wget 未安装，正在安装 wget..."
        if apt-get update && apt-get install -y wget; then
            log_success "wget 安装成功。"
        else
            log_error "安装 wget 失败。请手动安装 wget 后重试。"
            return 1 # 返回非零值表示失败
        fi
    fi

    # 2. 检测系统架构
    ARCH=$(uname -m)
    YQ_ARCH=""
    case "$ARCH" in
        x86_64) YQ_ARCH="amd64" ;;
        aarch64) YQ_ARCH="arm64" ;;
        armv7l) YQ_ARCH="arm" ;; # 或 armv7
        *)
            log_error "不支持的系统架构: ${ARCH}。请手动下载适合您架构的 yq。"
            return 1
            ;;
    esac

    YQ_DOWNLOAD_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}"

    log_info "正在从 ${YQ_DOWNLOAD_URL} 下载 yq 到 ${YQ_BIN_PATH}..."
    if wget "${YQ_DOWNLOAD_URL}" -O "${YQ_BIN_PATH}"; then
        log_success "yq 下载成功。"
    else
        log_error "下载 yq 失败。请检查网络连接或 URL 是否正确。"
        return 1
    fi

    log_info "正在为 yq 添加可执行权限..."
    if chmod +x "${YQ_BIN_PATH}"; then
        log_success "yq 已成功设置为可执行。"
    else
        log_error "设置 yq 可执行权限失败。"
        return 1
    fi

    log_success "yq 已成功安装到 ${YQ_BIN_PATH}。"

    # 验证安装
    if command -v yq &>/dev/null; then
        log_success "yq 安装验证成功。版本信息:"
        yq --version
    else
        log_error "yq 安装后未能找到。可能 PATH 环境变量未包含 ${YQ_BIN_PATH}。"
        return 1
    fi
    return 0 # 返回零值表示成功
}

# 任务：安装 Mihomo 的完整流程
task_install_mihomo() {
    log_info "开始 Mihomo 安装..."
    check_dependencies
    # 确保 yq 存在
    log_info "检查是否已安装 yq..."
    if command -v yq &>/dev/null; then
        log_success "yq 已经安装在 $(command -v yq)。"
    else
        # 如果 yq 未安装，则调用安装函数
        if ! task_install_yq; then
            log_error "yq 安装失败，无法继续安装 Mihomo。请检查上述错误信息。"
            exit 1 # yq安装失败，退出整个脚本
        fi
    fi
    
    # 下载并安装 Mihomo 核心文件
    # 确保 detect_architecture 函数可用
    download_and_install_archive "mihomo" "https://github.com/zhuoyuan32/StoreHouse/releases/download/mihomo/mihomo-meta-linux-$(detect_architecture).tar.gz" "/usr/local/bin/mihomo"
    
    # 串联所有安装步骤
    install_mihomo_config
    setup_systemd_services "mihomo"
    
    # 只有在需要时才设置防火墙和tp-router
    if [ "$NEED_FIREWALL_SETUP" = "true" ]; then
        log_info "正在配置IP转发和防火墙规则..."
        task_ip_forward
        setup_nftables "mihomo"
    else
        log_info "跳过防火墙和透明代理设置，复用现有服务..."
    fi
    
    install_dashboard_ui "mihomo"
  #  bash /usr/local/bin/tools/check_aio.sh # 确保这个脚本存在且可执行
    enable_and_start_all_services "mihomo"
    
    # 打印最终的总结信息
    print_summary "Mihomo" "/etc/mihomo" "http://${LOCAL_IP}:9090"
    log_success "Mihomo 定制安装完成！"
    
    # 提示用户关于代理切换的信息
    if command -v sing-box &>/dev/null; then
        log_info "检测到系统中同时安装了 Sing-Box。"
        log_info "您可以使用 'proxytool' 命令在两个代理服务之间切换。"
    fi
}

# 任务：交互式安装 Sing-Box 的完整流程
task_interactive_install() {
    log_info "开始 Sing-Box 交互式安装..."
    sleep 1
    check_dependencies
    rm -rf /root/sing-box* # 清理之前的安装残留

    # === 修改开始 ===
    local core_type=""

    choose_core_type core_type

    # 检查用户是否中途取消了选择
    if [ -z "$core_type" ]; then
        log_info "未选择核心或操作已取消，退出安装。"
        exit 0
    fi
    # === 修改结束 ===

    # 确保 jq 存在
    install_dependencies "jq"
    # 根据用户的选择安装相应的 Sing-Box 核心
    install_singbox_core "$core_type"

    # 根据核心类型确定配置文件类型，以便后续安装
    local config_type 
    case "$core_type" in
        official-compile)          config_type="official" ;;
        official-core)             config_type="official" ;;
        puer)                      config_type="puer" ;;
        xiling)                    config_type="xiling" ;;
        s-y)                       config_type="s-y" ;;
        reF1nd)                    config_type="reF1nd" ;;
    esac
    install_singbox_config "$config_type"
    
    # 串联所有后续安装步骤
    setup_systemd_services "sing-box"
    
    # 只有在需要时才设置防火墙和tp-router
    if [ "$NEED_FIREWALL_SETUP" = "true" ]; then
        log_info "正在配置IP转发和防火墙规则..."
        task_ip_forward
        setup_nftables "sing-box"
    else
        log_info "跳过防火墙和透明代理设置，复用现有服务..."
    fi
    
    install_dashboard_ui "sing-box"
  #  bash /usr/local/bin/tools/check_aio.sh
    enable_and_start_all_services "sing-box"
    
    print_summary "Sing-Box" "/etc/sing-box" "http://${LOCAL_IP}:9095"
    print_service_commands "sing-box"

    # 提示用户关于代理切换的信息
    if command -v mihomo &>/dev/null; then
        log_info "检测到系统中同时安装了 Mihomo。"
        log_info "您可以使用 'proxytool' 命令在两个代理服务之间切换。"
    fi
}

# 任务：更新核心
task_update_core() {
    #systemctl stop nftables &>/dev/null || true
    #systemctl stop tproxy-router &>/dev/null || true
    log_info "开始更新核心程序..."
    if [ ! -f "/etc/sing-box/version" ]; then
        log_error "未检测到 Sing-Box 安装。无法执行更新。"
        exit 1
    fi
    
    local current_core_type
    current_core_type=$(cat /etc/sing-box/version)
    
    log_info "正在备份当前核心..."
    local current_version
    current_version=$(/usr/local/bin/sing-box version | awk '/sing-box version/ {print $3}')
    cp -r /usr/local/bin/sing-box "/usr/local/bin/sing-box-${current_core_type}-${current_version}.bak"
    
    #systemctl stop tproxy-router &>/dev/null || true # 停止路由服务，忽略可能发生的错误
    
    # 重新运行当前核心类型的安装流程，以达到更新的目的
    install_singbox_core "$current_core_type"
    
    log_info "正在重启服务..."
    systemctl restart sing-box &>/dev/null || true
    systemctl restart tproxy-router &>/dev/null || true
    systemctl restart nftables &>/dev/null || true
    log_success "核心更新完成。"
}

# 任务：更新 UI 面板
task_update_ui() {
    log_info "正在更新仪表盘 UI..."
    #systemctl stop tproxy-router &>/dev/null || true
    #systemctl stop nftables &>/dev/null || true
    local core_binary
    # 自动查找当前安装的是 sing-box 还是 mihomo
    core_binary=$(find /usr/local/bin/ -type f \( -name "mihomo" -o -name "sing-box" \))
    
    if [ -z "$core_binary" ]; then
        log_error "未找到 'sing-box' 或 'mihomo' 核心文件。"
        exit 1
    fi
    
    #systemctl stop tproxy-router &>/dev/null || true
    # 根据找到的核心名来更新对应的UI目录
    install_dashboard_ui "$(basename "$core_binary")"
    systemctl restart tproxy-router &>/dev/null || true
    systemctl restart nftables &>/dev/null || true
    log_success "UI 更新完成。"
}

# 任务：切换核心
# 任务：切换核心
task_switch_core() {
    log_info "开始切换核心流程..."
    
    # 检查 sing-box 是否已安装
    if [ ! -f "/etc/sing-box/version" ]; then
        log_error "未检测到 Sing-Box 安装，无法执行核心切换。"
        exit 1
    fi
    
    log_info "正在备份当前核心和配置文件..."
    local current_core_type
    current_core_type=$(cat /etc/sing-box/version)
    local current_version
    current_version=$(/usr/local/bin/sing-box version | awk '/sing-box version/ {print $3}')
    cp -f /usr/local/bin/sing-box "/usr/local/bin/sing-box-${current_core_type}-${current_version}.bak"
    cp -f /etc/sing-box/config.json "/etc/sing-box/config.${current_core_type}.bak"
    
    #systemctl stop tproxy-router &>/dev/null || true
    #systemctl stop nftables &>/dev/null || true
    

    local new_core_type=""
    choose_core_type new_core_type
    
    # 检查用户是否中途取消
    if [ -z "$new_core_type" ]; then
        log_info "未选择核心或操作已取消，退出切换。"
        exit 0
    fi
    # --- 修复结束 ---
    
    # 根据核心类型确定配置文件类型
    local new_config_type
    case "$new_core_type" in
        official-compile|official-core) new_config_type="official" ;;
        *)                              new_config_type="$new_core_type" ;;
    esac
    
    # 安装新的核心和对应的配置
    install_singbox_core "$new_core_type"
    install_singbox_config "$new_config_type" # 使用新的配置类型
    
    log_info "正在重启所有服务以应用新核心..."
    systemctl restart sing-box &>/dev/null || true
    systemctl restart tproxy-router &>/dev/null || true
    systemctl restart nftables &>/dev/null || true
    log_success "核心成功切换为 '$new_core_type'。"
}

# ==============================================================================
# SECTION: 辅助与工具函数 (Helper & Utility Functions)
# ==============================================================================

# 检查所有脚本运行所必需的依赖项
check_dependencies() {
    log_info "正在检查系统依赖项..."
    # 定义所有需要的软件包列表
    # 注意：'go' 依赖通常通过下载 tarball 安装，而不是 apt-get
    # 'gawk' 已经是 GNU awk，在 Debian/Ubuntu 上通常就是 'awk'
    local apt_deps=("curl" "git" "build-essential" "libssl-dev" "libevent-dev" "zlib1g-dev" "nftables" "jq" "unzip")
    local missing_apt_deps=()
    local missing_non_apt_deps=() # 用于非 apt-get 安装的依赖

    # 遍历 apt 依赖列表，检查每个命令是否存在
    for dep in "${apt_deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_apt_deps+=("$dep")
        fi
    done

    # 特殊处理 'go'
    if ! command -v go &>/dev/null; then
        missing_non_apt_deps+=("go")
    fi

    # 如果有缺失的 APT 依赖，尝试自动安装
    if [ ${#missing_apt_deps[@]} -gt 0 ]; then
        log_warn "检测到以下 APT 依赖项缺失: ${missing_apt_deps[*]}。正在尝试自动安装..."
        if ! apt-get update; then
            log_error "apt update 失败，请检查您的软件源或网络连接。"
            exit 1
        fi
        if ! apt-get install -y "${missing_apt_deps[@]}"; then # 移除 >/dev/null 2>&1 以显示错误
            log_error "自动安装依赖 ${missing_apt_deps[*]} 失败！请手动安装或检查错误信息。"
            exit 1
        fi
        log_success "APT 依赖项安装完成。"
    else
        log_success "所有 APT 依赖项均已满足。"
    fi

    # 提示非 APT 安装的依赖（如 Go），因为它们会在后续步骤中单独处理
    if [ ${#missing_non_apt_deps[@]} -gt 0 ]; then
        log_warn "以下依赖 (${missing_non_apt_deps[*]}) 未通过 APT 安装，将在后续步骤中按需处理。"
    fi
    
    log_success "所有关键系统依赖检查完毕。"
}

# 专门用于按需安装依赖的函数
install_dependencies() {
    local deps_to_install=("$@")
    local missing_deps=()
    for dep in "${deps_to_install[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_warn "需要安装以下依赖: ${missing_deps[*]}。"
        apt-get update && apt-get install -y "${missing_deps[@]}"
    fi
}

# 检测CPU架构
detect_architecture() {
    case $(uname -m) in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *) log_error "不支持的CPU架构: $(uname -m)"; exit 1 ;;
    esac
}
task_ip_forward(){
        echo -e "${yellow}创建系统转发${reset}"
    # 判断是否已存在 net.ipv4.ip_forward=1
        if ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf; then
            echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        fi

    # 判断是否已存在 net.ipv6.conf.all.forwarding = 1
    #    if ! grep -q '^net.ipv6.conf.all.forwarding = 1$' /etc/sysctl.conf; then
    #       echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
    #   fi
        sleep 1
        echo -e "${green_text}系统转发创建完成${reset}"
        sleep 1
        }


# 检查并解除 systemd-resolved 对 53 端口的占用
check_resolved_port53() {
    log_info "正在检查 systemd-resolved 对 53 端口的占用情况..."
    local conf_file="/etc/systemd/resolved.conf"
    if [ ! -f "$conf_file" ]; then
        log_info "$conf_file 不存在，无需操作。"
        return
    fi
    if grep -qE "^\s*DNSStubListener\s*=\s*no\s*$" "$conf_file"; then
        log_success "DNSStubListener 已正确配置为 'no'。"
        return
    fi
    log_warn "DNSStubListener 配置需要调整，正在修改..."
    # 使用 sed 命令安全地修改或添加配置行
    if ! grep -qE "^\s*#?\s*DNSStubListener\s*=" "$conf_file"; then
        echo "DNSStubListener=no" >> "$conf_file"
    else
        sed -i -E 's/^\s*#?\s*DNSStubListener\s*=.*/DNSStubListener=no/' "$conf_file"
    fi
    systemctl restart systemd-resolved.service
    log_success "53 端口冲突已解决。"
}

# 通用函数：下载并安装一个 tar.gz 压缩包
download_and_install_archive() {
    local name="$1"       # 程序名，如 "mihomo"
    local url="$2"        # 下载地址
    local dest_path="$3"  # 最终安装路径，如 "/usr/local/bin/mihomo"
    
    log_info "正在下载并安装 '$name' 核心..."
    
    # 创建临时文件来存放下载的压缩包
    local temp_file
    temp_file=$(mktemp)
    # trap 命令确保脚本在退出时（无论正常还是异常）都会执行指定的命令，这里是删除临时文件
    trap 'rm -f "$temp_file"' RETURN 
    
    if ! wget -qO "$temp_file" "$url"; then
        log_error "'$name' 下载失败，URL: $url"
        exit 1
    fi
    
    # 创建临时目录来解压文件
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' RETURN # 确保脚本退出时自动删除临时目录
    
    tar -xzf "$temp_file" -C "$temp_dir"
    
    # 在解压后的目录中智能地查找可执行文件
    local binary_path
    # 优先按程序名查找
    binary_path=$(find "$temp_dir" -type f -name "$name")
    # 如果按名字找不到（例如压缩包内目录结构不一致），则查找任意可执行文件作为后备
    if [ -z "$binary_path" ]; then
        binary_path=$(find "$temp_dir" -type f -executable | head -n 1)
    fi

    if [ -z "$binary_path" ]; then
        log_error "在 '$name' 的压缩包中未找到可执行文件。"
        exit 1
    fi

    # 移动并设置权限
    mv "$binary_path" "$dest_path"
    chmod +x "$dest_path"
    log_success "'$name' 核心已成功安装至 $dest_path"
}


# ==============================================================================
# SECTION: 核心安装逻辑 (Installation Logic)
# ==============================================================================

# 提供菜单让用户选择要安装的核心类型
choose_core_type() {
    # 使用 nameref (声明一个引用变量)，result_var 就成了外面传进来的变量的别名。
    # 例如，调用 choose_core_type core_type，这里的 result_var 就代表外面的 core_type。
    declare -n result_var="$1"

    # 显示菜单（这些输出到哪里都无所谓了，因为我们不再捕获标准输出了）
    echo
    log_info "请选择您要安装的 Sing-Box 核心类型:"
    echo "  1. 官方核心 (可通过二进制或编译安装)"
    echo "  2. S-Y 核心 (推荐用于机场订阅)"
    echo "  3. reF1nd 核心 (功能强大的社区版)"
    echo "  4. Puer 核心 (旧版, 已停止维护)"
    echo "  5. Xiling 核心 (旧版, 已停止维护)"
    echo "  0. 退出安装"
    read -rp "请输入您的选择 [0-5]: " choice

    case "$choice" in
        1)
            echo "  -> 您已选择官方核心。"
            echo "     请选择安装方式:"
            echo "     1. 从源码编译 (获取最新功能, 速度较慢)"
            echo "     2. 安装预编译的二进制文件 (速度快)"
            read -rp "请输入您的选择 [1-2]: " method

            # 不再使用 echo 返回值，而是直接给引用变量赋值
            if [[ "$method" == "1" ]]; then
                result_var="official-compile"
            else
                result_var="official-core"
            fi
            ;;
        # 直接给引用变量赋值
        2) result_var="s-y" ;;
        3) result_var="reF1nd" ;;
        4) result_var="puer" ;;
        5) result_var="xiling" ;;
        0) log_info "操作已取消。"; exit 0 ;;
        *) log_error "无效的选择。"; exit 1 ;;
    esac
}
# 根据用户选择的核心类型，执行相应的安装操作
install_singbox_core() {
    local core_type="$1"
    local arch
    arch=$(detect_architecture)
    local url=""

    # 根据核心类型，设置不同的下载URL
    case "$core_type" in
        official-compile)
            # 对于编译安装，调用专门的编译函数
            compile_singbox_from_source
            return # 编译函数自己处理安装，所以这里直接返回
            ;;
        official-core)
            # 从 GitHub API 获取最新稳定版的版本号和下载地址
            local version
            version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
            url="https://github.com/SagerNet/sing-box/releases/download/${version}/sing-box-${version#v}-linux-${arch}.tar.gz"
            ;;
        puer)   url="https://github.com/herozmy/StoreHouse/releases/download/sing-box/sing-box-puernya-linux-${arch}.tar.gz" ;;
        s-y)    url="https://github.com/herozmy/StoreHouse/releases/download/sing-box-yelnoo/sing-box-yelnoo-linux-${arch}.tar.gz" ;;
        xiling) url="https://github.com/herozmy/StoreHouse/releases/download/sing-box-x/sing-box-x.tar.gz" ;;
        reF1nd) url="https://github.com/herozmy/StoreHouse/releases/download/sing-box-reF1nd/sing-box-reF1nd-dev-linux-${arch}.tar.gz" ;;
        *) log_error "未知的核心类型 '$core_type'，无法进行安装。"; exit 1 ;;
    esac
    
    # 调用通用的下载安装函数
    download_and_install_archive "sing-box" "$url" "/usr/local/bin/sing-box"
}

# 从源码编译并安装 Sing-Box 的函数 (优化版)
compile_singbox_from_source() {
    log_info "开始从源码编译 Sing-Box 最新版本..."

    # --- 步骤 1: 准备 Go 编译环境 ---
    log_info "正在准备 Go 编译环境..."
    
    # 清理旧的Go安装，确保环境纯净
    rm -rf /usr/local/go
    
    # 从GitHub获取最新的Go版本号
    log_info "正在获取最新的 Go 版本号..."
    local go_version
    go_version=$(curl -s https://github.com/golang/go/tags | grep '/releases/tag/go' | head -n 1 | gawk -F/ '{print $6}' | gawk -F\" '{print $1}')
    if [ -z "$go_version" ]; then
        log_error "从 GitHub 获取 Go 最新版本号失败！"
        exit 1
    fi
    log_success "成功获取 Go 版本号: ${go_version}"

    # 下载并解压Go
    local arch
    arch=$(detect_architecture)
    log_info "正在为架构 '${arch}' 下载并安装 Go..."
    local go_archive_name="${go_version}.linux-${arch}.tar.gz"
    
    wget -q --show-progress -O "$go_archive_name" "https://go.dev/dl/${go_version}.linux-${arch}.tar.gz"
    tar -C /usr/local -xzf "$go_archive_name"
    rm -f "$go_archive_name" # 操作完成后立即清理下载的压缩包
    
    # 设置Go环境变量，使其对当前会话和未来所有会话都生效
    log_info "正在配置 Go 环境变量..."
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/golang.sh
    source /etc/profile.d/golang.sh
    # 验证Go是否安装成功
    if ! command -v go &>/dev/null; then
        log_error "Go 环境配置失败，请检查 /etc/profile.d/golang.sh"
        exit 1
    fi
    log_success "Go 环境准备就绪 (版本: $(go version))"

    # --- 步骤 2: 获取并准备 Sing-Box 源码 ---
    # 创建一个安全的临时目录用于编译，避免污染当前目录
    local build_dir
    build_dir=$(mktemp -d)
    # 使用 trap 命令确保无论脚本如何退出（成功、失败、被中断），临时目录都会被清理
    trap 'log_info "正在清理临时编译目录..."; rm -rf "$build_dir"' RETURN > /dev/null 2>&1

    cd "$build_dir"
    log_info "正在从 GitHub 克隆 Sing-Box 源码至临时目录..."
    git clone https://github.com/SagerNet/sing-box.git
    cd sing-box

    log_info "请选择要编译的分支:"
    echo "  1. 稳定版 (main)"
    echo "  2. 开发版 (dev)"
    read -rp "请输入您的选择 [1/2]，回车默认为 1: " branch_choice

    local branch_name="main"
    local sing_box_tags="with_quic,with_grpc,with_dhcp,with_wireguard,with_utls,with_clash_api,with_gvisor,with_v2ray_api,with_lwip,with_acme"
    
    if [ "$branch_choice" == "2" ]; then
        branch_name="dev"
        sing_box_tags="with_quic,with_dhcp,with_shadowsocksr,with_utls,with_clash_api,with_gvisor"
    fi

    log_info "正在切换到 '${branch_name}' 分支..."
    git checkout "$branch_name"

    # --- 步骤 3: 编译 Sing-Box ---
    log_info "正在获取版本号并准备编译..."

    # 检查版本号读取工具是否存在
    if [ ! -f ./cmd/internal/read_tag/main.go ]; then
        log_error "源码中找不到版本号读取工具，可能仓库结构已改变。"
        exit 1
    fi

    # 获取版本号
    local sing_box_version
    sing_box_version=$(CGO_ENABLED=0 go run ./cmd/internal/read_tag)
    log_info "检测到 Sing-Box 版本: $sing_box_version"

    log_info "开始编译 (这可能需要几分钟)..."
    # 编译命令保持原样，以确保功能一致性
    if ! go build -v -trimpath \
        -ldflags "-checklinkname=0 -X 'github.com/sagernet/sing-box/constant.Version=${sing_box_version}' -s -w -buildid=" \
        -tags "${sing_box_tags}" \
        ./cmd/sing-box; then
        log_error "Sing-Box 编译失败！请检查编译日志。"
        exit 1
    fi

    log_success "Sing-Box 编译成功！"

    # --- 步骤 4: 安装编译好的文件 ---
    log_info "正在将编译好的核心文件安装到 /usr/local/bin/..."
    mv ./sing-box /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    
    log_success "Sing-Box (从源码编译) 已成功安装！"
    # 临时目录将在函数返回时由 trap 命令自动清理
}


# ==============================================================================
# SECTION: 配置与系统集成 (Configuration & System Integration)
# ==============================================================================

# 提示用户输入机场订阅地址
prompt_for_subscription() {
    local sub_url=""
    read -rp "是否需要根据机场订阅链接生成配置文件? (y/n): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        read -rp "请输入您的机场订阅链接: " sub_url
    fi
    echo "$sub_url" # 通过 echo 将结果返回给调用者
}

# 安装 Sing-Box 的配置文件
install_singbox_config() {
    local config_type="$1"
    mkdir -p /etc/sing-box
    
    log_info "正在为 '$config_type' 核心安装配置文件..."
    local sub_url
    sub_url=$(prompt_for_subscription)

    if [ -z "$sub_url" ]; then
        log_warn "未提供订阅链接。将仅安装一个模板，您需要手动修改它。"
    fi

    local template_url=""
    # 根据配置类型，设置不同的模板下载地址
    case "$config_type" in
        official)
            if [ -n "$sub_url" ]; then
                log_info "正在从订阅链接生成配置文件..."
                curl -o /etc/sing-box/config.json "${SUB_HOST}/config/${sub_url}${SINGBOX_CONFIG_TPL}"
            else
                log_warn "官方核心需要订阅链接来自动生成配置，现已跳过。"
            fi
            ;;
        puer)   template_url="https://raw.githubusercontent.com/zhuoyuan32/StoreHouse/refs/heads/latest/config/sing-box/sing-box-p.json" ;;
        xiling) template_url="https://raw.githubusercontent.com/zhuoyuan32/StoreHouse/refs/heads/latest/config/sing-box/sing-box-x.json" ;;
        s-y)    template_url="https://raw.githubusercontent.com/zhuoyuan32/StoreHouse/refs/heads/latest/config/sing-box/sing-box-y.json" ;;
        reF1nd) template_url="https://raw.githubusercontent.com/zhuoyuan32/StoreHouse/refs/heads/latest/config/sing-box/sing-box-r-1.12.json" ;;
    esac

    # 如果设置了模板URL，则下载并替换订阅地址
    if [ -n "$template_url" ]; then
        curl -o /etc/sing-box/config.json "$template_url"
        if [ -n "$sub_url" ]; then
            # 使用更健壮的 sed 替换方式，避免特殊字符问题
            sed -i 's|"download_url": "机场订阅"|"download_url": "'"$sub_url"'"|g' /etc/sing-box/config.json
            sed -i 's|"url": "机场订阅"|"url": "'"$sub_url"'"|g' /etc/sing-box/config.json
        fi
    fi

    # 在 /etc/sing-box 目录下创建一个 'version' 文件，记录当前安装的核心类型，以便后续更新和切换
    echo "$config_type" > /etc/sing-box/version
    log_success "'$config_type' 的配置文件已安装。"
}

# 安装并适配 Mihomo 的配置文件 (优化版)
install_mihomo_config() {
    log_info "开始配置 Mihomo..."
    
    # --- 步骤 1: 准备基础目录和版本文件 ---
    mkdir -p /etc/mihomo
    echo "mihomo" > /etc/mihomo/version
    log_success "Mihomo 目录和版本文件已创建。"

    # --- 步骤 2: 获取用户订阅信息 ---
    # 调用我们之前定义的通用函数来获取订阅URL
    local sub_url
    sub_url=$(prompt_for_subscription)

    # 如果用户选择不使用订阅，则无需进行任何配置操作
    if [ -z "$sub_url" ]; then
        log_warn "未提供订阅链接，跳过配置文件生成。请手动配置 /etc/mihomo/config.yaml"
        return
    fi
    
    # --- 步骤 3: 下载并修改配置文件 (原子性操作) ---
    log_info "正在下载并适配 Mihomo 配置文件模板..."
    
    # 定义常量，便于维护
    #local template_url="https://raw.githubusercontent.com/luestr/ProxyResource/main/Tool/Clash/Config/Clash_Sample_Configuration_By_iKeLee.yaml"
    local template_url="https://raw.githubusercontent.com/zhuoyuan32/StoreHouse/refs/heads/latest/config/mihomo/config.yaml"
    local final_config_path="/etc/mihomo/config.yaml"
    
    # 创建一个临时文件来执行所有修改操作
    local temp_config_file
    temp_config_file=$(mktemp)
    # 使用 trap 确保无论如何都会清理临时文件
    trap 'rm -f "$temp_config_file"' RETURN

    # 下载模板到临时文件
    if ! curl -sL -o "$temp_config_file" "$template_url"; then
        log_error "从 URL 下载配置文件模板失败: $template_url"
        exit 1
    fi
    log_success "配置文件模板下载成功。"

    log_info "正在根据您的系统环境和输入适配配置文件..."
    # 自动检测主网卡名称
    local interface_name
    interface_name=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(en|eth)' | head -n 1 | cut -d'@' -f1)
    if [ -z "$interface_name" ]; then
        log_error "未能自动检测到主网卡 (如 eth0, ens33)。"
        exit 1
    fi
    log_info "自动检测到网卡: $interface_name"
    log_info "正在根据您的系统环境和输入适配配置文件..."
    # 替换所有的 eth0 为检测到的网卡名称
    sed -i "s|eth0|${interface_name}|g" "$temp_config_file"
    # 特别确保 interface-name 字段被正确替换
   # sed -i "s|interface-name: .*|interface-name: ${interface_name}|" "$temp_config_file"

    # --- 步骤 4: 使用 yq 和 sed 集中修改配置 ---
    # 使用 yq 进行结构化修改，一次性完成
  #  yq eval-all \
   #     '.tproxy-port = 7896 |
   #      .redir-port = 7877 |
    #     ."interface-name" = "'"$interface_name"'" |
    #     ."external-ui" = "/etc/mihomo/ui" |
     #    del(.tun) |
     #    del(.proxy-providers."机场名称2") |
     #    .proxy-providers."机场名称1".url = "'"$sub_url"'"
     #   ' -i "$temp_config_file"

    # 使用 sed 处理非标准 YAML 或纯文本替换
    #sed -i \
       # -e 's/!!merge <<: \*/<<: \*/g' \
       # -e 's/FilterAll: &FilterAll.*$/FilterAll: \&FilterAll/' \
       # -e "s/28.0.0.1\/8/28.0.0.0\/8/g" \

       # "$temp_config_file"
    sed -i "s|机场订阅|${sub_url}|g" "$temp_config_file"
    # --- 步骤 5: 验证并应用修改 ---
    if ! yq eval 'true' "$temp_config_file" &>/dev/null; then
        log_error "配置文件修改后格式错误，操作已中止。"
        exit 1
    fi

    # 所有修改成功后，才将临时文件移动到最终位置
    mv "$temp_config_file" "$final_config_path"
    
    log_success "Mihomo 配置文件已成功生成并适配。"
}

# ==============================================================================
# SECTION: Hysteria2 'Go Home' 功能模块
# ==============================================================================

# 主任务函数：协调整个"回家"配置流程
task_install_hy2_home() {
    # 询问用户是否要安装
    read -rp "是否安装或更新 Hysteria2 '回家' 配置? (y/n): " choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        log_warn "操作已取消。"
        log_info "如需安装，可稍后运行 'proxytool' 或重新运行此脚本。"
        return
    fi
    
    log_info "开始 Hysteria2 '回家' 配置流程..."
    
    # 1. 生成自签名证书
    generate_self_signed_cert "/root/hysteria" "bing.com"
    
    # 2. 从用户处获取所有必要的配置信息
    declare -A hy2_details
    prompt_for_hy2_details hy2_details
    
    # 3. 将新的 inbound 注入到 Sing-Box 服务端配置中
    inject_hy2_inbound \
        "${hy2_details[port]}" \
        "${hy2_details[password]}" \
        "/root/hysteria/cert.pem" \
        "/root/hysteria/private.key"
    
    # 4. 重启服务以应用新配置
    log_info "正在重启 sing-box 服务以加载新配置..."
    systemctl restart sing-box
    
    # 5. 根据用户选择生成对应的客户端配置文件
    generate_client_config hy2_details
    
    log_success "Hysteria2 '回家' 配置全部完成！"
}

# 1. 生成自签名证书
generate_self_signed_cert() {
    local cert_dir="$1"
    local common_name="$2"
    
    log_info "正在生成自签名证书..."
    mkdir -p "$cert_dir"
    
    # 检查证书是否已存在，如果存在则跳过
    if [ -f "${cert_dir}/cert.pem" ] && [ -f "${cert_dir}/private.key" ]; then
        log_success "证书已存在于 ${cert_dir}，跳过生成。"
        return
    fi
    
    openssl ecparam -genkey -name prime256v1 -out "${cert_dir}/private.key"
    openssl req -new -x509 -days 36500 -key "${cert_dir}/private.key" -out "${cert_dir}/cert.pem" -subj "/CN=${common_name}"
    log_success "成功为 '${common_name}' 生成有效期100年的自签名证书。"
}

# 2. 提示用户输入所有 Hysteria2 配置详情
prompt_for_hy2_details() {
    declare -n details="$1"
    
    log_info "请输入 Hysteria2 '回家' 配置所需的详细信息:"
    
    while true; do
        read -rp "请输入您的家庭DDNS域名: " details[domain]
        if [[ "${details[domain]}" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            log_error "域名格式不正确，请重新输入。"
        fi
    done
    
    while true; do
        read -rp "请输入Hy2协议端口号 [默认: 8443]: " details[port]
        details[port]="${details[port]:-8443}"
        if [[ "${details[port]}" =~ ^[0-9]+$ ]]; then
            break
        else
            log_error "端口号必须为数字，请重新输入。"
        fi
    done

    read -rp "请输入连接密码 [默认: password]: " details[password]
    details[password]="${details[password]:-password}"

    read -rp "请输入您的家庭内网段 (例如 192.168.1.0/24) [默认: 10.10.10.0/24]: " details[cidr]
    details[cidr]="${details[cidr]:-10.10.10.0/24}"
    
    log_success "所有信息已收集。"
}

# 3. 使用 jq 安全地将 Hy2 inbound 注入到服务端 JSON 配置中
inject_hy2_inbound() {
    local port="$1"
    local password="$2"
    local cert_path="$3"
    local key_path="$4"
    local config_file="/etc/sing-box/config.json"

    log_info "正在向服务端配置文件注入 Hysteria2 inbound..."
    if [ ! -f "$config_file" ]; then
        log_error "服务端配置文件不存在: $config_file"
        exit 1
    fi
    
    # 先检查是否已存在 tag 为 'hy2-in' 的 inbound，如果存在则先删除
    if jq -e '.inbounds[] | select(.tag == "hy2-in")' "$config_file" > /dev/null; then
        log_warn "检测到已存在的 'hy2-in' 配置，将先移除旧配置再添加新配置。"
        jq 'del(.inbounds[] | select(.tag == "hy2-in"))' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    fi
    
    # 使用 jq 精确地在 'inbounds' 数组的开头添加一个新的对象
    jq \
    --argjson port "$port" \
    --arg password "$password" \
    --arg cert_path "$cert_path" \
    --arg key_path "$key_path" \
    '
    .inbounds = [
        {
            "type": "hysteria2",
            "tag": "hy2-in",
            "listen": "::",
            "listen_port": $port,
            "sniff": true,
            "sniff_override_destination": false,
            "sniff_timeout": "100ms",
            "users": [ { "password": $password } ],
            "ignore_client_bandwidth": true,
            "tls": {
                "enabled": true,
                "alpn": [ "h3" ],
                "certificate_path": $cert_path,
                "key_path": $key_path
            }
        }
    ] + .inbounds
    ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"

    log_success "Hysteria2 inbound 配置已成功注入。"
}

# 4. 生成客户端配置文件
generate_client_config() {
    declare -n details="$1"
    
    log_info "请选择要生成的客户端配置文件类型:"
    echo "  1. 全回家分流 (PH佬规则)"
    echo "  2. 客户端规则分流 (O佬规则，需自行添加代理节点)"
    read -rp "请输入您的选择 [1/2]: " choice

    local template_url=""
    case "$choice" in
        1) 
            template_url="https://raw.githubusercontent.com/zhuoyuan32/StoreHouse/refs/heads/latest/config/sing-box/ph_hy2-home-20250418.json"
            log_info "正在生成 '全回家分流' 客户端配置..."
            ;;
        2) 
            template_url="https://raw.githubusercontent.com/zhuoyuan32/StoreHouse/refs/heads/latest/config/sing-box/o_hy2-home.json"
            log_info "正在生成 '客户端规则分流' 配置..."
            ;;
        *) 
            log_error "无效选择。跳过客户端配置生成。"
            return
            ;;
    esac

    local client_config_path="/root/go_home.json"
    if ! wget -qO "$client_config_path" "$template_url"; then
        log_error "下载客户端配置模板失败。"
        return
    fi

    # 调用通用替换函数
    patch_client_config "$client_config_path" details

    # 如果是PH佬规则，额外获取并替换 bssid 和 mosdns 地址
    if [ "$choice" == "1" ]; then
        read -rp "请输入您家里的WiFi BSSID (用于回家直连，可留空): " bssid
        read -rp "请输入您的 MosDNS 服务器地址 [默认: 10.10.10.53]: " mosdns_addr
        sed -i \
            -e "s/home_wifi_bssid/${bssid:-e8:9f:80:8b:9c:59}/g" \
            -e "s/home_mosdns_address/${mosdns_addr:-10.10.10.53}/g" \
            "$client_config_path"
    fi

    log_success "客户端配置文件已成功生成！"
    log_info "文件路径: ${YELLOW}${client_config_path}${RESET}"
    log_info "请将此文件复制到您的客户端使用。"
}

patch_client_config() {
    local config_path="$1"
    declare -n cfg_details="$2"

    log_info "正在适配客户端配置文件：$config_path..."

    # 替换前对可能包含特殊字符的变量进行处理
    local escaped_domain="${cfg_details[domain]//\\/\\\\}" # 使用 cfg_details
    escaped_domain="${escaped_domain//&/\\&}"
    local escaped_port="${cfg_details[port]//\\/\\\\}"     # 使用 cfg_details
    escaped_port="${escaped_port//&/\\&}"
    local escaped_password="${cfg_details[password]//\\/\\\\}" # 使用 cfg_details
    escaped_password="${escaped_password//&/\\&}"
    local escaped_cidr="${cfg_details[cidr]//\\/\\\\}"     # 使用 cfg_details
    escaped_cidr="${escaped_cidr//&/\\&}"

    # 使用 sed 一次性完成所有通用替换
    sed -i \
        -e "s#home_domain#${escaped_domain}#g" \
        -e "s#home_port#${escaped_port}#g" \
        -e "s#home_password#${escaped_password}#g" \
        -e "s#home_ipcidr#${escaped_cidr}#g" \
        "$config_path"

    if [ $? -eq 0 ]; then
        log_info "客户端配置文件适配完成。"
    else
        log_error "适配客户端配置文件失败！请检查 $config_path 和输入参数。"
    fi
}

# ==============================================================================
# SECTION: 系统集成 (System Integration)
# ==============================================================================

# 安装 systemd 服务文件
setup_systemd_services() {
    local service_name="$1" # "sing-box" 或 "mihomo"
    log_info "正在为 '$service_name' 设置 systemd 服务..."
    cp "$DIRPATH/${service_name}.service" "/etc/systemd/system/"
    systemctl daemon-reload # 重新加载 systemd 配置使其生效
    log_success "$service_name 服务文件已创建。"
}
    check_interfaces() {
        interfaces=$(ip -o link show | awk -F': ' '{print $2}')
        # 输出物理网卡名称
        for interface in $interfaces; do
            # 检查是否为物理网卡（不包含虚拟、回环等），并排除@符号及其后面的内容
            if [[ $interface =~ ^(en|eth).* ]]; then
                interface_name=$(echo "$interface" | awk -F'@' '{print $1}')  # 去掉@符号及其后面的内容
                echo -e "您的网卡是：${yellow}$interface_name${reset}"
                valid_interfaces+=("$interface_name")  # 存储有效的网卡名称
            fi
        done
        # 提示用户选择
        
        #read -p "脚本自行检测的是否是您要的网卡？(y/n): " confirm_interface
        #if [ "$confirm_interface" = "y" ]; then
            #selected_interface="$interface_name"
            #echo -e "您选择的网卡是: ${green_text}$selected_interface${reset}"
        #elif [ "$confirm_interface" = "n" ]; then
            #read -p "请自行输入您的网卡名称: " selected_interface
            #echo -e "您输入的网卡名称是: ${green_text}$selected_interface${reset}"
        #else
            #echo "无效的选择"
        #fi
    }
setup_nftables() {
    log_info "正在进行 NFTables 和透明代理初始配置..."

    # 安装透明代理服务文件
    log_info "正在设置透明代理服务..."
    cp "$DIRPATH/tproxy-router.service" "/etc/systemd/system/"
    systemctl daemon-reload
    log_success "透明代理服务文件已创建。"

    # 自动检测主网卡名称
    check_interfaces

    if [ -z "$interface_name" ]; then
        log_error "无法自动检测到主网络接口。请手动检查网络配置或确保网络连接正常。"
        return 1
    fi
    log_info "检测到主网络接口为: '$interface_name'"
    sleep 1
    log_info "请根据提示选择要应用的 NFTables 模式..."
    
    # 调用 switch_nftables 函数，它现在只负责复制文件，不激活
    switch_nftables
    local switch_status=$?
    if [ $switch_status -ne 0 ]; then
        log_error "NFTables 模式选择或文件配置失败，退出初始配置。"
        return $switch_status
    fi
    log_success "NFTables 配置模板已根据您的选择配置到 '/etc/nftables.conf'。"
    log_info "防火墙规则尚未激活，正在准备替换网卡名称..."
    sleep 1
    local NFT_CONF_DEST="/etc/nftables.conf"

    # 检查 nftables.conf 中是否存在 eth0
    if grep -q "eth0" "$NFT_CONF_DEST"; then
        log_info "正在替换为检测到的接口 '$interface_name'..."
        if ! sed -i "s/eth0/${interface_name}/g" "$NFT_CONF_DEST"; then
            log_error "替换 '$NFT_CONF_DEST' 中的 'eth0' 为 '$interface_name' 失败。请检查文件权限或内容。"
            return 1 # 替换失败是严重错误，应退出
        else
            log_success "网卡名称已成功更新为 '$interface_name'。"
        fi
    fi

    sleep 1
    # 在所有配置（包括网卡替换）完成后，进行一次性激活
    log_info "所有 NFTables 配置已准备就绪。现在将激活防火墙规则..."
   # _activate_nftables_rules "最终的 NFTables 配置 (网卡: $interface_name)"
    return $? # 返回激活函数的状态
}

# 安装仪表盘 UI
install_dashboard_ui() {
    local core_name="$1"
    local ui_path="/etc/${core_name}/ui"
    log_info "正在为 '$core_name' 安装/更新仪表盘 UI..."
    rm -rf "$ui_path" # 先删除旧的UI
    # 从 GitHub 克隆最新的UI面板，--depth 1 表示只克隆最新的提交，加快速度
    if git clone --depth 1 https://github.com/Zephyruso/zashboard.git -b gh-pages "$ui_path"; then
        log_success "UI 已成功安装至 $ui_path"
    else
        log_error "克隆 UI 失败。请检查网络或手动安装。"
    fi
}

# 启用并启动所有相关服务
enable_and_start_all_services() {
    local core_name="$1"
    log_info "正在启用并启动所有相关服务..."
    check_resolved_port53

    # --now 选项表示立即启动并设置为开机自启
    systemctl enable --now "$core_name" &>/dev/null
    systemctl enable --now tproxy-router &>/dev/null
    
    # 应用防火墙规则并设置为开机自启
    nft flush ruleset
    nft -f /etc/nftables.conf
    systemctl enable --now nftables &>/dev/null
    
    log_success "所有服务均已启动并设置为开机自启。"
    
    # 检查是否存在冲突服务，并询问是否停止
    if [ -n "$PROXY_CONFLICT_SERVICE" ]; then
        local old_service="$PROXY_CONFLICT_SERVICE"
        log_warn "检测到 ${old_service^} 服务仍在运行。"
        log_info "新安装的 ${core_name^} 服务已经启动。"
        log_info "两个代理服务同时运行可能导致网络冲突。"
        
        read -p "是否停止旧的 ${old_service^} 服务？(输入y停止，默认否) [y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log_info "正在停止 ${old_service^} 服务..."
            systemctl stop "$old_service"
            systemctl disable "$old_service"
            log_success "${old_service^} 服务已停止。"
        else
            log_warn "您选择保留两个代理服务同时运行，这可能导致网络问题。"
            log_info "如需手动切换服务，请使用 'proxytool' 命令。"
        fi
        # 清理环境变量
        unset PROXY_CONFLICT_SERVICE
    fi
}

# 打印最终的安装总结信息
print_summary() {
    local name="$1"
    local dir="$2"
    local ui_url="$3"
    
    echo # 打印空行
    log_success "=================================================================="
    log_success "  $name 安装完成!"
    log_success "  脚本制作: BY herozmy 2025"
    log_success "=================================================================="
    echo
    log_info "配置文件目录: $dir"
    log_info "仪表盘UI地址: ${YELLOW}${ui_url}${RESET}"
    echo
    log_warn "本脚本仅供个人学习与研究使用。"
    log_warn "请勿用于任何违反您当地法律法规的活动！"
    echo
}

# 打印常用的服务管理命令
print_service_commands() {
    local name="$1"
    log_info "常用管理命令:"
    echo -e "  ${GREEN}menu${RESET} 显示主菜单"
    echo -e "  ${GREEN}proxytool${RESET} 显示工具菜单"
}

# --- 检查代理服务冲突 ---
check_proxy_conflict() {
    local installing_service="$1"  # 正在安装的服务名称
    local conflict_found=false
    local running_service=""
    
    # 默认设置为需要安装防火墙和tp-router
    export NEED_FIREWALL_SETUP=true
    
    # 检查是否已安装其他代理服务
    if [ "$installing_service" = "sing-box" ] && command -v mihomo &>/dev/null; then
        if systemctl is-active --quiet mihomo; then
            conflict_found=true
            running_service="mihomo"
        fi
    elif [ "$installing_service" = "mihomo" ] && command -v sing-box &>/dev/null; then
        if systemctl is-active --quiet sing-box; then
            conflict_found=true
            running_service="sing-box"
        fi
    fi

    if [ "$conflict_found" = true ]; then
        log_warn "检测到 ${running_service^} 正在运行。"
        log_info "当前存在正在运行的 ${running_service^} 服务。"
        log_info "为保持网络连接，安装过程中不会停止现有服务。"
        
        # 将冲突服务名写入环境变量，供后续处理
        export PROXY_CONFLICT_SERVICE="$running_service"
        
        # 检查是否已存在防火墙和tp-router服务
        if systemctl is-enabled --quiet tproxy-router &>/dev/null && systemctl is-enabled --quiet nftables &>/dev/null; then
            log_info "检测到已存在防火墙和透明代理服务，将直接复用现有服务。"
            export NEED_FIREWALL_SETUP=false
        fi
        
        read -p "是否继续安装？(默认是，输入n取消) [Y/n]: " choice
        if [[ "$choice" =~ ^[Nn]$ ]]; then
            log_error "安装已取消。"
            exit 1
        fi
    fi
    return 0
}

# --- 脚本执行入口 ---
# 将所有从命令行接收到的参数 ($@) 传递给 main 函数
main "$@"
