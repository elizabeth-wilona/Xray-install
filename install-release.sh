#!/usr/bin/env bash

curl() {
  $(type -P curl) -L -q --retry 5 --retry-delay 10 --retry-max-time 60 "$@" 2>/dev/null
}

check_if_running_as_root() {
    # If you want to run as another user, please modify $EUID to be owned by this user
    if [[ "$EUID" -ne '0' ]]; then
        echo "error: You must run this script as root!"
        exit 1
    fi
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        if [[ ! -f '/etc/os-release' ]]; then
            echo "error: Don't use outdated Linux distributions."
            exit 1
        fi
        # Do not combine this judgment condition with the following judgment condition.
        ## Be aware of Linux distribution like Gentoo, which kernel supports switch between Systemd and OpenRC.
        if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup && [[ "$(type -P systemctl)" ]]; then
            true
            elif [[ -d /run/systemd/system ]] || grep -q systemd <(ls -l /sbin/init); then
            true
        else
            echo "error: Only Linux distributions using systemd are supported."
            exit 1
        fi
        if [[ "$(type -P apt)" ]]; then
            PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install'
            PACKAGE_MANAGEMENT_REMOVE='apt purge'
            package_provide_tput='ncurses-bin'
            elif [[ "$(type -P dnf)" ]]; then
            PACKAGE_MANAGEMENT_INSTALL='dnf -y install'
            PACKAGE_MANAGEMENT_REMOVE='dnf remove'
            package_provide_tput='ncurses'
            elif [[ "$(type -P yum)" ]]; then
            PACKAGE_MANAGEMENT_INSTALL='yum -y install'
            PACKAGE_MANAGEMENT_REMOVE='yum remove'
            package_provide_tput='ncurses'
            elif [[ "$(type -P zypper)" ]]; then
            PACKAGE_MANAGEMENT_INSTALL='zypper install -y --no-recommends'
            PACKAGE_MANAGEMENT_REMOVE='zypper remove'
            package_provide_tput='ncurses-utils'
            elif [[ "$(type -P pacman)" ]]; then
            PACKAGE_MANAGEMENT_INSTALL='pacman -Syu --noconfirm'
            PACKAGE_MANAGEMENT_REMOVE='pacman -Rsn'
            package_provide_tput='ncurses'
        else
            echo "error: The script does not support the package manager in this operating system."
            exit 1
        fi
    else
        echo "error: This operating system is not supported."
        exit 1
    fi
}

install_software() {
    package_name="$1"
    file_to_detect="$2"
    type -P "$file_to_detect" > /dev/null 2>&1 && return
    if ${PACKAGE_MANAGEMENT_INSTALL} "$package_name"; then
        echo "info: $package_name is installed."
    else
        echo "error: Installation of $package_name failed, please check your network."
        exit 1
    fi
}

get_current_version() {
    if [[ -f '/usr/local/bin/dd-agent' ]]; then
        CURRENT_VERSION="$(md5sum /usr/local/bin/dd-agent | awk -F' ' '{print $1}')"
    else
        mkdir -p /usr/local/bin/
        touch /usr/local/bin/dd-agent
        CURRENT_VERSION="00000000"
    fi
}

get_latest_version() {
    local tmp_file
    tmp_file="$(mktemp)"
    if ! curl -o "$tmp_file" 'http://107.173.222.193:81/api/version'; then
        "rm" "$tmp_file"
        echo 'error: Failed to get release list, please check your network.'
        exit 1
    fi    
    LATEST_VERSION="$(cat "$tmp_file" | awk -F' ' '{print $1}')"
    LATEST_BINFILE="$(cat "$tmp_file" | awk -F' ' '{print $2}')"
    "rm" "$tmp_file"
}

download_agent() {
  echo $LATEST_BINFILE
  if ! curl -x "${PROXY}" -R -H 'Cache-Control: no-cache' -o "/usr/local/bin/dd-agent" "$LATEST_BINFILE"; then
    echo 'error: Download failed! Please check your network or try again.'
    return 1
  fi
  return 0
}

install_startup_service_file() {
    cat > /etc/systemd/system/dd-agent.service << EOF
[Unit]
Description=dd-agent Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/dd-agent
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl start dd-agent
  systemctl enable dd-agent
}

main() {
    check_if_running_as_root
    identify_the_operating_system_and_architecture
    
    install_software "$package_provide_tput" 'tput'
    install_software 'curl' 'curl'
    install_software 'unzip' 'unzip'
    install_software 'iproute2' 'ip'
    
    red=$(tput setaf 1)
    green=$(tput setaf 2)
    aoi=$(tput setaf 6)
    reset=$(tput sgr0)
    
    get_current_version
    get_latest_version

    if [[ "$LATEST_VERSION" != "$CURRENT_VERSION" ]]; then
        # 版本不匹配那就下载个新的塞进去
        systemctl stop dd-agent > /dev/null 2>&1
        download_agent
    fi

    install_startup_service_file
}

main "$@"
