#!/bin/bash
green_text="\033[32m"
yellow_text="\033[33m"
red_text="\033[31m"
reset="\033[0m" 
sub_host="https://sub-singbox.herozmy.com"
json_file="&file=https://raw.githubusercontent.com/herozmy/StoreHouse/refs/heads/latest/config/sing-box/sing-box.json"
local_ip=$(hostname -I | awk '{print $1}')
DIRPATH="/usr/local/bin/tools"
red() {
    echo -e "\e[31m$1\e[0m"
}

green() {
    echo -e "\e[32m$1\e[0m"
}

yellow() {
    echo -e "\e[33m$1\e[0m"
}

    # 修改架构检测函数为最新标准
    detect_architecture() {
        case $(uname -m) in
            x86_64)     echo "amd64" ;;
            aarch64)    echo "arm64" ;;
            armv7l)     echo "armv7" ;;
            armhf)      echo "armhf" ;;
            s390x)      echo "s390x" ;;
            i386|i686)  echo "386" ;;
            *)
                echo -e "${yellow}不支持的CPU架构: $(uname -m)${reset}"
                exit 1
                ;;
        esac
    }

    check_resolved(){
        if [ -f /etc/systemd/resolved.conf ]; then
            # 检测是否有未注释的 DNSStubListener 行
            dns_stub_listener=$(grep "^DNSStubListener=" /etc/systemd/resolved.conf)
            if [ -z "$dns_stub_listener" ]; then
                # 如果没有找到未注释的 DNSStubListener 行，检查是否有被注释的 DNSStubListener
                commented_dns_stub_listener=$(grep "^#DNSStubListener=" /etc/systemd/resolved.conf)
                if [ -n "$commented_dns_stub_listener" ]; then
                    # 如果找到被注释的 DNSStubListener，取消注释并改为 no
                    sed -i 's/^#DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
                    systemctl restart systemd-resolved.service
                    green "53端口占用已解除"
                else
                    green "未找到53端口占用配置，无需操作"
                fi
            elif [ "$dns_stub_listener" = "DNSStubListener=yes" ]; then
                # 如果找到 DNSStubListener=yes，则修改为 no
                sed -i 's/^DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
                systemctl restart systemd-resolved.service
                green "53端口占用已解除"
            elif [ "$dns_stub_listener" = "DNSStubListener=no" ]; then
                # 如果 DNSStubListener 已为 no，提示用户无需修改
                echo -e "${yellow_text}53端口未被占用，无需操作${reset}"
            fi
        else
            echo -e "${yellow_text} /etc/systemd/resolved.conf 不存在，无需操作${reset}"
        fi

    }
## 更新并安装依赖
    update_version(){

            apt update && apt -y upgrade || { 
                echo "更新失败！退出脚本"; 
                exit 1; 
            }
            apt -y install curl git gawk build-essential libssl-dev libevent-dev zlib1g-dev gcc-mingw-w64 nftables jq || { 
                echo "软件包安装失败！退出脚本"; 
                exit 1; 
            }
            echo -e "\n设置时区为Asia/Shanghai"
            timedatectl set-timezone Asia/Shanghai || { 
                echo -e "\e[31m时区设置失败！退出脚本\e[0m"; 
                exit 1; 
            }
            echo -e "\e[32m时区设置成功\e[0m"
    }
check_and_install_yq() {
    # 只检测是否存在，不检查版本
    if command -v yq &>/dev/null; then
        echo "yq 已存在，跳过安装"
        return 0
    fi

    # 安装最新版
    echo "开始安装 yq..."
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT

    # 架构检测
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *)
            echo "不支持的架构: $(uname -m)"
            return 1
            ;;
    esac

    # 下载验证
    if ! curl -fsSL -o "$temp_dir/yq" "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"; then
        echo "下载失败"
        return 1
    fi

    # 安装验证
    if ! sudo install -m 755 "$temp_dir/yq" /usr/local/bin/yq; then
        echo "安装失败"
        return 1
    fi

    # 最终存在性验证
    if ! command -v yq &>/dev/null; then
        echo "安装后验证失败"
        return 1
    fi

    echo "yq 安装成功"
    return 0
}

######编译sing-box 官核
    singbox_install_make(){
    echo -e "编译Sing-Box 最新版本"
        sleep 1
        echo -e "开始编译Sing-Box 最新版本"
        rm -rf /root/go/bin/*
        # 获取 Go 版本
        Go_Version=$(curl -s https://github.com/golang/go/tags | grep '/releases/tag/go' | head -n 1 | gawk -F/ '{print $6}' | gawk -F\" '{print $1}')
        if [[ -z "$Go_Version" ]]; then
            echo "获取 Go 版本失败！退出脚本"
            exit 1
        fi
        # 判断 CPU 架构
        arch=$(detect_architecture)
        echo "系统架构是：$arch"
        wget -O ${Go_Version}.linux-$arch.tar.gz https://go.dev/dl/${Go_Version}.linux-$arch.tar.gz || { 
            echo "下载 Go 版本失败！退出脚本"; 
            exit 1; 
        }
        tar -C /usr/local -xzf ${Go_Version}.linux-$arch.tar.gz || { 
            echo "解压 Go 文件失败！退出脚本"; 
            exit 1; 
        }
        rm -f ${Go_Version}.linux-$arch.tar.gz  # 清理下载的文件

        # 设置 Go 环境变量
        echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/golang.sh
        source /etc/profile.d/golang.sh  # 立即生效
        rm -rf sing-box
        git clone https://github.com/SagerNet/sing-box.git && cd sing-box
        echo -e "${yellow}请选择1.稳定版/2.开发版：${reset}"
        read -p " 1/2：" sb_choice
        # 拉取远程分支
        git fetch origin main dev || {
        echo -e "${red}拉取分支失败${reset}"
        exit 1
        }

        case $sb_choice in
            1)
                git checkout main || {
                echo -e "${red}切换至 main 分支失败${reset}"
                exit 1
        }
                sing_box_tags="with_quic,with_grpc,with_dhcp,with_wireguard,with_utls,with_clash_api,with_gvisor,with_v2ray_api,with_lwip,with_acme"
            ;;
            2)
                git checkout dev || {
                echo -e "${red}切换至 dev 分支失败${reset}"
                exit 1
            }
                sing_box_tags="with_quic,with_dhcp,with_shadowsocksr,with_utls,with_clash_api,with_gvisor"  # 示例标签
            ;;
            *)
            echo -e "${red}输入错误，请输入稳定版/开发版${reset}"
            exit 1
            ;;
        esac

# 检查版本号工具是否存在
        if [ ! -f ./cmd/internal/read_tag/main.go ]; then
            echo -e "${red}错误：找不到版本号读取工具${reset}"
            exit 1
        fi

    # 获取版本号
        local sing_box_version=$(CGO_ENABLED=0 go run ./cmd/internal/read_tag) || {
            echo -e "${red}获取版本号失败${reset}"
            exit 1
        }
        echo -e "Sing-Box 版本: $sing_box_version"

    # 编译
        if ! go build -v -trimpath \
            -ldflags "-checklinkname=0 -X 'github.com/sagernet/sing-box/constant.Version=${sing_box_version}' -s -w -buildid=" \
            -tags "${sing_box_tags}" \
            ./cmd/sing-box; then
            echo -e "${red}Sing-Box 编译失败！退出脚本${reset}"
            exit 1
        fi

        echo -e "${green}编译完成${reset}"
        sleep 1
    }
## mihomo安装
    mihomo_install(){
        arch=$(detect_architecture)
        download_url="https://github.com/herozmy/StoreHouse/releases/download/mihomo/mihomo-meta-linux-${arch}.tar.gz"
        echo -e "${yellow}开始下载mihomo核心...${reset}"
        if ! wget -O mihomo.tar.gz $download_url; then
            echo -e "${yellow}下载失败，请检查网络连接${reset}"
            exit 1
        fi
        
        echo -e "${green_text}下载完成，开始安装${reset}"
        tar -zxvf mihomo.tar.gz > /dev/null 2>&1
        rm -f mihomo.tar.gz
        mv mihomo /usr/local/bin/
        chmod +x /usr/local/bin/mihomo
    }
## singbox二进制安装
    singbox_install_core(){
        # 替换原有架构判断
        arch=$(detect_architecture)  
        echo -e "请选择下载版本：1.稳定版/2.开发版"     
        read -p "1/2：" version_choice
        case $version_choice in
            1)
                VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest| grep tag_name | cut -d ":" -f2 | sed 's/[\",v ]//g')
                ;;
            2)
                VERSION=$(curl -sSL https://api.github.com/repos/SagerNet/sing-box/releases | jq -r '[.[] | select(.tag_name | test("alpha|beta|rc"))][0].tag_name' | sed 's/[\",v ]//g')
                ;;
            *)
                echo -e "${red}输入错误，请输入稳定版/开发版${reset}"
                exit 1
                ;;
        esac
        curl -Lo sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${arch}.tar.gz"
        tar -zxvf sing-box.tar.gz > /dev/null 2>&1
        mv /root/sing-box-${VERSION}-linux-${arch}/sing-box /usr/local/bin/ || { echo "移动 sing-box 失败！"; exit 1; }
        chmod +x /usr/local/bin/sing-box
        cd ..
        rm -rf sing-box-${VERSION}-linux-${arch} sing-box.tar.gz
    }
    # p核
    singbox_p_install(){
        arch=$(detect_architecture)
        download_url="https://github.com/herozmy/StoreHouse/releases/download/sing-box/sing-box-puernya-linux-${arch}.tar.gz"


        echo -e "${yellow}开始下载Puer喵佬核心...${reset}"
        if ! wget -O sing-box.tar.gz $download_url; then
            echo -e "${yellow}下载失败，请检查网络连接${reset}"
            exit 1
        fi
        
        echo -e "${green_text}下载完成，开始安装${reset}"
        tar -zxvf sing-box.tar.gz
        rm -f sing-box.tar.gz
    }
    # s核
    singbox_s_install(){
        arch=$(detect_architecture)
        download_url="https://github.com/herozmy/StoreHouse/releases/download/sing-box-yelnoo/sing-box-yelnoo-linux-${arch}.tar.gz"
        echo -e "${yellow}开始下载S佬Y核心...${reset}"
        if ! wget -O sing-box.tar.gz $download_url; then
            echo -e "${yellow}下载失败，请检查网络连接${reset}"
            exit 1
        fi
        
        echo -e "${green_text}下载完成，开始安装${reset}"
        tar -zxvf sing-box.tar.gz > /dev/null 2>&1
        rm -f sing-box.tar.gz
    }

    # 完善曦灵X核心安装函数
    singbox_x_install(){
        arch=$(detect_architecture)
        download_url="https://github.com/herozmy/StoreHouse/releases/download/sing-box-x/sing-box-x.tar.gz"
        echo -e "${yellow}开始下载曦灵X核心...${reset}"
        if ! wget -O sing-box.tar.gz $download_url; then
            echo -e "${yellow}下载失败，请检查网络连接${reset}"
            exit 1
        fi
        
        echo -e "${green_text}下载完成，开始安装${reset}"
        tar -zxvf sing-box.tar.gz > /dev/null 2>&1
        mv sing-box_linux_amd64 sing-box
        rm -f sing-box.tar.gz > /dev/null 2>&1   
    }
    # reF1nd佬 R核心
    singbox_r_install(){
        arch=$(detect_architecture)
        download_url="https://github.com/herozmy/StoreHouse/releases/download/sing-box-reF1nd/sing-box-reF1nd-dev-linux-${arch}.tar.gz"
        echo -e "${yellow}开始下载reF1nd佬 R核心...${reset}"
        if ! wget -O sing-box.tar.gz $download_url; then
            echo -e "${yellow}下载失败，请检查网络连接${reset}"
            exit 1
        fi
        
        echo -e "${green_text}下载完成，开始安装${reset}"
        tar -zxvf sing-box.tar.gz > /dev/null 2>&1       
        rm -f sing-box.tar.gz > /dev/null 2>&1   
        
    }
    # 检查核心类型
    check_core_type() {
        local version_file="/etc/sing-box/version"
    
        if [ ! -f "$version_file" ]; then
            echo -e "${red}未检测到核心类型${reset}"
            return 1
        fi
    
        local core_type=$(cat "$version_file")
        case "$core_type" in
            official|puer|xiling|s-y|reF1nd|official-core)
                echo "$core_type"
                return 0
                ;;
            *)
                echo -e "${red}未知核心类型：$core_type${reset}"
                return 1
                ;;
        esac
}
# 更新核心
    update_singbox_core() {
    # 获取当前核心类型
    if ! core_type=$(check_core_type); then
        echo -e "${red}无法确定当前核心，请先选择安装类型${reset}"
        choose_singbox
        return 1
    fi

    systemctl stop tproxy-router > /dev/null 2>&1
    # 根据核心类型执行更新
    case "$core_type" in
        official)
            echo -e "${green}正在编译更新官方核心...${reset}"
            singbox_install_make
            cp -r /root/sing-box/sing-box /usr/local/bin/ || { echo "复制文件失败！退出脚本"; exit 1; }
            chmod +x /usr/local/bin/sing-box 
            ;;
        official-core)
            echo -e "${green}正在更新官方核心...${reset}"
            singbox_install_core 

            ;;
        puer)
            echo -e "${green}正在更新Puer核心...${reset}"
            singbox_p_install && install_core
            ;;
        xiling)
            echo -e "${green}正在更新曦灵核心...${reset}"
            singbox_x_install && install_core
            ;;
        s-y)
            echo -e "${green}正在更新S-Y核心...${reset}"
            singbox_s_install && install_core
            ;;
        reF1nd)
            echo -e "${green}正在更新reF1nd核心...${reset}"
            singbox_r_install && install_core
            ;;
        *)
            echo -e "${red}未知核心类型${reset}"
            return 1
            ;;
    esac
    
    # 重启服务
    systemctl restart sing-box > /dev/null 2>&1
    systemctl restart tproxy-router > /dev/null 2>&1
    echo -e "${green}核心更新完成${reset}"
}
##安装配置文件
    ### 自定义设置
    customize_settings() {
        local retry_count=0
        local max_retries=3
        local suburl=""
        get_subscription_url 
    # 检查订阅地址是否为空
        if [ -z "$suburl" ]; then
            echo -e "${yellow}未提供订阅地址，跳过配置文件生成${reset}"
            return 0  # 直接退出函数，不执行后续操作
        fi

        while [ $retry_count -lt $max_retries ]; do

            # 生成配置文件
            generate_config  # 新增配置文件生成函数
            
            # 验证配置文件
            if check_config; then
                return 0
            else
                retry_count=$((retry_count+1))
                remaining=$((max_retries - retry_count))
                echo -e "${yellow}剩余尝试次数: ${remaining}${reset}"
            fi
        
        done
        echo -e "${red}连续3次生成配置文件失败，请检查订阅地址有效性${reset}"
        echo "请手动编写config配置文件,默认模版仓库地址：https://github.com/herozmy/StoreHouse/tree/main/config"
        sleep 2
    }

    # 新增订阅地址获取函数
    get_subscription_url() {
        echo -e "是否选择生成配置？(y/n) ${green_text}生成配置文件需要添加机场订阅，如自建vps请选择n${reset}"
        read sub_choice
        if [ "$sub_choice" = "y" ]; then
            read -p "输入订阅连接：" suburl
            suburl="${suburl:-https://}"
            echo "已设置订阅连接地址：$suburl"
        else
            echo "请手动编写config配置文件,默认模版仓库地址：https://github.com/herozmy/StoreHouse/tree/main/config"
            
        fi
    }

    # 新增配置文件生成函数
    generate_config() {

        echo -e "${yellow}正在生成配置文件...${reset}"

        curl -o config.json "${sub_host}/config/${suburl}${json_file}" || {
            echo -e "${red}配置文件下载失败${reset}"
            return 1
        }
    }

    # 修改后的配置检查函数
    check_config() {
        local config_file="config.json"
        
        if [ ! -f "$config_file" ]; then
            echo -e "${red}配置文件不存在${reset}"
            return 1
        fi

        line_count=$(wc -l < "$config_file")
        
        if [ "$line_count" -gt 10 ]; then
            echo -e "${green}配置文件检测通过 (${line_count}行)${reset}"
        # return 0
        else
            echo -e "${red}配置文件不完整 (仅${line_count}行)${reset}"
            return 1
        fi
    }
install_mihomo_config(){           
            mkdir -p /etc/mihomo
            echo "mihomo" > /etc/mihomo/version
            get_subscription_url
            if [[ "${sub_choice}" == "y" ]]; then
                if curl -o /etc/mihomo/config.yaml https://raw.githubusercontent.com/luestr/ProxyResource/main/Tool/Clash/Config/Clash_Sample_Configuration_By_iKeLee.yaml; then
                    echo -e "${green_text} 配置文件下载成功${reset}"
                    sleep 1
                    echo -e "${yellow}开始修正配置以适应方案${reset}"
                    check_interfaces
                    # 更改tproxy-port端口
                    sed -i "s|tproxy-port: 7894|tproxy-port: 7896|g" /etc/mihomo/config.yaml
                    # 更改redir-port端口
                    sed -i "s|redir-port: 7893|redir-port: 7877|g" /etc/mihomo/config.yaml
                    # 更改网卡名称
                    sed -i -e '/^interface-name:/d' -e "10i interface-name: $interface_name" /etc/mihomo/config.yaml
                    # 更改UI路径
                    sed -i 's/^#* *external-ui: *ui/external-ui: \/etc\/mihomo\/ui/' /etc/mihomo/config.yaml
                    # 删除 tun 配置块
                    yq eval 'del(.tun)' -i /etc/mihomo/config.yaml
                    # 删除机场名称2 配置块
                    yq eval 'del(.proxy-providers."机场名称2")' -i /etc/mihomo/config.yaml
                    sed -i 's/!!merge <<: \*/<<: \*/g' /etc/mihomo/config.yaml
                    sed -i 's/FilterAll: &FilterAll.*$/FilterAll: \&FilterAll/' /etc/mihomo/config.yaml
                # 更改订阅URL
                    sed -i "s|url: '机场1的订阅URL'|url: '$suburl'|g" /etc/mihomo/config.yaml
                    echo -e "${green_text}mihomo配置修正完成${reset}"
                    else
                    echo -e "${red}配置文件下载失败${reset}"
                    exit 1
                    fi
            fi
            
}
    ### 安装配置文件
    install_josn_config(){
    ###官方内核配置文件
    if [[ "$core_choice" == "1" ]]; then
    mkdir -p /etc/sing-box
        if [[ "$official_choice" == "1" ]]; then
            echo "official" > /etc/sing-box/version
        else 
        echo "official-core" > /etc/sing-box/version
        fi
    customize_settings            
            if [ -f "config.json" ]; then
                mv config.json /etc/sing-box/config.json || {
                    echo -e "${red}配置文件移动失败${reset}"
                    exit 1
                }
            fi        
        # echo -e "${green_text}Sing-box配置文件写入成功！${reset}"
    ###Puer喵佬核心配置文件
        elif [[ "$core_choice" == "2" ]]; then
            
            
            mkdir -p /etc/sing-box
            mkdir -p /etc/sing-box/providers
            mkdir -p /etc/sing-box/rule
            echo "puer" > /etc/sing-box/version
            get_subscription_url

            if curl -o /etc/sing-box/config.json https://raw.githubusercontent.com/herozmy/StoreHouse/refs/heads/latest/config/sing-box/sing-box-p.json; then
                echo -e "${green_text} 配置文件下载成功${reset}"
                sed -i "s|\"download_url\": \"机场订阅\"|\"download_url\": \"$suburl\"|g" /etc/sing-box/config.json
            else
                echo -e "${red}配置文件下载失败${reset}"
                exit 1
            fi
            wget -O /etc/sing-box/p_rule.tar.gz https://d.herozmy.com/public/Routing/Config/sing-box/p_rule.tar.gz
            tar --strip-components=1 -zxvf /etc/sing-box/p_rule.tar.gz -C /etc/sing-box/rule
            rm -f /etc/sing-box/p_rule.tar.gz
    ###曦灵X核心配置文件
        elif [[ "$core_choice" == "3" ]]; then
            
            
            mkdir -p /etc/sing-box
            echo "xiling" > /etc/sing-box/version
            get_subscription_url
            if curl -o /etc/sing-box/config.json https://raw.githubusercontent.com/herozmy/StoreHouse/refs/heads/latest/config/sing-box/sing-box-x.json; then
                echo -e "${green_text} 配置文件下载成功${reset}"
                sed -i "s|\"download_url\": \"机场订阅\"|\"download_url\": \"$suburl\"|g" /etc/sing-box/config.json
            else
                echo -e "${red}配置文件下载失败${reset}"
                exit 1
            fi
    ###S佬Y核心配置文件
        elif [[ "$core_choice" == "4" ]]; then
            
            
            mkdir -p /etc/sing-box
            echo "s-y" > /etc/sing-box/version
            get_subscription_url
            if curl -o /etc/sing-box/config.json https://raw.githubusercontent.com/herozmy/StoreHouse/refs/heads/latest/config/sing-box/sing-box-y.json; then
                echo -e "${green_text} 配置文件下载成功${reset}"
                sed -i "s|\"url\": \"机场订阅\"|\"url\": \"$suburl\"|g" /etc/sing-box/config.json
            else
                echo -e "${red}配置文件下载失败${reset}"
                exit 1
            fi
    ###reF1nd佬 R核心配置文件
        elif [[ "$core_choice" == "5" ]]; then
            
            mkdir -p /etc/sing-box
            echo "reF1nd" > /etc/sing-box/version
            get_subscription_url
            if curl -o /etc/sing-box/config.json https://raw.githubusercontent.com/zhuoyuan32/StoreHouse/refs/heads/latest/config/sing-box/sing-box-r-1.12.json; then
                echo -e "${green_text} 配置文件下载成功${reset}"
                sed -i "s|\"download_url\": \"机场订阅\"|\"download_url\": \"$suburl\"|g" /etc/sing-box/config.json
            else
                echo -e "${red}配置文件下载失败${reset}"
                exit 1  
            fi
    fi
    }
    # 拉取sing-box UI管理界面
        ###检测ui是否存在
    check_ui(){
        found_files=$(find /usr/local/bin/ -type f \( -name "mihomo" -o -name "sing-box" \))
        if [ -n "$found_files" ]; then
        for file in $found_files; do
            filename=$(basename "$file")
        done
        fi  
        if [ -d "/etc/${filename}/ui" ]; then
            echo "更新 WEBUI..."
            rm -rf /etc/${filename}/ui
            git_ui
        else
            git_ui
        fi
    }
    git_ui(){
        if git clone https://github.com/Zephyruso/zashboard.git -b gh-pages /etc/${filename}/ui; then
            echo -e "UI 源码拉取${green_text}成功${reset}。"
        else
            echo "拉取源码失败，请手动下载源码并解压至 /etc/${filename}/ui."
            echo "地址: https://github.com/metacubex/metacubexd"
        fi
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

    #安装hy2回家配置
    hy2-gohome(){
        echo -e "${yellow}是否安装hy2回家配置 y/n${reset}"
        read -p "请输入选择 (y/n): " hy2_choice
        case "${hy2_choice}" in
            y)
                echo -e "${green_text}安装hy2回家配置${reset}"
                install_hy2-gohome
                ;;
            n)
                echo -e "${yellow}不安装hy2回家配置${reset}"
                echo -e "${yellow}如后期需要安装hy2回家配置${reset},${green_text}proxytool${reset}安装即可"
                ;;
            *)
                echo -e "${red}无效选择，退出脚本${reset}"
                exit 1
                ;;
        esac

    }
    #安装hy2回家配置
    install_hy2-gohome(){
        echo -e "hysteria2 回家 自签证书"
        echo -e "开始创建证书存放目录"
        mkdir -p /root/hysteria 
        echo -e "自签bing.com证书100年"
        openssl ecparam -genkey -name prime256v1 -out /root/hysteria/private.key && openssl req -new -x509 -days 36500 -key /root/hysteria/private.key -out /root/hysteria/cert.pem -subj "/CN=bing.com"
        while true; do
            # 提示用户输入域名
            echo -e "${yellow_text}请输入家庭DDNS域名${reset}"
            read -p "域名: " domain
            # 检查域名格式是否正确
            if [[ $domain =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                break
            else
                echo "域名格式不正确，请重新输入"
            fi
        done  
        # 输入端口号
        while true; do
            echo -e "${yellow_text}请输入hy2协议端口号${reset}"
            read -p "端口号: " hyport
            hyport="${hyport:-8443}"

            # 检查端口号是否为数字
            if [[ $hyport =~ ^[0-9]+$ ]]; then
                break
            else
                echo "端口号格式不正确，请重新输入"
            fi
        done
        echo -e "${yellow_text}请输入密码${reset}"
        read -p "密码: " password
        password="${password:-password}"
        echo -e "${yellow_text}请输入你的家庭内网段${reset}"
        read -p "内网段: " ip_cidr
        ip_cidr="${ip_cidr:-10.10.10.0/24}"

        sleep 2
        echo "开始生成配置文件"
        # 检查sb配置文件是否存在
        config_file="/etc/sing-box/config.json"
        if [ ! -f "$config_file" ]; then
            echo "错误：配置文件 $config_file 不存在"
            echo "请配置singbox或者Puer喵佬核或者X核的singbox config.json脚本"
            
            exit 1
        fi   
        hy_config='{
        "type": "hysteria2",
        "tag": "hy2-in",
        "listen": "::",
        "listen_port": '"${hyport}"',
        "sniff": true,
        "sniff_override_destination": false,
        "sniff_timeout": "100ms",
        "users": [
            {
            "password": "'"${password}"'"
            }
        ],
        "ignore_client_bandwidth": true,
        "tls": {
            "enabled": true,
            "alpn": [
            "h3"
            ],
            "certificate_path": "/root/hysteria/cert.pem",
            "key_path": "/root/hysteria/private.key"
        }
        },
    '
    line_num=$(grep -n 'inbounds' /etc/sing-box/config.json | cut -d ":" -f 1)
    # 如果找到了行号，则在其后面插入 JSON 字符串，否则不进行任何操作
    if [ ! -z "$line_num" ]; then
        # 将文件分成两部分，然后在中间插入新的 JSON 字符串
        head -n "$line_num" /etc/sing-box/config.json > tmpfile
        echo "$hy_config" >> tmpfile
        tail -n +$(($line_num + 1)) /etc/sing-box/config.json >> tmpfile
        mv tmpfile /etc/sing-box/config.json
    fi
        echo "HY2回家配置写入完成"
        echo "开始重启sing-box"
        systemctl restart sing-box
        echo "开始生成sing-box回家-手机配置"
        sleep 1
        echo -e "请选择生成sing-box回家-客户端配置"
        echo -e "${yellow}1. 全回家分流 <PH佬规则>${reset}"
        echo -e "${yellow}2. 客户端规则分流 <O佬规则> 注意：需自行添加飞机节点${reset}"
        read -p "请输入选择 (1/2/0): " hy2_config
        case "${hy2_config}" in
        1)
            echo "开始生成sing-box回家-全回家分流 <PH佬规则>"
            ph_home_config
            ;;
        2)
            echo "开始生成sing-box回家-规则分流 <O佬规则> 注意：需自行添加飞机节点"
            home_config
            ;;
        *)
            echo -e "无效选择，退出脚本"
            exit 1
            ;;
        esac

    }

        home_config(){
        if ! wget -O /root/go_home.json https://raw.githubusercontent.com/herozmy/StoreHouse/refs/heads/latest/config/sing-box/o_hy2-home.json; then
            echo -e "${red}客户端配置生成失败${reset}"
            exit 1
        fi
        echo -e "${yellow_text}修正客户端配置${reset}"
        sed -i "s/home_domain/${domain}/g" /root/go_home.json
        sed -i "s/home_port/${hyport}/g" /root/go_home.json
        sed -i "s/home_password/${password}/g" /root/go_home.json
        sed -i "s#home_ipcidr#${ip_cidr//\//\\/}#g" /root/go_home.json
        echo -e "${green}客户端配置生成完成${reset}"
        echo -e "${yellow}客户端配置生成路径为: /root/go_home.json${reset}"
        echo -e "${yellow}请自行复制至客户端${reset}"

    }
    ph_home_config(){
        echo -e "${yellow_text}请输入：mosdns地址 默认：10.10.10.53${reset}"
        read -p "DNS地址: " mosdns_address
        mosdns_address="${mosdns_address:-10.10.10.53}"
        echo -e "${yellow_text}请输入：家里wifi bssid <用于回家直连，请自行获取>${reset}"
        read -p "家里wifi bssid: " wifi_bssid
        wifi_bssid="${wifi_bssid:-e8:9f:80:8b:9c:59}"
        if ! wget -O /root/go_home.json https://raw.githubusercontent.com/herozmy/StoreHouse/refs/heads/latest/config/sing-box/ph_hy2-home-20250418.json; then
            echo -e "${red}客户端配置生成失败${reset}"
            exit 1
        fi
        echo -e "${yellow_text}修正客户端配置${reset}"
        sed -i "s/home_domain/${domain}/g" /root/go_home.json
        sed -i "s/home_port/${hyport}/g" /root/go_home.json
        sed -i "s/home_password/${password}/g" /root/go_home.json
        sed -i "s#home_ipcidr#${ip_cidr//\//\\/}#g" /root/go_home.json
        sed -i "s/home_wifi_bssid/${wifi_bssid}/g" /root/go_home.json
        sed -i "s/home_mosdns_address/${mosdns_address}/g" /root/go_home.json
        echo -e "${green}客户端配置生成完成${reset}"
        echo -e "${yellow}客户端配置生成路径为: /root/go_home.json${reset}"
        echo -e "${yellow}请自行复制至客户端${reset}"
    }
    switch_core(){
        singbox_version=$(cat /etc/sing-box/version)
        echo -e "${green_text}当前核心为: $singbox_version${reset}"
        read -p "是否切换核心 y/n: " core_choice
        case "$core_choice" in
            y)
                choose_singbox
                ;;
            n)
                echo -e "已取消切换核心"
                exit 0
                ;;
        esac
        green "已切换核心为: ${singbox_version}核心"
        yellow "更新config.json配置文件"
        cp /etc/sing-box/config.json /etc/sing-box/${singbox_version}.config.json.bak
        install_josn_config
        green "配置文件更新完成"
        yellow "开始重启sing-box"
        sleep 1
        systemctl restart sing-box
        green "sing-box重启完成"
        yellow "开始重启tproxy-router"
        sleep 1
        systemctl restart tproxy-router
        green "tproxy-router重启完成"
        green "核心切换完毕"
    }
    

######选择安装sing-box 核心
    choose_singbox(){
        echo -e "请选择${green_text}程序${reset}"
        echo -e "${yellow}1. Sing-box官核 ${reset}${green_text}<vps自建推荐>${reset}"
        echo -e "${yellow}2. Sing-boxPuer喵佬核心${reset} <支持订阅> ${green_text}停更${reset}"
        echo -e "${yellow}3. Sing-box曦灵X核心${reset} <支持订阅> ${green_text}停更${reset}"
        echo -e "${yellow}4. Sing-box S佬Y核心${reset} <支持订阅> ${green_text}推荐${reset}"
        echo -e "${yellow}5. Sing-box reF1nd佬 R核心${reset} ${green_text}推荐${reset}"
        echo -e "${yellow}0. 返回主菜单${reset}"
        read -p "请输入选择 (1/2/3/4/5/0): " core_choice
        case "$core_choice" in
            1)
                echo -e "当前选择: ${green_text}Sing-BOX${reset}官方核心"        
                echo -e "请选择: ${green_text}Sing-BOX${reset}官方核心安装方式"  
                choose_install_singbox
                ;;
            2)
                echo -e "当前选择: ${green_text} Sing-BOX ${reset}Puer喵佬核心"
                update_version &&singbox_p_install && install_core
               
                ;;
            3)
                echo -e "当前选择: ${green_text}Sing-BOX${reset}曦灵X核心"
                update_version && singbox_x_install && install_core
                ;;
            4)
                echo -e "当前选择: ${green_text}Sing-BOX${reset}S佬Y核心"
                update_version && singbox_s_install && install_core
                ;;
            5)
                echo -e "当前选择: ${green_text}Sing-BOX${reset}reF1nd佬 R核心"
                update_version && singbox_r_install && install_core
                ;;
            0)
                main
                ;;
            *)
                echo -e "无效选择，退出脚本"
                exit 1
                ;;
        esac
    }
    install_core(){
        mv sing-box /usr/local/bin/sing-box || { echo "移动 sing-box 失败！"; exit 1; }
        chmod +x /usr/local/bin/sing-box       
    }
#############sing-box官方核心
    choose_install_singbox(){
        echo -e "请选择${green_text}程序${reset}"
        echo -e "${yellow}1. Sing-box编译安装${reset}"
        echo -e "${yellow}2. Sing-box二进制安装${reset}"
        echo -e "${yellow}0. 返回核心选择主菜单${reset}"
        read -p "请输入选择 (1/2/0): " official_choice
        case "$official_choice" in
            1)
                echo -e "当前选择: ${green_text}Sing-BOX${reset}编译安装"              
                update_version
                singbox_install_make
                mv -f /root/sing-box/sing-box /usr/local/bin/ || { echo "复制文件失败！退出脚本"; exit 1; }
                chmod +x /usr/local/bin/sing-box 
                echo -e "${green_text}Sing-Box 编译安装完成${reset}" 
                ;;
            2)
                echo -e "当前选择: ${green_text} Sing-BOX ${reset}二进制安装"
                update_version
                singbox_install_core
                # install_core
                echo -e "${green_text}Sing-Box 二进制安装完成${reset}"
                ;;
            0)
                choose_singbox
                ;;
            *)
                echo -e "无效选择，退出脚本"
                exit 1
                ;;
        esac
    }

# 多函数调用    
case "$1" in
    update_core)
        rm -rf /root/sing-box*
        # 检查是否安装过sing-box
        if [ ! -f "/etc/sing-box/version" ]; then
            echo -e "${red}未检测到Sing-Box安装，请先安装 sing-box${reset}"
            exit 1
        fi        
        # 调用更新函数
        echo -e "${green}开始更新Sing-Box核心...${reset}"
        systemctl stop tproxy-router > /dev/null 2>&1
        singbox_version=$(sing-box version | awk '/sing-box version/ {print $3}')
        cp -r /usr/local/bin/sing-box /usr/local/bin/sing-box-$(cat /etc/sing-box/version)-${singbox_version}.bak
        update_singbox_core
        systemctl start tproxy-router > /dev/null 2>&1
        exit 0  # 新增退出指令
        ;;
    update_ui)
        systemctl stop tproxy-router > /dev/null 2>&1
        check_ui
        systemctl start tproxy-router > /dev/null 2>&1
        exit 0  # 新增退出指令
        ;;
    update_home)
        systemctl stop tproxy-router > /dev/null 2>&1
        install_hy2-gohome
        systemctl start tproxy-router > /dev/null 2>&1
        exit 0  # 新增退出指令
        ;;
    switch_core)
        systemctl stop tproxy-router > /dev/null 2>&1
        singbox_version=$(sing-box version | awk '/sing-box version/ {print $3}')
        cp -r /usr/local/bin/sing-box /usr/local/bin/sing-box-$(cat /etc/sing-box/version)-${singbox_version}.bak
        switch_core
        exit 0  # 新增退出指令
        ;;
    mihomo)
    if ! check_and_install_yq; then
        echo "必需依赖 yq 安装失败，退出脚本"
        exit 1
    fi
        mihomo_install
        install_mihomo_config
        check_resolved
        echo -e "${yellow_text}配置mihomo自启动配置${reset}"
        cp $DIRPATH/mihomo.service /etc/systemd/system/
        echo -e "${green_text}mihomo自启动配置完成${reset}"
        sleep 1
        echo -e "${yellow_text}配置tproxy路由${reset}"
        cp $DIRPATH/tproxy-router.service /etc/systemd/system/
        echo -e "${green_text}tproxy路由配置完成${reset}"
        sleep 1
        echo -e "${yellow_text}配置nftables规则${reset}"
        echo "" > "/etc/nftables.conf"
        cat $DIRPATH/nft-tproxy.conf >> "/etc/nftables.conf"
        echo -e "${yellow_text}修正nftables规则${reset}"
        sed -i "s/eth0/${interface_name}/g" "/etc/nftables.conf"
        echo -e "${green_text}nftables规则配置完成${reset}"
        sleep 1
        echo -e "${yellow_text}拉取mihomo UI管理界面${reset}"
        check_ui
        check_aio
        echo -e "${green_text}启用相关服务${reset}"
        systemctl enable --now mihomo > /dev/null 2>&1
        sleep 1
        systemctl enable --now tproxy-router > /dev/null 2>&1
        nft flush ruleset > /dev/null 2>&1
        nft -f /etc/nftables.conf > /dev/null 2>&1
        systemctl enable --now nftables > /dev/null 2>&1
        echo -e "请使用 ${yellow_text}proxytool${reset} ${green_text}管理mihomo${reset}"
        echo "=================================================================="
        echo -e "\t\t\tMihomo 安装完毕"
        echo -e "\t\t\tPowered by www.herozmy.com 2025"
        echo -e "\n"
        echo -e "Mihomo运行目录为/etc/mihomo"
        echo -e "Mihomo WebUI地址:${green_text}http://${local_ip}:9090${reset}"
        echo -e "本脚本仅适用于学习与研究等个人用途，请勿用于任何违反国家法律的活动！"
        echo "=================================================================="
        exit 0
        ;;

esac
    rm -rf /root/sing-box*
    choose_singbox
    install_josn_config
    check_resolved
    sleep 1
    echo -e "${yellow}配置系统服务文件${reset}"
    sleep 1
    cp $DIRPATH/sing-box.service /etc/systemd/system/
    echo -e "${green_text}sing-box 服务创建完成${reset}"
    echo -e "${yellow}配置tproxy${reset}"
    sleep 1
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
    cp $DIRPATH/tproxy-router.service /etc/systemd/system/
    sleep 1
    echo -e "${green_text}tproxy-router 服务创建完成"
    sleep 1
    sleep 1
    ####写入nftables
    echo "" > "/etc/nftables.conf"
    cat $DIRPATH/nft-tproxy-redirect.conf >> "/etc/nftables.conf"
    check_interfaces
    echo -e "修正nftables规则"
    sed -i "s/eth0/${interface_name}/g" "/etc/nftables.conf"
    echo -e "${green_text}nftables 规则写入完成${reset}"
    sleep 1
    echo -e "拉取sing-box UI管理界面"
    check_ui
    bash /usr/local/bin/tools/check_aio.sh
    echo -e "${green_text}启用相关服务${reset}"
    systemctl enable --now sing-box  > /dev/null 2>&1
    sleep 2
    systemctl enable --now tproxy-router > /dev/null 2>&1
    nft flush ruleset > /dev/null 2>&1
    nft -f /etc/nftables.conf > /dev/null 2>&1
    systemctl enable --now nftables > /dev/null 2>&1
    echo "=================================================================="
    echo -e "\t\t\tSing-box 安装完毕"
    echo -e "\t\t\tPowered by www.herozmy.com 2025"
    echo -e "\n"

    echo -e "Sing-box运行目录为/etc/sing-box"
    echo -e "Sing-box WebUI地址:${green_text}http://${local_ip}:9090${reset}"
    echo -e "本脚本仅适用于学习与研究等个人用途，请勿用于任何违反国家法律的活动！"
    echo "=================================================================="
    echo -e "${green_text}请使用${reset} ${yellow_text}systemctl start sing-box${reset} ${green_text}启动服务${reset}"
    echo -e "${green_text}请使用${reset} ${yellow_text}systemctl enable sing-box${reset} ${green_text}设置开机自启${reset}"
    echo -e "${green_text}请使用${reset} ${yellow_text}systemctl status sing-box${reset} ${green_text}查看服务状态${reset}"
    echo -e "${green_text}请使用${reset} ${yellow_text}systemctl restart sing-box${reset} ${green_text}重启服务${reset}"
    echo -e "${green_text}请使用${reset} ${yellow_text}systemctl stop sing-box${reset} ${green_text}停止服务${reset}"
    echo -e "${green_text}请使用${reset} ${yellow_text}systemctl disable sing-box${reset} ${green_text}禁用开机自启${reset}"
    echo -e "${green_text}请使用${reset} ${yellow_text}systemctl restart nftables${reset} ${green_text}重启nftables${reset}"
    echo -e "${green_text}请使用${reset} ${yellow_text}systemctl status nftables${reset} ${green_text}查看nftables状态${reset}"
    echo -e "${green_text}请使用${reset} ${yellow_text}systemctl restart tproxy-router${reset} ${green_text}重启路由${reset}"
    echo -e "${green_text}请使用${reset} ${yellow_text}systemctl status tproxy-router${reset} ${green_text}查看路由状态${reset}" 
	echo -----------------------------------------------
	echo -e "${green_text}请使用${reset} ${yellow_text}proxytool${reset} ${green_text}管理sing-box${reset}"
	echo ----------------------------------------------- 
    

