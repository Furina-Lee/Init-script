#!/bin/bash

###############################################################################
# 自动化系统配置脚本
# 功能：SSH 配置、BBR/FQ 配置、系统参数调优
# 可选：跳过 BBR 配置时使用 --no-bbr 或 -n
###############################################################################

set -uo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

cleanup() {
    log_info "执行清理操作..."
    pkill -9 -f "kejilio" 2>/dev/null || true
    pkill -9 -f "kejilion" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        exit 1
    fi
}

install_bbr() {
    log_info "开始 BBR+FQ 配置流程..."
    log_info "使用直接配置方式，无需交互式安装"

    local kernel_version kernel_major kernel_minor
    kernel_version=$(uname -r | cut -d. -f1,2)
    IFS='.' read -r kernel_major kernel_minor <<< "$kernel_version"
    log_info "当前内核版本: $(uname -r)"

    if [[ $kernel_major -lt 4 ]] || [[ $kernel_major -eq 4 && $kernel_minor -lt 9 ]]; then
        log_warn "内核版本过低（${kernel_version}），BBR 需要内核 >= 4.9"
        return 1
    fi

    if ! lsmod 2>/dev/null | grep -q tcp_bbr; then
        log_info "加载 BBR 模块..."
        if modprobe tcp_bbr 2>/dev/null; then
            log_info "BBR 模块加载成功"
        else
            log_warn "无法加载 BBR 模块，尝试安装当前内核头文件..."
            if command_exists apt-get; then
                apt-get update -qq >/dev/null 2>&1 || true
                apt-get install -y -qq "linux-headers-$(uname -r)" >/dev/null 2>&1 || true
                modprobe tcp_bbr 2>/dev/null || log_warn "BBR 模块加载失败，继续配置"
            else
                log_warn "未找到 apt-get，跳过内核头文件安装"
            fi
        fi
    else
        log_info "BBR 模块已加载"
    fi

    log_info "配置 BBR 和 FQ 参数..."
    if [[ -f /etc/sysctl.conf ]]; then
        cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true
    fi

    local sysctl_content=""
    if [[ -f /etc/sysctl.conf ]]; then
        sysctl_content=$(grep -v "net.core.default_qdisc" /etc/sysctl.conf | grep -v "net.ipv4.tcp_congestion_control" || true)
    fi

    {
        echo "$sysctl_content"
        echo ""
        echo "# BBR and FQ configuration - Added by install script"
        echo "net.core.default_qdisc = fq"
        echo "net.ipv4.tcp_congestion_control = bbr"
    } > /etc/sysctl.conf

    if sysctl -p >/dev/null 2>&1; then
        log_info "BBR/FQ 配置应用成功"
    else
        log_warn "BBR/FQ 配置可能未完全生效"
    fi
    sysctl --system >/dev/null 2>&1 || true

    local current_cc current_qdisc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    log_info "当前拥塞控制算法: $current_cc"
    log_info "当前队列算法: $current_qdisc"

    if [[ "$current_cc" == "bbr" ]] && [[ "$current_qdisc" == "fq" ]]; then
        log_info "BBR+FQ 配置成功"
        return 0
    fi

    log_warn "BBR 配置可能未完全生效，可能需要重启系统"
    return 1
}

configure_ssh() {
    log_info "配置 SSH..."

    if echo "root:FurinaCloud520" | chpasswd 2>/dev/null; then
        log_info "Root 密码设置成功"
    else
        log_warn "Root 密码设置可能失败"
    fi

    local sshd_config="/etc/ssh/sshd_config"
    if [[ ! -f "$sshd_config" ]]; then
        log_error "SSH 配置文件不存在: $sshd_config"
        return 1
    fi

    cp "$sshd_config" "${sshd_config}.bak.$(date +%s)" 2>/dev/null || true
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' "$sshd_config" 2>/dev/null || true
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' "$sshd_config" 2>/dev/null || true

    if systemctl restart sshd 2>/dev/null; then
        log_info "SSH 服务重启成功"
    else
        log_warn "SSH 服务重启可能失败"
    fi

    log_info "SSH 配置完成"
}

configure_sysctl() {
    log_info "配置系统参数..."

    if [[ -f /etc/sysctl.conf ]]; then
        cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true
    fi

    cat > /etc/sysctl.conf << 'SYSCTL_EOF'
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=50000000
net.core.wmem_max=50000000
net.ipv4.tcp_rmem=4096 190054 50000000
net.ipv4.tcp_wmem=4096 190054 50000000
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL_EOF

    if sysctl -p >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1; then
        log_info "系统参数配置成功"
    else
        log_warn "系统参数配置可能未完全成功"
    fi
}

main() {
    log_info "=========================================="
    log_info "开始执行自动化系统配置脚本"
    log_info "=========================================="

    check_root

    local skip_bbr=false
    if [[ "${1:-}" == "--no-bbr" ]] || [[ "${1:-}" == "-n" ]]; then
        skip_bbr=true
        log_info "跳过 BBR 配置模式"
    fi

    log_info "[1/3] 配置 SSH..."
    if configure_ssh; then
        log_info "SSH 配置成功"
    else
        log_warn "SSH 配置可能未完全成功，继续执行"
    fi

    if [[ "$skip_bbr" == false ]]; then
        log_info "[2/3] 配置 BBR/FQ..."
        if install_bbr; then
            log_info "BBR/FQ 配置成功"
        else
            log_warn "BBR/FQ 配置可能未完全成功，继续执行"
        fi
    else
        log_info "[2/3] 已跳过 BBR/FQ 配置"
    fi

    log_info "[3/3] 配置系统参数..."
    configure_sysctl

    log_info "=========================================="
    log_info "所有系统配置任务完成"
    log_info "=========================================="
}

main "$@"
