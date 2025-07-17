#!/bin/bash
########################################################
# 更新脚本
# 作者: herozmy
# 版本: 1.0
# 日期: 2025-04-21
########################################################

# 颜色定义
green_text="\033[32m"
yellow_text="\033[33m"
red_text="\033[31m"
reset="\033[0m" 
DIRPATH="/usr/local/bin/tools"
BACKUP_DIR="/tmp/storehouse_backup"

# 简化颜色输出函数
red() { echo -e "\e[31m$1\e[0m"; }
green() { echo -e "\e[32m$1\e[0m"; }
yellow() { echo -e "\e[33m$1\e[0m"; }

# 变量定义
url="https://raw.githubusercontent.com/zhuoyuan32/StoreHouse/latest"

download() {
    # 参数【$1】目标文件，【$2】在线地址
    result=""
    if command -v curl >/dev/null 2>&1; then
        curl -s -L -o "$1" "$2" && result="200" || result="404"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --no-check-certificate -O "$1" "$2" && result="200" || result="404"
    else
        red "未找到下载工具，请安装curl或wget"
        return 1
    fi
}

backup_scripts() {
    if [ -d "$DIRPATH" ]; then
        mkdir -p "$BACKUP_DIR"
        cp -r "$DIRPATH"/* "$BACKUP_DIR"/ 2>/dev/null
        if [ -f "/usr/bin/menu" ]; then
            cp "/usr/bin/menu" "$BACKUP_DIR"/ 2>/dev/null
        fi
        if [ -f "/usr/bin/proxytool" ]; then
            cp "/usr/bin/proxytool" "$BACKUP_DIR"/ 2>/dev/null
        fi
        return 0
    fi
    return 1
}

restore_scripts() {
    if [ -d "$BACKUP_DIR" ]; then
        mkdir -p "$DIRPATH"
        cp -r "$BACKUP_DIR"/* "$DIRPATH"/ 2>/dev/null
        if [ -f "$BACKUP_DIR/menu" ]; then
            cp "$BACKUP_DIR/menu" "/usr/bin/" 2>/dev/null
        fi
        if [ -f "$BACKUP_DIR/proxytool" ]; then
            cp "$BACKUP_DIR/proxytool" "/usr/bin/" 2>/dev/null
        fi
        yellow "已恢复之前的脚本文件"
        return 0
    fi
    return 1
}

get_script() {
    # 先备份现有脚本
    backup_scripts
    
    # 下载脚本
    green "正在下载更新包..."
    download /tmp/StoreHouse.tar.gz $url/bin/StoreHouse.tar.gz
    if [ "$result" != "200" ]; then
        red "文件下载失败！正在恢复之前的脚本..."
        restore_scripts
        return 1
    fi
    
    # 创建目录并解压脚本
    mkdir -p $DIRPATH
    if ! tar -zxf "/tmp/StoreHouse.tar.gz" -C "$DIRPATH" >/dev/null 2>&1; then
        red "解压失败！正在恢复之前的脚本..."
        restore_scripts
        return 1
    fi
    
    return 0
}

install_tools() {
    green "安装工具命令..."
    cat > /usr/bin/menu <<EOF
#!/bin/bash
. $DIRPATH/menu.sh
EOF
    cp -f $DIRPATH/proxytool.sh /usr/bin/proxytool
    chmod +x /usr/bin/proxytool /usr/bin/menu
}

install() {
    green "开始更新脚本..."
    if get_script; then
        green "更新完成！"
        install_tools
        echo -----------------------------------------------
        yellow "输入 menu 命令进入菜单页面！！！"
        green "后期直接执行 menu 更新相关脚本，无需重新安装！！！"
        echo ----------------------------------------------- 
    else
        red "更新失败！"
        exit 1
    fi
}

# 检查是否是 root 用户
if [ "$(id -u)" != "0" ]; then
    red "错误：请使用 root 用户执行此脚本！"
    yellow "请执行以下命令切换用户：\n  sudo su -"
    exit 1
fi

# 检查是否存在旧目录
if [ -d "$DIRPATH" ]; then
    green "检测到旧的安装目录 $DIRPATH"
    yellow "是否删除旧的安装目录？y确认 n忽略"
    read -p "请输入(y/n): " choice
    case "${choice,,}" in
        y) 
            rm -rf $DIRPATH
            green "旧的安装目录已删除！"
            install
            ;;
        n)
            install
            ;;
        *)
            red "输入错误！"
            exit 1
            ;;
    esac
else
    install
fi

# 清理临时文件
rm -f /tmp/StoreHouse.tar.gz
