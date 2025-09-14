#!/bin/bash -e

build_dir=/opt/build
# Support for Pterodactyl panel - use /home/container if /opt/server is not mounted
if [[ -d /home/container && ! $(mount | grep /opt/server) ]]; then
    mounted_dir=/home/container
    echo "Detected Pterodactyl environment, using /home/container as server directory"
else
    mounted_dir=/opt/server
fi
spt_binary=SPT.Server.exe
uid=${UID:-1000}
gid=${GID:-1000}

backup_dir_name=${BACKUP_DIR:-backups}
backup_dir=$mounted_dir/$backup_dir_name

spt_version=${SPT_VERSION:-3.11.3}
spt_version=$(echo $spt_version | cut -d '-' -f 1)
spt_backup_dir=$backup_dir/spt/$(date +%Y%m%dT%H%M)
spt_data_dir=$mounted_dir/SPT_Data
spt_core_config=$spt_data_dir/Server/configs/core.json
enable_spt_listen_on_all_networks=${LISTEN_ALL_NETWORKS:-false}

fika_version=${FIKA_VERSION:-v2.4.8}
install_fika=${INSTALL_FIKA:-false}
fika_backup_dir=$backup_dir/fika/$(date +%Y%m%dT%H%M)
fika_config_path=assets/configs/fika.jsonc
fika_mod_dir=$mounted_dir/user/mods/fika-server
fika_artifact=fika-server-$(echo $fika_version | cut -d 'v' -f 2).zip
fika_release_url="http://gh.halonice.com/https://github.com/project-fika/Fika-Server/releases/download/$fika_version/$fika_artifact"

auto_update_spt=${AUTO_UPDATE_SPT:-false}
auto_update_fika=${AUTO_UPDATE_FIKA:-false}

take_ownership=${TAKE_OWNERSHIP:-true}
change_permissions=${CHANGE_PERMISSIONS:-true}
enable_profile_backup=${ENABLE_PROFILE_BACKUP:-true}

num_headless_profiles=${NUM_HEADLESS_PROFILES:+"$NUM_HEADLESS_PROFILES"}

install_other_mods=${INSTALL_OTHER_MODS:-false}

# Check if running in Pterodactyl environment
is_pterodactyl_env() {
    [[ "$mounted_dir" == "/home/container" ]]
}

start_crond() {
    if is_pterodactyl_env; then
        echo "跳过cron服务在Pterodactyl环境中（没有对/var/run的写入权限）"
        return
    fi
    echo "启用配置文件备份的cron守护进程"
    /etc/init.d/cron start
}

create_running_user() {
    if is_pterodactyl_env; then
        echo "跳过用户创建在Pterodactyl环境中（使用容器用户）"
        return
    fi
    echo "检查运行中的用户/组: $uid:$gid"
    getent group $gid || groupadd -g $gid spt
    if [[ ! $(id -un $uid) ]]; then
        echo "用户未找到，正在创建用户'spt'，ID为$uid"
        useradd --create-home -u $uid -g $gid spt
    fi
}

validate() {
    if [[ ${num_headless_profiles:+1} && ! $num_headless_profiles =~ ^[0-9]+$ ]]; then
        echo "版本设置中 NUM_HEADLESS_PROFILES 必须是一个数字。";
        exit 1
    fi

    # Must mount /opt/server directory, otherwise the serverfiles are in container and there's no persistence
    # Exception: In Pterodactyl environment, /home/container is acceptable
    if [[ ! $(mount | grep $mounted_dir) && "$mounted_dir" != "/home/container" ]]; then
       echo "请将主机上的卷/目录挂载到 $mounted_dir。此服务器容器必须在主机上存储文件。"
       echo "您可以使用docker run的-v标志来做到这一点，例如'-v /path/on/host:/opt/server'"
       echo "或使用docker-compose的'volumes'指令"
       echo "注意：在Pterodactyl面板环境中，此检查被绕过，使用/home/container"
       exit 1
    fi

    # Validate SPT version
    if [[ -d $spt_data_dir && -f $spt_core_config ]]; then
       echo "验证 SPT 版本"
       existing_spt_version=$(jq -r '.sptVersion' $spt_core_config)
       if [[ $existing_spt_version != "$spt_version" ]]; then
          try_update_spt $existing_spt_version
       fi
    fi

    # Validate fika version
    if [[ -d $fika_mod_dir && -f $fika_mod_dir/package.json && $install_fika == "true" ]]; then
       echo "验证 Fika 版本"
       existing_fika_version=$(jq -r '.version' $fika_mod_dir/package.json)
       if [[ "v$existing_fika_version" != $fika_version ]]; then
          try_update_fika "v$existing_fika_version"
       fi
    fi
}

make_and_own_spt_dirs() {
    mkdir -p $mounted_dir/user/mods
    mkdir -p $mounted_dir/user/profiles
    change_owner
    set_permissions
}

change_owner() {
    if is_pterodactyl_env; then
        echo "跳过在Pterodactyl环境中的所有权更改（没有chown权限）"
        return
    fi
    if [[ "$take_ownership" == "true" ]]; then
        echo "正在将服务器文件的所有者更改为 $uid:$gid"
        chown -R ${uid}:${gid} $mounted_dir
    fi
}

set_permissions() {
    if is_pterodactyl_env; then
        echo "跳过在Pterodactyl环境中的权限更改（使用容器权限）"
        return
    fi
    if [[ "$change_permissions" == "true" ]]; then
        echo "正在将服务器文件的权限更改为 user+rwx, group+rwx, others+rx"
        # owner(u), (g)roup, (o)ther
        # (r)ead, (w)rite, e(x)ecute
        chmod -R u+rwx,g+rwx,o+rx $mounted_dir
    fi
}

set_timezone() {
    # If the TZ environment variable has been set, use it
    if [[ ! -z "${TZ}" ]]; then
        # In Pterodactyl environment, skip writing to read-only /etc/timezone
        if ! is_pterodactyl_env; then
            echo $TZ > /etc/timezone
        fi
    else
        # Grab the hour from the date command to compare against later
        before_date_hour=$(date +"%H")

        # Set TZ to the /etc/timezone, either mounted or the default from the container
        TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    fi

    # Force update the symlink (skip if in Pterodactyl and no write permissions)
    if is_pterodactyl_env; then
        echo "跳过在Pterodactyl环境中的时区符号链接更新（只读文件系统）"
        echo "使用时区: ${TZ:-UTC}"
    else
        ln -sf /usr/share/zoneinfo/$TZ /etc/localtime
        # If there was actually a change in the timezone or TZ was specified
        if [[ $before_date_hour != $(date +"%H") ]]; then
            echo "时区设置为 $TZ";
        fi
    fi
}

########
# Fika #
########
# Fika #
########

# 检查下载前置条件
check_download_prerequisites() {
    local target_file="$1"
    local min_space_mb=100  # 至少需要100MB空间
    
    echo "检查下载前置条件..."
    
    # 检查磁盘空间
    if command -v df >/dev/null 2>&1; then
        available_space=$(df . 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
        # 将KB转换为MB (除以1024)
        available_space_mb=$((available_space / 1024))
        echo "可用磁盘空间: ${available_space_mb}MB"
        
        if [ $available_space_mb -lt $min_space_mb ]; then
            echo "错误：磁盘空间不足！需要至少 ${min_space_mb}MB，但只有 ${available_space_mb}MB"
            return 1
        fi
    else
        echo "警告：无法检查磁盘空间"
    fi
    
    # 检查目录写入权限
    test_file="test_write_$$"
    if ! touch "$test_file" 2>/dev/null; then
        echo "错误：当前目录无写入权限"
        echo "当前目录: $(pwd)"
        echo "当前用户: $(whoami 2>/dev/null || echo "unknown")"
        return 1
    fi
    rm -f "$test_file"
    
    # 检查网络连接
    echo "检查网络连接..."
    if ! curl -s --connect-timeout 10 --max-time 15 -I "https://github.com" >/dev/null 2>&1; then
        echo "警告：无法连接到GitHub，可能存在网络问题"
        # 不直接返回错误，因为可能是暂时性问题
    fi
    
    echo "下载前置条件检查完成"
    return 0
}

install_fika_mod() {
    echo "安装 Fika servermod 版本 $fika_version"
    echo "Fika release URL: $fika_release_url"
    # Assumes fika_server.zip artifact contains user/mods/fika-server
    
    # 运行下载前置条件检查
    if ! check_download_prerequisites "$fika_artifact"; then
        echo "错误：下载前置条件不满足，中止安装"
        exit 1
    fi
    
    # 检查磁盘空间和权限
    echo "检查系统状态..."
    echo "当前工作目录: $(pwd)"
    echo "磁盘空间使用情况:"
    df -h . 2>/dev/null || echo "无法获取磁盘空间信息"
    echo "目录权限: $(ls -ld . 2>/dev/null || echo "无法获取权限信息")"
    
    # 确保工作目录可写
    if ! touch test_write_$$ 2>/dev/null; then
        echo "错误：无法在当前目录创建文件，检查权限"
        echo "当前目录: $(pwd)"
        echo "当前用户: $(whoami 2>/dev/null || echo "unknown")"
        exit 1
    fi
    rm -f test_write_$$
    
    # 增加更多curl日志和错误处理
    echo "正在下载 Fika 服务器模组..."
    echo "目标文件路径: $(pwd)/$fika_artifact"
    
    # 尝试下载，并提供更详细的错误信息
    if ! curl -sL --fail --show-error --connect-timeout 30 --max-time 300 -o "$fika_artifact" "$fika_release_url"; then
        curl_exit_code=$?
        echo "错误：下载 Fika 服务器模组失败"
        echo "URL: $fika_release_url"
        echo "目标文件: $fika_artifact"
        echo "curl 退出代码: $curl_exit_code"
        
        # 提供针对性的解决建议
        case $curl_exit_code in
            23)
                echo "错误代码 23: 无法写入目标文件"
                echo "可能的原因："
                echo "  1. 磁盘空间不足"
                echo "  2. 目录权限不足"
                echo "  3. 文件系统只读"
                echo "  4. 目标路径不存在"
                ;;
            6)
                echo "错误代码 6: 无法解析主机"
                ;;
            7)
                echo "错误代码 7: 无法连接到服务器"
                ;;
            22)
                echo "错误代码 22: HTTP 错误（可能是 404 Not Found）"
                ;;
            28)
                echo "错误代码 28: 操作超时"
                ;;
            *)
                echo "其他错误，请检查网络连接和权限"
                ;;
        esac
        
        echo "诊断信息："
        echo "  磁盘空间: $(df -h . 2>/dev/null | tail -1 || echo "无法获取")"
        echo "  工作目录: $(pwd)"
        echo "  目录权限: $(ls -ld . 2>/dev/null || echo "无法获取")"
        
        # 尝试备用下载方法
        echo ""
        echo "尝试备用下载方法..."
        
        # 方法1: 尝试直接从GitHub下载（去掉代理）
        direct_url="https://github.com/project-fika/Fika-Server/releases/download/$fika_version/$fika_artifact"
        echo "尝试直接从GitHub下载: $direct_url"
        if curl -sL --fail --show-error --connect-timeout 30 --max-time 300 -o "$fika_artifact" "$direct_url"; then
            echo "备用下载方法成功！"
        else
            echo "直接下载也失败了"
            
            # 方法2: 尝试使用wget
            if command -v wget >/dev/null 2>&1; then
                echo "尝试使用 wget 下载..."
                if wget -q --timeout=30 -O "$fika_artifact" "$fika_release_url" || wget -q --timeout=30 -O "$fika_artifact" "$direct_url"; then
                    echo "wget 下载成功！"
                else
                    echo "wget 下载也失败了"
                    echo ""
                    echo "所有下载方法都失败了。请手动解决以下问题："
                    echo "1. 检查磁盘空间是否充足"
                    echo "2. 检查目录权限"
                    echo "3. 检查网络连接"
                    echo "4. 验证URL是否有效: $fika_release_url"
                    exit 1
                fi
            else
                echo ""
                echo "所有下载方法都失败了。请手动解决以下问题："
                echo "1. 检查磁盘空间是否充足"
                echo "2. 检查目录权限"
                echo "3. 检查网络连接"
                echo "4. 验证URL是否有效: $fika_release_url"
                exit 1
            fi
        fi
    fi
    echo "Fika 服务器模组下载完成"
    echo "解压 Fika servermod"
    unzip -q $fika_artifact -d $mounted_dir
    echo "正在删除 Fika servermod 工件"
    rm $fika_artifact
    echo "----安装完成---"
}

backup_fika() {
    mkdir -p $fika_backup_dir
    cp -r $fika_mod_dir $fika_backup_dir
}

try_update_fika() {
    if [[ "$auto_update_fika" != "true" ]]; then
        echo "Fika 版本不匹配: 请求安装 Fika，但现有的 Fika mod 服务器是 v$existing_fika_version，而此镜像期望 $fika_version"
        echo "如果您希望使用此容器来更新您的 Fika 服务器 mod，请将 AUTO_UPDATE_FIKA 设置为 true"
        echo "中止"
        exit 1
    fi

    echo "更新 Fika servermod in place, from $1 to $fika_version"
    # Backup entire fika servermod, then delete and update servermod
    backup_fika
    rm -r $fika_mod_dir
    install_fika_mod
    # restore config
    mkdir -p $fika_mod_dir/assets/configs
    cp $fika_backup_dir/fika-server/$fika_config_path $fika_mod_dir/$fika_config_path
    echo "成功将 Fika 从 $1 更新到 $fika_version"
}

set_num_headless_profiles() {
    if [[ ${num_headless_profiles:+1} && -f $fika_mod_dir/$fika_config_path ]]; then
        echo "将无头配置文件的数量设置为 $num_headless_profiles"
        modified_fika_jsonc="$(jq --arg jq_num_headless_profiles $num_headless_profiles '.headless.profiles.amount=$jq_num_headless_profiles' $fika_mod_dir/$fika_config_path)" && echo -E "${modified_fika_jsonc}" > $fika_mod_dir/$fika_config_path
    fi
}

#######
# SPT #
#######
install_spt() {
    # Remove the SPT_Data server, since databases tend to be different between versions
    rm -rf $mounted_dir/SPT_Data
    cp -r $build_dir/* $mounted_dir
    make_and_own_spt_dirs
}

# TODO Anticipate BepInEx too, for Corter-ModSync
backup_spt_user_dirs() {
    mkdir -p $spt_backup_dir
    cp -r $mounted_dir/user $spt_backup_dir/
}

try_update_spt() {
    if [[ "$auto_update_spt" != "true" ]]; then
        echo "SPT 版本不匹配: 现有服务器文件是 SPT $existing_spt_version，而此镜像期望 $spt_version"
        echo "如果您希望使用此容器来更新您的 SPT 服务器文件，请将 AUTO_UPDATE_SPT 设置为 true"
        echo "中止"
        exit 1
    fi

    echo "更新 SPT in-place, from $1 to $spt_version"
    # Backup SPT, install new version, then halt
    backup_spt_user_dirs
    install_spt
    echo "SPT 更新完成。我们从 $1 移动到 $spt_version"
    echo "  "
    echo "  ==============="
    echo "  === WARNING ==="
    echo "  ==============="
    echo ""
    echo "  The user/ folder has been backed up to $spt_backup_dir, but otherwise has been LEFT UNTOUCHED in the server dir."
    echo "  Please verify your existing mods and profile work with this new SPT version! You may want to delete the mods directory and start from scratch"
    echo "  Restart this container to bring the server back up"
    echo ""
    echo "  ==============="
    echo "  === WARNING ==="
    echo "  ==============="
    exit 0
}

spt_listen_on_all_networks() {
    # Changes the ip and backendIp to 0.0.0.0 so that the server will listen on all network interfaces.
    http_json=$mounted_dir/SPT_Data/Server/configs/http.json
    modified_http_json="$(jq '.ip = "0.0.0.0" | .backendIp = "0.0.0.0"' $http_json)" && echo -E "${modified_http_json}" > $http_json
    # If fika server config exists, modify that too
    if [[ -f "$fika_mod_dir/$fika_config_path" ]]; then
        echo "设置 Fika SPT 配置覆盖中的所有网络监听"
        modified_fika_jsonc="$(jq '.server.SPT.http.ip = "0.0.0.0" | .server.SPT.http.backendIp = "0.0.0.0"' $fika_mod_dir/$fika_config_path)" && echo -E "${modified_fika_jsonc}" > $fika_mod_dir/$fika_config_path
    fi
}

##############
# Other Mods #
##############

install_requested_mods() {
    # Run the download & install mods script
    echo "下载并安装其他模组"
    /usr/bin/download_unzip_install_mods $mounted_dir
}

##############
# Run it All #
##############

validate

# If no server binary in this directory, copy our built files in here and run it once
if [[ ! -f "$mounted_dir/$spt_binary" ]]; then
    echo "未找到服务器文件，正在初始化第一次启动..."
    install_spt
else
    echo "找到服务器文件，跳过初始化"
fi

# Install listen on all interfaces is requested.
if [[ "$enable_spt_listen_on_all_networks" == "true" ]]; then
    spt_listen_on_all_networks
fi

# Install fika if requested. Run each boot to support installing in existing serverfiles that don't have fika installed
if [[ "$install_fika" == "true" ]]; then
    if [[ ! -d $fika_mod_dir || ! -f $fika_mod_dir/package.json ]]; then
        echo "没有检测到Fika服务器mod，安装请求已发出。开始安装。"
        install_fika_mod
    else
        echo "请求安装Fika，但Fika服务器mod目录已存在，跳过Fika安装"
    fi
fi

set_num_headless_profiles

if [[ "$install_other_mods" == "true" ]]; then
    install_requested_mods
fi

if [[ "$enable_profile_backup" == "true" ]]; then
    start_crond
fi

create_running_user

# Own mounted files as running user
change_owner
set_permissions

set_timezone

# Run the server
if is_pterodactyl_env; then
    echo "在 Pterodactyl 环境中启动 SPT 服务器"

    # Create a temporary passwd entry to fix Node.js user lookup
    current_uid=$(id -u)
    current_gid=$(id -g)
    current_user=$(whoami 2>/dev/null || echo "container")
    
    # Create temporary passwd file if it doesn't contain current user
    if ! getent passwd $current_uid >/dev/null 2>&1; then
        echo "创建临时用户条目以兼容 Node.js"
        # Create a temporary passwd file
        temp_passwd="/tmp/passwd"
        cp /etc/passwd "$temp_passwd" 2>/dev/null || touch "$temp_passwd"
        echo "${current_user}:x:${current_uid}:${current_gid}:Container User:/home/container:/bin/bash" >> "$temp_passwd"
        export NSS_WRAPPER_PASSWD="$temp_passwd"
        export NSS_WRAPPER_GROUP="/etc/group"
        
        # Preload NSS wrapper
        export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libnss_wrapper.so"
    fi
    
    # Set environment variables to handle missing user info in Pterodactyl
    export HOME=${HOME:-/home/container}
    export USER=${USER:-$current_user}
    export LOGNAME=${LOGNAME:-$current_user}
    export SHELL=${SHELL:-/bin/bash}
    
    cd $mounted_dir && ./SPT.Server.exe
else
    su - $(id -nu $uid) -c "cd $mounted_dir && ./SPT.Server.exe"
fi
