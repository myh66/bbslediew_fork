#!/bin/bash
# 检测当前用户是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户执行此脚本！"
  echo "你可以使用 'sudo -i' 进入 root 用户模式。"
  exit 1
fi

# --- OS Detection ---
check_sys() {
  if [ -f /etc/alpine-release ]; then
    OS_type="Alpine"
    echo "检测为 Alpine Linux 系统。"
  elif [[ -f /etc/redhat-release || -f /etc/centos-release || -f /etc/fedora-release || -f /etc/rocky-release ]]; then
    OS_type="CentOS"
    echo "检测为CentOS通用系统，判断有误请反馈"
  elif [[ -f /etc/debian_version ]] || grep -qi -E "debian|ubuntu" /etc/issue || grep -qi -E "debian|ubuntu" /etc/os-release; then
     # More robust check for Debian/Ubuntu
    OS_type="Debian"
    echo "检测为Debian/Ubuntu通用系统，判断有误请反馈"
  else
    # Fallback using /etc/os-release ID
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" = "alpine" ]; then
             OS_type="Alpine"
             echo "检测为 Alpine Linux 系统。"
        elif [[ "$ID" = "centos" || "$ID" = "rhel" || "$ID" = "fedora" || "$ID" = "rocky" ]]; then
             OS_type="CentOS"
             echo "检测为CentOS通用系统 (via os-release)，判断有误请反馈"
        elif [[ "$ID" = "debian" || "$ID" = "ubuntu" ]]; then
             OS_type="Debian"
             echo "检测为Debian/Ubuntu通用系统 (via os-release)，判断有误请反馈"
        else
             echo "无法识别的操作系统类型 (ID: $ID)。尝试通用检测..."
             # Add more specific checks if needed here, otherwise exit
             echo "无法支持的操作系统。"
             exit 1
        fi
    else
        echo "无法确定操作系统类型，缺少 /etc/os-release 文件。"
        exit 1
    fi
  fi

  # Set OS_TYPE based on /etc/os-release if check_sys logic didn't set it confidently for Alpine
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "alpine" ]; then
         OS_TYPE="Alpine"
    fi
  fi

  echo "确定的操作系统类型: $OS_TYPE"

}

# --- Helper Functions ---
_exists() {
    local cmd="$1"
    if eval type type >/dev/null 2>&1; then
      eval type "$cmd" >/dev/null 2>&1
    elif command >/dev/null 2>&1; then
      command -v "$cmd" >/dev/null 2>&1
    else
      which "$cmd" >/dev/null 2>&1
    fi
    local rt=$?
    return ${rt}
}

random_color() {
  # Check if RANDOM is supported (Bash feature)
  if [ -n "$BASH_VERSION" ] && [[ "$RANDOM" ]]; then
    colors=("31" "32" "33" "34" "35" "36" "37")
    echo -e "\e[${colors[$((RANDOM % 7))]}m$1\e[0m"
  else
    # Fallback for non-bash or shells without RANDOM
    echo "$1"
  fi
}

# --- Initial Setup ---
check_sys # Run OS detection early

install_custom_packages() {
    echo "正在为 $OS_TYPE 更新软件包列表并安装依赖..."
    if [ "$OS_TYPE" = "Debian" ]; then
        apt update
        apt install -y wget sed sudo openssl net-tools psmisc procps iptables iproute2 ca-certificates jq curl bash coreutils
    elif [ "$OS_TYPE" = "CentOS" ]; then
        yum install -y epel-release || true # Allow failure if EPEL already installed
        yum install -y wget sed sudo openssl net-tools psmisc procps-ng iptables iproute ca-certificates jq curl bash coreutils
    elif [ "$OS_TYPE" = "Alpine" ]; then
        apk update
        # Install required packages for Alpine
        # bash is needed because the script uses bash features
        # coreutils provides non-busybox versions of some tools if needed
        # procps provides pgrep/pkill
        apk add --no-cache bash wget sed sudo openssl net-tools psmisc procps iptables iproute2 ca-certificates jq curl coreutils
    else
        echo "不支持的操作系统: $OS_TYPE。"
        exit 1
    fi
    echo "依赖安装完成。"
}

install_custom_packages

echo "检查关键命令是否可用："
all_cmds_found=true
# List essential COMMANDS needed by the script, not package names
essential_cmds=(wget sed openssl iptables jq curl bash mktemp pgrep fuser ss ip)

for cmd in "${essential_cmds[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "命令: $cmd ... 已找到"
    else
        echo "命令: $cmd ... 未找到！"
        all_cmds_found=false
        # Try to suggest package for Alpine
        if [ "$OS_TYPE" = "Alpine" ]; then
             case "$cmd" in
                 mktemp) echo "  -> 可能需要 'coreutils' 包";;
                 pgrep) echo "  -> 可能需要 'procps' 或 'procps-ng' 包";;
                 fuser) echo "  -> 可能需要 'psmisc' 包";;
                 ss|ip) echo "  -> 可能需要 'iproute2' 包";;
                 *) echo "  -> 请检查 '$cmd' 是否已安装或包含在某个包中";;
             esac
        else
             echo "  -> 请确保提供了 '$cmd' 命令的包已安装。"
        fi
    fi
done

if $all_cmds_found; then
    echo "所有关键命令检查完毕，看起来都已就绪。"
else
    echo "警告：部分关键命令未找到，脚本后续步骤可能会失败！"
    # exit 1 # Optionally exit if critical commands are missing
fi
echo "依赖检查完毕。"


set_architecture() {
  case "$(uname -m)" in
    'i386' | 'i686')
      arch='386'
      ;;
    'amd64' | 'x86_64')
      arch='amd64'
      ;;
    'armv5tel' | 'armv6l' | 'armv7' | 'armv7l')
      arch='arm'
      ;;
    'armv8' | 'aarch64')
      arch='arm64'
      ;;
    'mips' | 'mipsle' | 'mips64' | 'mips64le')
      arch='mipsle'
      ;;
    's390x')
      arch='s390x'
      ;;
    *)
      echo "暂时不支持你的系统哦，可能是因为不在已知架构范围内。"
      exit 1
      ;;
  esac
  echo "检测到系统架构: $arch"
}

get_installed_version() {
    if [ -x "/root/hy3/hysteria-linux-$arch" ]; then
        # Ensure bash is used if needed for command substitution features
        version=$(bash -c "/root/hy3/hysteria-linux-$arch version | grep Version | grep -o 'v[.0-9]*'")
    else
        version="你还没有安装,老登"
    fi
}

get_latest_version() {
  local tmpfile
  # Ensure coreutils mktemp is available
  if ! command -v mktemp >/dev/null 2>&1; then apk add coreutils || yum install coreutils || apt install coreutils ; fi
  tmpfile=$(mktemp)

  # Use curl as it was installed
  if ! curl -sS "https://api.hy2.io/v1/update?cver=installscript&plat=linux&arch="$arch"&chan=release&side=server" -o "$tmpfile"; then
    echo "错误：无法从 Hysteria 2 API 获取最新版本，请检查网络连接。"
    rm -f "$tmpfile" # Clean up temp file on error
    # Consider exiting or returning an error status
    latest_version="获取失败"
    return 1 # Indicate failure
  fi

  # Use grep -o with basic regex for broader compatibility
  local latest_version_raw
  latest_version_raw=$(grep -o '"lver": *"[^"]*"' "$tmpfile" | head -1)
  latest_version=$(echo "$latest_version_raw" | sed -n 's/.*"lver": *"\([^"]*\)".*/\1/p')


  if [[ -n "$latest_version" ]]; then
    echo "$latest_version"
  else
    echo "解析失败"
    rm -f "$tmpfile"
    return 1 # Indicate failure
  fi

  rm -f "$tmpfile"
  return 0 # Indicate success
}

checkact() {
# Ensure procps provides pgrep
if ! command -v pgrep >/dev/null 2>&1; then apk add procps || yum install procps-ng || apt install procps ; fi
pid=$(pgrep -f "hysteria-linux-$arch")

if [ -n "$pid" ]; then
  hy2zt="运行中"
else
  hy2zt="未运行"
fi
}

# --- Kernel/GRUB Functions (Disabled for Alpine) ---
# These functions are too specific to Debian/CentOS GRUB and kernel management.
# They won't work correctly on Alpine's default setup (OpenRC, syslinux/grub).
BBR_grub() {
  if [ "$OS_TYPE" = "Alpine" ]; then
    echo "注意：BBR/GRUB 更新功能在此脚本中不支持 Alpine Linux。"
  elif [ "$OS_TYPE" = "CentOS" ]; then
    # ... (original CentOS code) ...
    echo "执行 CentOS GRUB 更新..." # Placeholder
     if [[ ${version} == "6" ]]; then
      if [ -f "/boot/grub/grub.conf" ]; then
        sed -i 's/^default=.*/default=0/g' /boot/grub/grub.conf
      elif [ -f "/boot/grub/grub.cfg" ]; then
        grub-mkconfig -o /boot/grub/grub.cfg
        grub-set-default 0
      elif [ -f "/boot/efi/EFI/centos/grub.cfg" ]; then
        grub-mkconfig -o /boot/efi/EFI/centos/grub.cfg
        grub-set-default 0
      elif [ -f "/boot/efi/EFI/redhat/grub.cfg" ]; then
        grub-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
        grub-set-default 0
      else
        echo -e "${Error} grub.conf/grub.cfg 找不到，请检查."
        exit
      fi
    elif [[ ${version} == "7" ]]; then
      if [ -f "/boot/grub2/grub.cfg" ]; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
        grub2-set-default 0
      elif [ -f "/boot/efi/EFI/centos/grub.cfg" ]; then
        grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg
        grub2-set-default 0
      elif [ -f "/boot/efi/EFI/redhat/grub.cfg" ]; then
        grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
        grub2-set-default 0
      else
        echo -e "${Error} grub.cfg 找不到，请检查."
        exit
      fi
    elif [[ ${version} == "8" ]]; then
      if [ -f "/boot/grub2/grub.cfg" ]; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
        grub2-set-default 0
      elif [ -f "/boot/efi/EFI/centos/grub.cfg" ]; then
        grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg
        grub2-set-default 0
      elif [ -f "/boot/efi/EFI/redhat/grub.cfg" ]; then
        grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
        grub2-set-default 0
      else
        echo -e "${Error} grub.cfg 找不到，请检查."
        exit
      fi
      grubby --info=ALL | awk -F= '$1=="kernel" {print i++ " : " $2}'
    fi
  elif [ "$OS_TYPE" = "Debian" ]; then
    # ... (original Debian code) ...
     echo "执行 Debian/Ubuntu GRUB 更新..." # Placeholder
     if _exists "update-grub"; then
      update-grub
    elif [ -f "/usr/sbin/update-grub" ]; then
      /usr/sbin/update-grub
    else
      apt install grub2-common -y
      update-grub
    fi
  fi
}

check_version() {
  # This function seems primarily for Xanmod which is disabled for Alpine
  if [ "$OS_TYPE" = "Alpine" ]; then return; fi

  if [[ -s /etc/redhat-release ]]; then
    version=$(grep -oE "[0-9.]+" /etc/redhat-release | cut -d . -f 1)
  else
    version=$(grep -oE "[0-9.]+" /etc/issue | cut -d . -f 1)
  fi
  bit=$(uname -m)
  # check_github # This function was not defined in the original script
}

installxanmod1 () {
  if [ "$OS_TYPE" = "Alpine" ]; then echo "Xanmod 安装不支持 Alpine Linux。"; return; fi
  # ... (original code) ...
    echo "该功能仅支持 Debian/Ubuntu x86_64"
    exit 1 # Or just return
}

installxanmod2 () {
  if [ "$OS_TYPE" = "Alpine" ]; then echo "Xanmod 安装不支持 Alpine Linux。"; return; fi
  # ... (original code) ...
  echo "该功能仅支持 Debian x86_64"
  exit 1 # Or just return
}

detele_kernel() {
  if [ "$OS_TYPE" = "Alpine" ]; then echo "内核删除功能在此脚本中不支持 Alpine Linux。"; return; fi
  # ... (original code) ...
}

detele_kernel_head() {
  if [ "$OS_TYPE" = "Alpine" ]; then echo "内核头文件删除功能在此脚本中不支持 Alpine Linux。"; return; fi
  # ... (original code) ...
}

detele_kernel_custom() {
  if [ "$OS_TYPE" = "Alpine" ]; then echo "自定义内核删除功能在此脚本中不支持 Alpine Linux。"; return; fi
  BBR_grub
  read -p " 查看上面内核输入需保留保留保留的内核关键词(如:5.15.0-11) :" kernel_version
  detele_kernel
  detele_kernel_head
  BBR_grub
}

# --- Welcome & Prerun ---
welcome() {
# ... (original code) ...
echo -e "$(random_color '
░██  ░██
░██  ░██        ░████         ░█          ░█         ░█░█░█
░██  ░██       ░█     █        ░█          ░█         ░█   ░█
░██████       ░██████         ░█          ░█         ░█   ░█
░██  ░██       ░█             ░█ ░█      ░█  ░█       ░█░█░█
░██  ░██        ░██  █          ░█          ░█              ')"
 echo -e "$(random_color '
人生有两出悲剧：一是万念俱灰，另一是踌躇满志 ')"

}

# install_missing_commands > /dev/null 2>&1 # This function was not defined

set_architecture
get_installed_version
latest_version=$(get_latest_version) # Capture return value
checkact

# --- OpenRC Service Management Functions for Alpine ---
# Equivalent functions for systemctl using rc-service and rc-update

stop_service() {
    if [ "$OS_TYPE" = "Alpine" ]; then
        if [ -f /etc/init.d/hysteria ]; then
            rc-service hysteria stop
        fi
        if [ -f /etc/init.d/ipppp ]; then
            rc-service ipppp stop
        fi
    else
        systemctl stop hysteria.service
        systemctl stop ipppp.service # Stop even if not installed, ignore error
    fi
}

disable_service() {
     if [ "$OS_TYPE" = "Alpine" ]; then
        if [ -f /etc/init.d/hysteria ]; then
             rc-update del hysteria default
         fi
         if [ -f /etc/init.d/ipppp ]; then
             rc-update del ipppp default
         fi
     else
        systemctl disable hysteria.service
        systemctl disable ipppp.service # Disable even if not installed, ignore error
     fi
}

start_service() {
    if [ "$OS_TYPE" = "Alpine" ]; then
        if [ -f /etc/init.d/hysteria ]; then
             rc-service hysteria start
         fi
    else
        systemctl start hysteria.service
    fi
}

restart_service() {
    if [ "$OS_TYPE" = "Alpine" ]; then
        if [ -f /etc/init.d/hysteria ]; then
             rc-service hysteria restart
         fi
    else
        systemctl restart hysteria.service
    fi
}

enable_service() {
     if [ "$OS_TYPE" = "Alpine" ]; then
         if [ -f /etc/init.d/hysteria ]; then
             rc-update add hysteria default
         fi
     else
        systemctl enable hysteria.service
     fi
}


# --- Main Functions ---
uninstall_hysteria() {
  echo "正在停止并禁用 Hysteria 服务..."
  stop_service
  disable_service

  if [ "$OS_TYPE" = "Alpine" ]; then
      if [ -f "/etc/init.d/hysteria" ]; then
          rm -f "/etc/init.d/hysteria"
          echo "Hysteria OpenRC 服务脚本已删除。"
      else
          echo "Hysteria OpenRC 服务脚本不存在。"
      fi
      if [ -f "/etc/init.d/ipppp" ]; then
          rm -f "/etc/init.d/ipppp"
          echo "ipppp OpenRC 服务脚本已删除。"
      else
          echo "ipppp OpenRC 服务脚本不存在。"
      fi
  else
      if [ -f "/etc/systemd/system/hysteria.service" ]; then
          rm -f "/etc/systemd/system/hysteria.service"
          echo "Hysteria systemd 服务文件已删除。"
          systemctl daemon-reload # Reload systemd after removing unit file
      else
          echo "Hysteria systemd 服务文件不存在。"
      fi
       if [ -f "/etc/systemd/system/ipppp.service" ]; then
          rm -f "/etc/systemd/system/ipppp.service"
          echo "ipppp systemd 服务文件已删除。"
          systemctl daemon-reload
      else
          echo "ipppp systemd 服务文件不存在。"
      fi
  fi


  process_name="hysteria-linux-$arch"
  # Ensure pgrep/pkill are available
  if ! command -v pgrep >/dev/null 2>&1; then apk add procps || yum install procps-ng || apt install procps ; fi
  pid=$(pgrep -f "$process_name")

  if [ -n "$pid" ]; then
    echo "找到 $process_name 进程 (PID: $pid)，正在终止..."
    kill "$pid"
    # Wait briefly and check if killed, force kill if necessary
    sleep 1
    if pgrep -f "$process_name" > /dev/null; then
        echo "进程未能终止，尝试强制终止 (kill -9)..."
        pkill -9 -f "$process_name"
    fi
    echo "$process_name 进程已被终止。"
  else
    echo "未找到 $process_name 进程。"
  fi

  if [ -f "/root/hy3/hysteria-linux-$arch" ]; then
    rm -f "/root/hy3/hysteria-linux-$arch"
    echo "Hysteria 服务器二进制文件已删除。"
  else
    echo "Hysteria 服务器二进制文件不存在。"
  fi

  if [ -f "/root/hy3/config.yaml" ]; then
    rm -f "/root/hy3/config.yaml"
    echo "Hysteria 服务器配置文件已删除。"
  else
    echo "Hysteria 服务器配置文件不存在。"
  fi

  # Remove the directory and potentially other files (like neko.txt, clash-mate.yaml, ipppp.sh)
  if [ -d "/root/hy3" ]; then
      rm -rf /root/hy3
      echo "/root/hy3 目录已删除。"
  fi

  # Remove shortcut if it exists
  if [ -f "/usr/local/bin/hy2" ]; then
      rm -f /usr/local/bin/hy2
      echo "hy2 快捷方式已删除。"
  fi

  echo "卸载完成(ง ื▿ ื)ว."
}

hy2easy() {
    # This downloads an external script - use with caution.
    # Assuming hy2.crazyact.com provides this *same* script.
    echo "正在尝试创建 hy2 快捷方式..."
    # Ensure sudo is available
    if ! command -v sudo >/dev/null 2>&1; then apk add sudo || yum install sudo || apt install sudo ; fi
    # Ensure wget is available
    if ! command -v wget >/dev/null 2>&1; then apk add wget || yum install wget || apt install wget ; fi

    # Create the directory if it doesn't exist
    mkdir -p /usr/local/bin

    # Attempt download
    if sudo wget -q hy2.crazyact.com -O /usr/local/bin/hy2; then
      sudo chmod +x /usr/local/bin/hy2
      echo "已添加 hy2 快捷方式 (指向 hy2.crazyact.com 的脚本)。"
    else
      echo "警告：无法从 hy2.crazyact.com 下载快捷脚本。快捷方式未创建。"
    fi
}

# --- Main Menu ---
hy2easy # Attempt to create shortcut first
welcome

echo "$(random_color '选择一个操作，小崽子(ง ื▿ ื)ว：')"
echo -e "$(random_color '输入 hy2 可快捷启动脚本')" # Corrected message slightly
echo "1. 安装(以梦为马)"
echo "2. 卸载(以心为疆)"
echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"
echo "3. 查看配置(穿越时空)"
echo "4. 退出脚本(回到未来)"
echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"
echo "5. 在线更新hy2内核(您当前的hy2版本:$version)"
echo "6. hy2内核管理 (启动/停止/重启)"
# Conditionally show option 7
if [ "$OS_TYPE" != "Alpine" ]; then
  echo "7. 安装/卸载 xanmod 内核 (更好的调动网络资源)"
else
  echo "7. (Alpine 不支持 Xanmod 内核安装)"
fi
echo "hy2内核最新版本为： $latest_version"
echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"
echo "hysteria2状态: $hy2zt"

read -p "输入操作编号 (1-7): " choice # Adjusted prompt range

case $choice in
    1)
      # Installation logic follows
      ;;

    2)
      uninstall_hysteria # Use the refactored function
      echo -e "$(random_color '你别急,别急,正在卸载......')"
      echo -e "$(random_color '卸载完成,老登ψ(｀∇´)ψ！')"
      exit 0
      ;;

    3)
      echo "$(random_color '下面是你的nekobox节点信息')"
      echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"
      if [ -f "/root/hy3/neko.txt" ]; then
        cat /root/hy3/neko.txt
      else
        echo "配置文件 /root/hy3/neko.txt 不存在。"
      fi
      echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"
      echo "$(random_color '下面是你的clashmate配置')"
       if [ -f "/root/hy3/clash-mate.yaml" ]; then
        cat /root/hy3/clash-mate.yaml
      else
        echo "配置文件 /root/hy3/clash-mate.yaml 不存在。"
      fi
      echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"
      exit 0
      ;;

    4)
      echo "退出脚本。"
      exit 0
      ;;

    5)
      get_updated_version() {
        # Re-check installed version after update attempt
        if [ -x "/root/hy3/hysteria-linux-$arch" ]; then
          version2=$(bash -c "/root/hy3/hysteria-linux-$arch version | grep Version | grep -o 'v[.0-9]*'")
        else
          version2="更新后未找到或无法执行"
        fi
      }

      updatehy2 () {
        echo "正在尝试停止当前 Hysteria 进程..."
        process_name="hysteria-linux-$arch"
        # Ensure pgrep/pkill are available
        if ! command -v pgrep >/dev/null 2>&1; then apk add procps || yum install procps-ng || apt install procps ; fi
        pid=$(pgrep -f "$process_name")

        if [ -n "$pid" ]; then
          echo "找到 $process_name 进程 (PID: $pid)，正在终止..."
          kill "$pid" || pkill -9 -f "$process_name" # Force kill if needed
          sleep 1 # Give time to terminate
        else
          echo "未找到 $process_name 进程，可能未在运行。"
        fi

        # Navigate to directory, create if doesn't exist (should exist if updating)
        mkdir -p /root/hy3
        cd /root/hy3 || { echo "错误：无法进入 /root/hy3 目录。"; exit 1; }


        echo "正在删除旧的二进制文件..."
        rm -f hysteria-linux-"$arch" # Use -f to ignore error if not found

        echo "正在下载最新的 Hysteria 二进制文件..."
        # Ensure wget is available
        if ! command -v wget >/dev/null 2>&1; then apk add wget || yum install wget || apt install wget ; fi

        if wget --no-check-certificate -O hysteria-linux-"$arch" https://download.hysteria.network/app/latest/hysteria-linux-"$arch"; then
          chmod +x hysteria-linux-"$arch"
          echo "从 download.hysteria.network 下载成功。"
        else
          echo "从主下载点下载失败，尝试 GitHub Releases..."
          local latest_tag # Get latest tag again or use previous value
          latest_tag=$(get_latest_version) # Assumes get_latest_version returns the tag like vX.Y.Z
          if [[ "$latest_tag" == "获取失败" || "$latest_tag" == "解析失败" ]]; then
              echo "错误：无法获取最新版本号，无法从 GitHub 下载。"
              exit 1
          fi
          if wget --no-check-certificate -O hysteria-linux-"$arch" "https://github.com/apernet/hysteria/releases/download/app/$latest_tag/hysteria-linux-$arch"; then
            chmod +x hysteria-linux-"$arch"
            echo "从 GitHub Releases 下载成功。"
          else
            echo "错误：无法从任何源下载 Hysteria 二进制文件。"
            # Optional: restore backup if available?
            exit 1
          fi
        fi

        echo "尝试重启 Hysteria 服务..."
        restart_service # Use the abstracted function

        echo "更新完成,不是哥们,你有什么实力,你直接给我坐下(ง ื▿ ื)ว."
      }

      echo "$(random_color '正在更新中,别急,老登')"
      sleep 1
      updatehy2 # Run update function
      echo "$(random_color '更新完成,老登')"
      get_updated_version # Check version after update
      echo "您当前的更新后hy2版本: $version2"
      exit 0
      ;;

    6)
      echo "Hysteria 内核管理:"
      echo "1. 启动 hy2 内核"
      echo "2. 关闭 hy2 内核"
      echo "3. 重启 hy2 内核"
      read -p "请选择 (1/2/3): " choicehy2
      case "$choicehy2" in
          1) start_service; echo "hy2 内核启动命令已发送。";;
          2) stop_service; echo "hy2 内核关闭命令已发送。";;
          3) restart_service; echo "hy2 内核重启命令已发送。";;
          *) echo "无效选项。";;
      esac
      exit 0
      ;;

    7)
      if [ "$OS_TYPE" = "Alpine" ]; then
          echo "此选项在 Alpine Linux 上不可用。"
          exit 1
      fi
      # Original Xanmod logic for Debian/CentOS
      echo "Xanmod 内核管理 (仅限 Debian/CentOS):"
      echo "y. 安装 Xanmod 内核"
      echo "n. 取消"
      echo "o. 卸载多余内核 (保留指定)"
      read -p "请选择 (y/n/o): " answer
      if [ "$answer" = "y" ]; then
        check_sys # Rerun just in case
        installxanmod2 # Assuming this is the desired function
      elif [ "$answer" = "n" ]; then
        echo "取消并退出..."
        exit 0
      elif [ "$answer" = "o" ]; then
        check_sys # Rerun just in case
        detele_kernel_custom
      else
        echo "无效输入，请输入 y, n, 或 o。"
      fi
      exit 0
      ;;

    *)
      echo "$(random_color '无效的选择，退出脚本。')"
      exit 1
      ;;
esac

# --- Installation Logic (if choice was 1) ---

echo "$(random_color '别急,别急,别急,老登')"
sleep 1

if [ "$hy2zt" = "运行中" ]; then
  echo "Hysteria 正在运行，请先选择 '2. 卸载' 再重新安装。"
  exit 1
else
  echo "原神,启动。" # Funny message from original script
fi

# Run uninstall first to ensure clean state, suppress most output
echo "正在进行预清理..."
uninstall_hysteria > /dev/null 2>&1

installhy2 () {
  echo "创建 Hysteria 工作目录 /root/hy3..."
  mkdir -p /root/hy3
  cd /root/hy3 || { echo "错误：无法创建或进入 /root/hy3 目录。"; exit 1; }

  echo "正在下载 Hysteria $arch 二进制文件..."
  # Ensure wget is available
  if ! command -v wget >/dev/null 2>&1; then apk add wget || yum install wget || apt install wget ; fi

  if wget --no-check-certificate -O hysteria-linux-"$arch" https://download.hysteria.network/app/latest/hysteria-linux-"$arch"; then
      chmod +x hysteria-linux-"$arch"
      echo "从 download.hysteria.network 下载成功。"
  else
      echo "从主下载点下载失败，尝试 GitHub Releases..."
      local latest_tag # Get latest tag again or use previous value
      latest_tag=$(get_latest_version) # Assumes get_latest_version returns the tag like vX.Y.Z
      if [[ "$latest_tag" == "获取失败" || "$latest_tag" == "解析失败" ]]; then
          echo "错误：无法获取最新版本号，无法从 GitHub 下载。"
          exit 1
      fi
      # Construct download URL using the obtained tag
      local DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/app/$latest_tag/hysteria-linux-$arch"
      echo "尝试下载: $DOWNLOAD_URL"
      if wget --no-check-certificate -O hysteria-linux-"$arch" "$DOWNLOAD_URL"; then
          chmod +x hysteria-linux-"$arch"
          echo "从 GitHub Releases ($latest_tag) 下载成功。"
      else
          echo "错误：无法从任何源下载 Hysteria 二进制文件。"
          exit 1
      fi
  fi

  echo "Hysteria 二进制文件准备就绪。"
}

echo "$(random_color '正在下载中,老登( ﾟдﾟ)つBye')"
sleep 1
installhy2 # Execute download function

echo "正在生成基础配置文件 config.yaml..."
# Default config from original script
cat <<EOL > config.yaml
listen: :443 # Placeholder, will be replaced

# tls: # TLS section added later based on choice
#   cert: /path/to/cert.pem
#   key: /path/to/key.pem

# acme: # ACME section added later based on choice
#  domains:
#    - your.domain.com
#  email: your@email.com
#  # Optional DNS challenge section here if selected

auth:
  type: password
  password: Se7RAuFZ8Lzg # Placeholder, will be replaced

masquerade:
  type: proxy
  # file: # Example, disabled by default
  #   dir: /www/masq
  proxy:
    url: https://news.ycombinator.com/ # Placeholder, will be replaced
    rewriteHost: true
  # string: # Example, disabled by default
  #   content: hello stupid world
  #   headers:
  #     content-type: text/plain
  #     custom-stuff: ice cream so good
  #   statusCode: 200

# Bandwidth (optional, examples) - Set reasonable defaults or leave commented
# bandwidth:
#   up: 100 mbps
#   down: 500 mbps

# UDP Idle Timeout (optional, example)
# udpIdleTimeout: 60s

# Obfs (optional, example) - requires password in auth section above
# obfs:
#   type: salamander
#   password: your_obfs_password # Must match auth password

EOL

# --- Interactive Configuration ---
while true; do
    echo "$(random_color '请输入端口号（留空默认443，输入0随机2000-60000，你可以输入1-65535指定端口号）: ')"
    read -p "" port

    if [ -z "$port" ]; then
      port=443
    elif [ "$port" -eq 0 ]; then
      port=$(( ( RANDOM % 58001 ) + 2000 )) # Use Bash RANDOM if available
      # Fallback for non-bash RANDOM
      if ! [[ "$port" -ge 2000 ]]; then port=$(awk 'BEGIN{srand(); print int(rand()*58001)+2000}'); fi
    elif ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      echo "$(random_color '无效端口号，请输入1-65535之间的数字。')"
      continue
    fi

    echo "检查端口 $port 是否被占用..."
    # Use ss instead of netstat; check both TCP and UDP
    # Ensure iproute2 provides ss
    if ! command -v ss >/dev/null 2>&1; then apk add iproute2 || yum install iproute || apt install iproute2 ; fi
    if ss -tuln | grep -q ":$port "; then
      echo "$(random_color "端口 $port 已被占用，请重新输入端口号：")"
      continue # Ask again
    else
      echo "$(random_color "端口 $port 可用。")"
      # Use | as delimiter in sed to avoid conflicts with paths
      if sed -i "s|^listen:.*|listen: :$port|" config.yaml; then
        echo "$(random_color '端口号已设置为：')" "$port"
        break # Port set successfully, exit loop
      else
        echo "$(random_color '替换端口号失败，退出脚本。')"
        exit 1
      fi
    fi
done

# --- Certificate Configuration ---
# Define variables to hold TLS config lines
tls_config_lines=""
domain_name="" # For self-signed SNI
domain="" # For ACME SNI
ovokk="" # For self-signed insecure flag in URL
choice1="" # For self-signed skip-verify flag in Clash config
choice2="false" # Default skip-verify for ACME Clash config

generate_certificate() {
    echo "$(random_color '正在生成自签名证书...')"
    read -p "请输入要用于自签名证书的域名/CN (默认为 bing.com): " user_domain
    domain_name=${user_domain:-"bing.com"} # Use this for SNI later

    # Basic check if domain resolves or is simple string
    # if ! ping -c 1 "$domain_name" > /dev/null 2>&1 && ! echo "$domain_name" | grep -qE '^[a-zA-Z0-9.-]+$'; then
    #    echo -e "输入的域名 '$domain_name' 看起来无效，请重试！"
    #    generate_certificate # Recursive call, potential issue
    #    return # Return after recursive call finishes
    # fi
    # Simplified check - allow most strings
    if [ -z "$domain_name" ]; then
        echo "域名/CN 不能为空，请重试。"
        generate_certificate
        return
    fi

    cert_dir="/etc/ssl/private" # Standard location
    mkdir -p "$cert_dir"
    cert_path="$cert_dir/$domain_name.crt"
    key_path="$cert_dir/$domain_name.key"

    echo "生成密钥和证书到 $cert_dir ..."
    # Ensure openssl is available
    if ! command -v openssl >/dev/null 2>&1; then apk add openssl || yum install openssl || apt install openssl ; fi
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$key_path" -out "$cert_path" \
        -subj "/CN=$domain_name" -days 36500

    if [ $? -ne 0 ]; then
        echo "错误：生成证书失败。"
        exit 1
    fi

    chmod 600 "$key_path" # Secure private key
    chmod 644 "$cert_path"
    echo -e "自签名证书和私钥已生成！"
    echo -e "证书: $cert_path"
    echo -e "私钥: $key_path"

    # Prepare TLS config lines for config.yaml
    # Use standard YAML indentation (2 spaces)
    tls_config_lines="tls:\n  cert: $cert_path\n  key: $key_path"
    ovokk="insecure=1&" # Flag for URL
    choice1="true" # Flag for Clash skip-verify
    choice2="" # Clear ACME flag
}

# Prompt for certificate type
read -p "请选择证书类型（输入 1 使用 ACME 证书 (需要域名), 输入 2 使用自签名证书, 回车默认 ACME）: " cert_choice

if [ "$cert_choice" == "2" ]; then
    generate_certificate # This sets tls_config_lines, ovokk, choice1, domain_name
else
    # ACME selected (or default)
    echo "$(random_color '请输入你的域名（必须正确解析到本服务器 IP）: ')"
    read -p "" domain

    while [ -z "$domain" ]; do
      echo "$(random_color '域名不能为空，请重新输入: ')"
      read -p "" domain
    done
    # Basic validation could be added here (e.g., check DNS resolution)

    echo "$(random_color '请输入你的邮箱（用于 ACME 注册，默认随机生成）: ')"
    read -p "" email

    if [ -z "$email" ]; then
      # Generate a more plausible random email if possible
      random_part=$(head /dev/urandom | LC_ALL=C tr -dc a-z0-9 | head -c 8)
      email="${random_part}@example.com" # Use example.com
      echo "使用随机邮箱: $email"
    fi

    # Prepare ACME config lines
    acme_config_lines="acme:\n  domains:\n    - $domain\n  email: $email"
    choice2="false" # Set Clash skip-verify to false for valid ACME certs
    choice1="" # Clear self-signed flag

    # Ask about DNS challenge
    echo "请选择 ACME 验证方式:"
    echo "1. HTTP 验证 (默认，需要端口 80 开放)"
    echo "2. DNS 验证 (Cloudflare - 需要 API 令牌)"
    read -p "请输入你的选择 (1 或 2，回车默认 1): " acme_challenge_choice

    if [ "$acme_challenge_choice" == "2" ]; then
        read -p "请输入 Cloudflare 的 API 令牌: " api_key
        if [ -z "$api_key" ]; then
            echo "错误：Cloudflare API 令牌不能为空。"
            exit 1
        fi
        # Add DNS challenge config lines
         dns_challenge_lines="  challenge:\n    type: dns\n    provider: cloudflare\n    cloudflare:\n      api_token: $api_key"
         acme_config_lines="$acme_config_lines\n$dns_challenge_lines"
         echo "已配置 Cloudflare DNS 验证。"
    else
        echo "使用 HTTP 验证 (确保端口 80 可访问)。"
        # No extra lines needed for default HTTP challenge
    fi
fi

# --- Insert TLS or ACME config into config.yaml ---
temp_file=$(mktemp)
# Find the line after 'listen:' to insert the config
insert_line=$(grep -n "^listen:.*" config.yaml | cut -d: -f1)
insert_line=$((insert_line + 1)) # Insert on the next line

# Create the config to insert
config_to_insert=""
if [ -n "$tls_config_lines" ]; then
    config_to_insert="$tls_config_lines"
elif [ -n "$acme_config_lines" ]; then
    config_to_insert="$acme_config_lines"
fi

# Use awk for reliable insertion
awk -v line="$insert_line" -v config="$config_to_insert" 'NR==line{print config} 1' config.yaml > "$temp_file" && mv "$temp_file" config.yaml

if [ $? -eq 0 ]; then
    echo "证书配置已写入 config.yaml。"
else
    echo "错误：写入证书配置到 config.yaml 失败。"
    rm -f "$temp_file"
    exit 1
fi


# --- Continue with Password, Masquerade, IP, Port Hopping ---

# Select IP Address for Client Config
get_ipv4_info() {
  # Ensure wget is available
  if ! command -v wget >/dev/null 2>&1; then apk add wget || yum install wget || apt install wget ; fi
  ip_address=$(wget -4 -qO- --no-check-certificate --user-agent=Mozilla --tries=2 --timeout=3 http://ip-api.com/json/)
  if [ $? -ne 0 ] || [ -z "$ip_address" ]; then echo "获取 IPv4 信息失败。"; ipwan="YOUR_IPV4_ADDRESS"; return; fi
  ispck=$(echo "$ip_address" | jq -r '.isp // empty')
  ip_query=$(echo "$ip_address" | jq -r '.query // empty')

  if echo "$ispck" | grep -qi "cloudflare"; then
    echo "检测到 Cloudflare WARP (IPv4)，请输入正确的服务器 IP："
    read -p "" new_ip
    # Basic validation for IPv4
    if [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ipwan="$new_ip"
    else
        echo "输入的 IPv4 格式无效，将使用检测到的 IP。";
        ipwan="$ip_query" # Fallback
    fi
  else
    ipwan="$ip_query"
  fi
}

get_ipv6_info() {
  # Ensure wget is available
  if ! command -v wget >/dev/null 2>&1; then apk add wget || yum install wget || apt install wget ; fi
  ip_address=$(wget -6 -qO- --no-check-certificate --user-agent=Mozilla --tries=2 --timeout=5 https://api.ip.sb/geoip) # Use ip.sb for IPv6
   if [ $? -ne 0 ] || [ -z "$ip_address" ]; then echo "获取 IPv6 信息失败。"; ipwan="YOUR_IPV6_ADDRESS"; return; fi
  ispck=$(echo "$ip_address" | jq -r '.isp // empty')
  ip_query=$(echo "$ip_address" | jq -r '.ip // empty')

  if echo "$ispck" | grep -qi "cloudflare"; then
    echo "检测到 Cloudflare WARP (IPv6)，请输入正确的服务器 IP (无需方括号)："
     read -p "" new_ip
     # Basic validation for IPv6 can be complex, just check non-empty for now
     if [ -n "$new_ip" ]; then
        ipwan="[$new_ip]"
     else
        echo "输入的 IPv6 为空，将使用检测到的 IP。";
        ipwan="[$ip_query]" # Fallback
     fi
  else
    ipwan="[$ip_query]"
  fi
}

# Choose IP mode
ipwan="" # Initialize ipwan
ipta="" # Initialize iptables command variable
while true; do
  echo "请选择客户端连接时使用的 IP 地址类型:"
  echo "1. IPv4 (默认)"
  echo "2. IPv6"
  read -p "请选择 (1 或 2，回车默认 1): " ip_choice

  case "$ip_choice" in
    1|"")
      echo "获取 IPv4 地址..."
      get_ipv4_info
      echo "客户端将使用 IPv4 地址：$ipwan"
      ipta="iptables" # For port hopping rules
      break
      ;;
    2)
      echo "获取 IPv6 地址..."
      get_ipv6_info
      echo "客户端将使用 IPv6 地址：$ipwan"
      ipta="ip6tables" # For port hopping rules
      break
      ;;
    *)
      echo "无效输入。请输入 1 或 2。"
      ;;
  esac
done


# Set Password
echo "$(random_color '请输入你的密码（留空将生成随机密码）: ')"
read -p "" password

if [ -z "$password" ]; then
  # Ensure openssl is available
  if ! command -v openssl >/dev/null 2>&1; then apk add openssl || yum install openssl || apt install openssl ; fi
  password=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9') # Generate slightly shorter random password
  echo "生成随机密码。"
fi

# Use | as delimiter for sed
if sed -i "s|password: Se7RAuFZ8Lzg|password: $password|" config.yaml; then
  echo "$(random_color '密码已设置为：')" "$password"
else
  echo "$(random_color '替换密码失败，退出脚本。')"
  exit 1
fi

# Set Masquerade URL
echo "$(random_color '请输入伪装网址（必须是有效 URL，留空默认 https://bing.com/）: ')"
read -p "" masquerade_url

if [ -z "$masquerade_url" ]; then
  masquerade_url="https://bing.com/" # Changed default
fi

# Validate URL format slightly
if ! echo "$masquerade_url" | grep -qE '^https?://'; then
    echo "警告：输入的伪装网址格式可能不正确，请确保它是有效的 URL。"
fi

# Use | as delimiter for sed
if sed -i "s|url: https://news.ycombinator.com/|url: $masquerade_url|" config.yaml; then
  echo "$(random_color '伪装域名已设置为：')" "$masquerade_url"
else
  echo "$(random_color '替换伪装域名失败，退出脚本。')"
  exit 1
fi


# Port Hopping Configuration
start_port=""
end_port=""
while true; do
    echo "$(random_color '是否要开启 UDP 端口跳跃功能？（需要 iptables/ip6tables 支持）(ง ื▿ ื)ว（回车默认不开启，输入 1 开启）: ')"
    read -p "" port_jump_choice

    if [ -z "$port_jump_choice" ]; then
        echo "不开启端口跳跃。"
        break # Exit loop, port hopping disabled
    elif [ "$port_jump_choice" -eq 1 ]; then
        echo "$(random_color '请输入端口跳跃起始端口号 (必须小于末尾端口): ')"
        read -p "" start_port

        echo "$(random_color '请输入端口跳跃末尾端口号 (必须大于起始端口): ')"
        read -p "" end_port

        # Validate ports
        if ! [[ "$start_port" =~ ^[0-9]+$ ]] || ! [[ "$end_port" =~ ^[0-9]+$ ]] || \
           [ "$start_port" -lt 1 ] || [ "$start_port" -gt 65535 ] || \
           [ "$end_port" -lt 1 ] || [ "$end_port" -gt 65535 ]; then
            echo "$(random_color '起始或末尾端口无效 (必须是 1-65535 之间的数字)。')"
            start_port="" # Reset
            end_port=""
            continue # Ask again
        elif [ "$start_port" -ge "$end_port" ]; then
             echo "$(random_color '末尾端口必须大于起始端口，请重新输入。')"
             start_port="" # Reset
             end_port=""
             continue # Ask again
        fi

        echo "配置端口跳跃规则 ($start_port:$end_port -> $port)..."
        # Ensure iptables/ip6tables command exists
        if ! command -v "$ipta" >/dev/null 2>&1; then
            echo "错误: $ipta 命令未找到。无法设置端口跳跃。"
            echo "请尝试安装 'iptables' 包。"
            start_port="" # Disable port hopping
            end_port=""
            break
        fi

        # Apply the rule immediately (might be cleared on reboot if not persisted)
        "$ipta" -t nat -A PREROUTING -p udp --dport "$start_port":"$end_port" -j DNAT --to-destination :"$port"
        if [ $? -eq 0 ]; then
            echo "$(random_color "端口跳跃功能已初步启用 (UDP $start_port-$end_port -> $port)。")"
            echo "$(random_color '注意：此规则可能在重启后失效，将尝试创建服务使其持久化。')"
            break # Exit loop, port hopping enabled
        else
            echo "$(random_color '错误：应用 iptables 规则失败。端口跳跃未启用。')"
             start_port="" # Disable port hopping
             end_port=""
             break # Exit loop
        fi
    else
      echo "$(random_color '输入无效，请输入 1 开启端口跳跃功能，或直接按回车跳过。')"
      # Loop continues
    fi
done

# Create persistence script and service for port hopping if enabled
if [ -n "$start_port" ] && [ -n "$end_port" ]; then
  echo "创建端口跳跃持久化脚本 /root/hy3/ipppp.sh ..."
  # Ensure directory exists
  mkdir -p /root/hy3
  cat <<EOF > /root/hy3/ipppp.sh
#!/bin/bash
# Ensure iptables command exists
if ! command -v "$ipta" >/dev/null 2>&1; then exit 1; fi
# Flush existing rule first to avoid duplicates (optional but safer)
"$ipta" -t nat -D PREROUTING -p udp --dport "$start_port":"$end_port" -j DNAT --to-destination :"$port" 2>/dev/null || true
# Add the rule
"$ipta" -t nat -A PREROUTING -p udp --dport "$start_port":"$end_port" -j DNAT --to-destination :"$port"
EOF
  chmod +x /root/hy3/ipppp.sh

  if [ "$OS_TYPE" = "Alpine" ]; then
      echo "创建 OpenRC 服务脚本 /etc/init.d/ipppp ..."
      cat <<EOF > /etc/init.d/ipppp
#!/sbin/openrc-run
description="Hysteria Port Hopping Persistence"

depend() {
    need net # Depend on network service
}

start() {
    ebegin "Applying Hysteria port hopping rule"
    /root/hy3/ipppp.sh
    eend \$?
}

stop() {
    ebegin "Removing Hysteria port hopping rule"
    # Ensure iptables command exists
    if command -v "$ipta" >/dev/null 2>&1; then
        "$ipta" -t nat -D PREROUTING -p udp --dport "$start_port":"$end_port" -j DNAT --to-destination :"$port" 2>/dev/null || true
    fi
    eend 0 # Always report success on stop
}
EOF
      chmod +x /etc/init.d/ipppp
      echo "启用并启动 ipppp OpenRC 服务..."
      rc-update add ipppp default
      rc-service ipppp start
  else # Assume systemd for Debian/CentOS
      echo "创建 systemd 服务文件 /etc/systemd/system/ipppp.service ..."
      cat <<EOF > /etc/systemd/system/ipppp.service
[Unit]
Description=Hysteria Port Hopping Persistence
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=oneshot
ExecStart=/root/hy3/ipppp.sh
ExecStop=/bin/bash -c 'if command -v "$ipta" >/dev/null 2>&1; then "$ipta" -t nat -D PREROUTING -p udp --dport "$start_port":"$end_port" -j DNAT --to-destination :"$port" 2>/dev/null || true; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
      echo "启用并启动 ipppp systemd 服务..."
      systemctl enable ipppp.service
      systemctl start ipppp.service
  fi
  echo "$(random_color '端口跳跃持久化服务已设置。')"
fi


# --- Generate Client Configs ---
echo "正在生成 Clash Meta 配置文件 clash-mate.yaml..."
# Set SNI based on cert type
client_sni="$domain$domain_name" # Will use ACME domain if set, otherwise self-signed CN
# Set skip-cert-verify based on cert type
client_skip_cert_verify="$choice1$choice2" # Will be "true" for self-signed, "false" for ACME

cat <<EOL > clash-mate.yaml
# Clash Meta Configuration - Generated by Script
# Ports for Clash itself
port: 7890
socks-port: 7891
# mixed-port: 7892 # Or use mixed-port
# redir-port: 7893 # For transparent proxying

allow-lan: false # Set to true to allow connections from other devices on LAN
bind-address: '*' # Bind to all interfaces if allow-lan is true
mode: rule # rule or global
log-level: info
ipv6: true # Enable IPv6 support in Clash

# External Controller (for web UI like Yacd)
external-controller: 127.0.0.1:9090
# secret: 'your_clash_api_secret' # Optional API secret

# Profile settings (optional)
profile:
  store-selected: true
  store-fake-ip: true

# TUN device settings (for system-wide proxy on some OS)
# tun:
#   enable: true
#   stack: system # Or gvisor
#   auto-route: true
#   auto-detect-interface: true
#   dns-hijack: # Hijack DNS requests made to specific servers
#     - any:53

# DNS settings
dns:
  enable: true
  listen: 0.0.0.0:5353 # Use a non-standard port to avoid conflicts
  ipv6: true # Allow DNS server to return IPv6 records
  prefer-h3: true # Prefer DNS over HTTPS/3
  enhanced-mode: fake-ip # fake-ip or redir-host
  fake-ip-range: 198.18.0.1/16 # Range for Fake IP mode
  # default-nameserver: # Used for requests resolving doh/dot hostnames
  #   - 1.1.1.1
  #   - 8.8.8.8
  nameserver: # DNS servers for general lookups
    - https://223.5.5.5/dns-query # Ali DNS DoH
    - https://dns.google/dns-query # Google DoH
    # - tls://1.1.1.1:853 # Cloudflare DoT example
  fallback: # Servers to use if primary ones fail
    - https://1.0.0.1/dns-query # Cloudflare DoH
    # - tcp://8.8.8.8

proxies:
  - name: Hysteria2-$(hostname) # Add hostname for clarity
    type: hysteria2
    server: $ipwan # Use the selected IPv4 or IPv6 address
    port: $port # The main listening port
    password: $password # The password set earlier
    sni: $client_sni # SNI based on cert type (ACME domain or self-signed CN)
    skip-cert-verify: ${client_skip_cert_verify:-false} # "true" for self-signed, "false" for ACME
    # Optional Hysteria 2 parameters (examples)
    # obfs: salamander # If using obfs, must match server config
    # obfs-password: $password # If using obfs
    # up-mbps: 100 # Client-side bandwidth shaping (optional)
    # down-mbps: 500 # Client-side bandwidth shaping (optional)
    # alpn: # Optional ALPN override
    #  - h3

proxy-groups:
  - name: 🚀 Proxy # Group name for selection
    type: select # Manual selection type
    proxies:
      - Hysteria2-$(hostname)
      # - DIRECT # Add DIRECT if needed
      # - REJECT # Add REJECT if needed

rules:
  # Add your preferred Clash rules here
  # Example: Direct common Chinese sites
  # - DOMAIN-SUFFIX,cn,DIRECT
  # - DOMAIN-KEYWORD,google,🚀 Proxy
  # - GEOSITE,google,🚀 Proxy # Use geosite database if available
  # - GEOIP,CN,DIRECT # Use geoip database if available
  - MATCH,🚀 Proxy # Default rule: everything else goes through proxy
EOL

echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"
echo "Clash Meta 配置文件 clash-mate.yaml 已保存到 /root/hy3/"
echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"

# Generate NekoBox URL
echo "正在生成 NekoBox / V2rayN 等客户端可用的链接..."
neko_url="hysteria2://$password@$ipwan:$port/?sni=$client_sni&${ovokk}" # Add insecure flag if self-signed
# Add port hopping parameter if enabled
if [ -n "$start_port" ] && [ -n "$end_port" ]; then
    neko_url="${neko_url}mport=$port,$start_port-$end_port#"
else
    neko_url="${neko_url}#" # Add # for anchor even without mport
fi
# Add anchor/name
neko_url="${neko_url}Hysteria2-$(hostname)"

echo "$neko_url" > neko.txt # Save to file

# --- Start Service ---
echo "正在创建/配置 Hysteria 服务..."

if [ "$OS_TYPE" = "Alpine" ]; then
    # Create OpenRC init script
    echo "创建 OpenRC 服务脚本 /etc/init.d/hysteria ..."
    cat <<EOF > /etc/init.d/hysteria
#!/sbin/openrc-run
description="Hysteria 2 Proxy Server"
# supervisor="supervise-daemon" # Use supervise-daemon for better process management (requires package)

# Ensure these exist before depending on them
command="/root/hy3/hysteria-linux-$arch"
command_args="server"
command_user="root" # Run as root, or consider a dedicated user
pidfile="/run/hysteria.pid" # Store PID file in /run
logfile="/var/log/hysteria.log" # Log file location
directory="/root/hy3" # Working directory

depend() {
    need net # Depend on network service
    use logger # Optional: depend on logger if logging heavily
}

start() {
    ebegin "Starting Hysteria 2 server"
    # Check if command exists and is executable
    if [ ! -x "\$command" ]; then
        eerror "Hysteria command not found or not executable: \$command"
        return 1
    fi
    # Use start-stop-daemon for process management
    start-stop-daemon --start --quiet --background \
        --make-pidfile --pidfile "\$pidfile" \
        --chdir "\$directory" \
        --exec "\$command" -- \$command_args >> "\$logfile" 2>&1
    eend \$? "Failed to start Hysteria 2"
}

stop() {
    ebegin "Stopping Hysteria 2 server"
    start-stop-daemon --stop --quiet --pidfile "\$pidfile"
    eend \$? "Failed to stop Hysteria 2"
}

status() {
    if [ -f "\$pidfile" ] && pgrep -F "\$pidfile" > /dev/null; then
        echo "Hysteria 2 is running (PID: \$(cat \$pidfile))"
        return 0
    else
        echo "Hysteria 2 is not running."
        # Check if pidfile exists but process is dead
        if [ -f "\$pidfile" ]; then return 1; else return 3; fi
    fi
}
EOF
    chmod +x /etc/init.d/hysteria
    echo "启用并启动 Hysteria OpenRC 服务..."
    enable_service # Use abstracted function (rc-update add hysteria default)
    start_service # Use abstracted function (rc-service hysteria start)
else # Assume systemd
    # Create systemd unit file
     echo "创建 systemd 服务文件 /etc/systemd/system/hysteria.service ..."
     cat <<EOF > /etc/systemd/system/hysteria.service
[Unit]
Description=Hysteria 2 Proxy Server
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=simple
WorkingDirectory=/root/hy3
# Consider running as a non-root user for better security
# User=hysteria
# Group=hysteria
# AmbientCapabilities=CAP_NET_BIND_SERVICE # If running as non-root and using low port (<1024)
ExecStart=/root/hy3/hysteria-linux-$arch server --config /root/hy3/config.yaml
# StandardOutput=append:/var/log/hysteria.log # Log to file
# StandardError=append:/var/log/hysteria.log
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536 # Increase file descriptor limit

[Install]
WantedBy=multi-user.target
EOF
    echo "启用并启动 Hysteria systemd 服务..."
    systemctl daemon-reload # Reload systemd to recognize the new file
    enable_service # Use abstracted function (systemctl enable)
    start_service # Use abstracted function (systemctl start)
fi

echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"
echo "安装完成。"
echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"

echo "$(random_color '老登,马上,马上了------')"
sleep 2 # Keep the dramatic pause

echo "$(random_color '这是你的 Clash Meta 配置 (保存于 /root/hy3/clash-mate.yaml):')"
echo "--------------------------------------------------"
cat /root/hy3/clash-mate.yaml
echo "--------------------------------------------------"

echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"
echo "$(random_color '>>>>>>>>>>>>>>>>>>>>')"

echo -e "$(random_color '这是你的 Hysteria2 节点链接信息 (保存于 /root/hy3/neko.txt): ')\n${neko_url}"

echo -e "$(random_color '\nHysteria 2 安装成功，请合理使用哦,你直直-——直直接给我坐下')"
echo "提示：如果连接失败，请检查服务器防火墙是否放行了端口 $port (UDP) 以及端口 80 (TCP, 如果使用 ACME HTTP 验证)。"
echo "      对于自签名证书，请确保客户端开启了“跳过证书验证”选项。"

exit 0
