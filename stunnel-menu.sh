#!/bin/bash
# ===============================================
# AmberVPN VPS Management Script v2.5
# Features: User Management, SSH/Squid, Stunnel, DNSTT, Live System Banner
# ===============================================

set -euo pipefail

# ---------------------------
# Root Check
# ---------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR] This script must be run as root.\033[0m"
    exit 1
fi

# ---------------------------
# Colors for output
# ---------------------------
function print_color {
    local COLOR=$1
    local MESSAGE=$2
    NC='\033[0m'
    case $COLOR in
        red) echo -e "\033[0;31m${MESSAGE}${NC}" ;;
        green) echo -e "\033[0;32m${MESSAGE}${NC}" ;;
        yellow) echo -e "\033[0;33m${MESSAGE}${NC}" ;;
        blue) echo -e "\033[0;34m${MESSAGE}${NC}" ;;
        *) echo "${MESSAGE}" ;;
    esac
}

# ---------------------------
# Global Config
# ---------------------------
SSH_PORT=22
SQUID_PORT=8080
STUNNEL_PORT=""   # will be set after Stunnel setup
BANNER_TEXT="==== AMBERVPN ===="
LOG_FILE="/var/log/ambervpn.log"

# ---------------------------
# System Info Functions
# ---------------------------
function get_system_info() {
    RAM_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
    RAM_USED=$(free -h | awk '/Mem:/ {print $3}')
    RAM_FREE=$(free -h | awk '/Mem:/ {print $4}')
    CPU_CORES=$(nproc)
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%.1f", 100 - $8}')
}

function get_online_user_count() {
    who | wc -l
}

# ---------------------------
# Logging
# ---------------------------
function log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# ---------------------------
# Dynamic SSH Banner
# ---------------------------
function update_ssh_banner() {
    get_system_info
    VPS_IP=$(hostname -I | awk '{print $1}')
    ONLINE_USERS=$(get_online_user_count)
    STUNNEL_PORT_DISPLAY=${STUNNEL_PORT:-"Not set"}
    SQUID_PORT_DISPLAY=${SQUID_PORT:-"Not set"}

    new_banner="$BANNER_TEXT
VPS IP: $VPS_IP
SSH Port: $SSH_PORT
Stunnel Port: $STUNNEL_PORT_DISPLAY
Squid Port: $SQUID_PORT_DISPLAY
CPU Cores: $CPU_CORES
CPU Usage: $CPU_USAGE%
RAM Total: $RAM_TOTAL
RAM Used: $RAM_USED
RAM Free: $RAM_FREE
Online Users: $ONLINE_USERS"

    echo "$new_banner" > /etc/issue
    echo "$new_banner" > /etc/motd
    sed -i 's|#Banner none|Banner /etc/issue|' /etc/ssh/sshd_config || true
    systemctl restart ssh
    print_color green "SSH banner updated with live VPS stats."
    log_action "SSH banner updated with live VPS stats"
}

# ---------------------------
# User Management
# ---------------------------
function create_user() {
    read -p "Enter new username: " u
    if [[ ! "$u" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_color red "Invalid username."
        return
    fi
    if id "$u" &>/dev/null; then
        print_color red "User $u already exists!"
        return
    fi
    read -sp "Enter password for $u: " p; echo
    if [[ -z "$p" ]]; then
        print_color red "Password cannot be empty."
        return
    fi
    read -p "Enter expiration period in days (leave blank for no expiration): " exp_days

    useradd -m -s /bin/bash "$u"
    echo "$u:$p" | chpasswd
    print_color green "User $u created."

    if [[ -n "$exp_days" && "$exp_days" =~ ^[0-9]+$ ]]; then
        expiration_date=$(date -d "+$exp_days days" '+%Y-%m-%d')
        chage -E "$expiration_date" "$u"
        print_color yellow "Account $u will expire on $expiration_date."
    fi

    print_color blue "Account Details:"
    echo "======================"
    echo "Username: $u"
    echo "Home Directory: /home/$u"
    echo "Shell: /bin/bash"
    echo "======================"

    log_action "Created user $u"
    update_ssh_banner
}

function delete_user() {
    read -p "Enter username to delete: " u
    if id "$u" &>/dev/null; then
        deluser --remove-home "$u"
        print_color green "User $u deleted."
        log_action "Deleted user $u"
        update_ssh_banner
    else
        print_color red "User $u does not exist!"
    fi
}

function list_users() {
    print_color blue "Non-system users:"
    awk -F: '$3 >= 1000 {print $1}' /etc/passwd
}

function list_online_users() {
    print_color blue "Currently online users:"
    who
}

# ---------------------------
# Stunnel Setup
# ---------------------------
function setup_stunnel() {
    read -p "Enter VPS IP: " VPS_IP
    read -p "Enter Stunnel port (e.g., 443): " ACCEPT_PORT
    read -p "Enter local service port to tunnel (e.g., 22): " CONNECT_PORT

    STUNNEL_PORT=$ACCEPT_PORT

    print_color blue "Updating system..."
    apt update -y && apt upgrade -y
    apt install -y stunnel4 openssl

    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4

    SSL_FILE="/etc/stunnel/stunnel.pem"
    mkdir -p /etc/stunnel
    openssl req -new -x509 -days 365 -nodes \
        -out "$SSL_FILE" -keyout "$SSL_FILE" \
        -subj "/C=PH/ST=Philippines/L=City/O=AmberVPN/OU=IT/CN=$VPS_IP"
    chmod 600 "$SSL_FILE"

    [ -f /etc/stunnel/stunnel.conf ] && mv /etc/stunnel/stunnel.conf /etc/stunnel/stunnel.conf.bak

    cat <<EOL > /etc/stunnel/stunnel.conf
cert = $SSL_FILE
pid = /var/run/stunnel.pid
client = no

[service]
accept = $VPS_IP:$ACCEPT_PORT
connect = $CONNECT_PORT
EOL

    systemctl restart stunnel4
    systemctl enable stunnel4

    print_color green "Stunnel setup complete on port $ACCEPT_PORT."
    log_action "Stunnel installed on $VPS_IP:$ACCEPT_PORT -> $CONNECT_PORT"

    update_ssh_banner
}

# ---------------------------
# SSH + Squid Installation
# ---------------------------
function install_ssh_squid() {
    read -p "Allow remote Squid access? (y/N): " allow_remote
    apt update -y
    apt install -y openssh-server squid

    systemctl enable ssh squid
    systemctl restart ssh squid

    cp /etc/squid/squid.conf /etc/squid/squid.conf.backup

    if [[ "$allow_remote" =~ ^[Yy]$ ]]; then
        ACL_LINE="acl localnet src 0.0.0.0/0"
    else
        ACL_LINE="acl localnet src 127.0.0.1/32"
    fi

    cat <<EOF > /etc/squid/squid.conf
http_port $SQUID_PORT
$ACL_LINE
http_access allow localnet
http_access deny all
access_log /var/log/squid/access.log
EOF

    systemctl restart squid
    print_color green "SSH and Squid installed (Squid on port $SQUID_PORT)."
    log_action "SSH and Squid installed"

    update_ssh_banner
}

# ---------------------------
# DNSTT Deployment
# ---------------------------
function deploy_dnstt() {
    TMP_SCRIPT=$(mktemp)
    curl -Ls -o "$TMP_SCRIPT" https://raw.githubusercontent.com/noelrubio143/stunneling/refs/heads/main/dnstt || {
        print_color red "Failed to download DNSTT script."
        return
    }
    chmod +x "$TMP_SCRIPT"
    bash "$TMP_SCRIPT"
    rm -f "$TMP_SCRIPT"
    log_action "DNSTT deployed"
}

# ---------------------------
# VPS Reboot
# ---------------------------
function reboot_vps() {
    print_color yellow "Rebooting VPS..."
    reboot
}

# ---------------------------
# Main Menu
# ---------------------------
while true; do
    clear
    get_system_info
    ONLINE_USERS=$(get_online_user_count)

    print_color green "$BANNER_TEXT"
    print_color blue "System Info:"
    echo "RAM: $RAM_TOTAL (Used: $RAM_USED, Free: $RAM_FREE)"
    echo "CPU Cores: $CPU_CORES"
    echo "CPU Usage: $CPU_USAGE%"
    echo "SSH Port: $SSH_PORT"
    print_color blue "Squid Port: $SQUID_PORT"
    print_color blue "Stunnel Port: ${STUNNEL_PORT:-Not set}"
    print_color blue "Online Users: $ONLINE_USERS"

    echo "1) Create new user"
    echo "2) Set up Stunnel"
    echo "3) Deploy DNSTT"
    echo "4) Install SSH and Squid Proxy"
    echo "5) Delete a user"
    echo "6) List users"
    echo "7) Reboot VPS"
    echo "8) List online users"
    echo "9) Edit SSH Banner"
    echo "0) Quit"
    read -p "Choose option [0-9]: " choice

    case $choice in
        0) print_color red "Exiting..."; exit 0 ;;
        1) create_user; read -p "Press Enter to return to menu..." ;;
        2) setup_stunnel; read -p "Press Enter to return to menu..." ;;
        3) deploy_dnstt; read -p "Press Enter to return to menu..." ;;
        4) install_ssh_squid; read -p "Press Enter to return to menu..." ;;
        5) delete_user; read -p "Press Enter to return to menu..." ;;
        6) list_users; read -p "Press Enter to return to menu..." ;;
        7) reboot_vps; read -p "Press Enter to return to menu..." ;;
        8) list_online_users; read -p "Press Enter to return to menu..." ;;
        9) update_ssh_banner; read -p "Press Enter to return to menu..." ;;
        *) print_color red "Invalid choice!"; sleep 1 ;;
    esac
done
