#!/bin/bash
# ===============================================
# AmberVPN VPS Management Script with Stunnel Installer
# ===============================================

set -e

# Colors for output
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

# Default configuration
SQUID_PORTS="80,8080,8888"
SSH_PORT=22
BANNER_TEXT="==== AMBERVPN ===="
LOG_FILE="/var/log/ambervpn.log"

# ---------------------------
# System Info
# ---------------------------
function get_system_info() {
    RAM_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
    RAM_USED=$(free -h | awk '/Mem:/ {print $3}')
    RAM_FREE=$(free -h | awk '/Mem:/ {print $4}')
    CPU_CORES=$(nproc)
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')
}

# ---------------------------
# Logging Function
# ---------------------------
function log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# ---------------------------
# User Management
# ---------------------------
function create_user() {
    read -p "Enter new username: " u
    if [[ ! "$u" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_color red "Invalid username. Use letters, numbers, ., _, or -"
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

    sudo useradd -m -s /bin/bash "$u"
    echo "$u:$p" | sudo chpasswd
    print_color green "User $u created."

    if [[ -n "$exp_days" && "$exp_days" =~ ^[0-9]+$ ]]; then
        expiration_date=$(date -d "+$exp_days days" '+%Y-%m-%d')
        sudo chage -E "$expiration_date" "$u"
        print_color yellow "Account $u will expire on $expiration_date."
    fi

    print_color blue "Account Details:"
    echo "======================"
    echo "Username: $u"
    echo "Home Directory: /home/$u"
    echo "Shell: /bin/bash"
    echo "======================"

    log_action "Created user $u"
}

function delete_user() {
    read -p "Enter username to delete: " u
    if id "$u" &>/dev/null; then
        sudo deluser --remove-home "$u"
        print_color green "User $u deleted."
        log_action "Deleted user $u"
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

function get_online_user_count() {
    who | wc -l
}

# ---------------------------
# SSH Banner Update
# ---------------------------
function update_ssh_banner() {
    read -p "Enter new SSH banner text: " new_banner
    new_banner=$(echo "$new_banner" | xargs)
    if [[ -n "$new_banner" ]]; then
        echo "$new_banner" | sudo tee /etc/issue /etc/motd >/dev/null
        sudo sed -i 's|#Banner none|Banner /etc/motd|' /etc/ssh/sshd_config
        sudo systemctl restart ssh
        print_color green "SSH banner updated."
    else
        print_color yellow "No banner entered. Banner unchanged."
    fi
}

# ---------------------------
# Stunnel Installer (IP-bound)
# ---------------------------
function setup_stunnel() {
    if [ "$EUID" -ne 0 ]; then
        print_color red "Please run as root to setup Stunnel."
        return
    fi

    read -p "Enter your VPS IP: " VPS_IP
    read -p "Enter the port Stunnel will accept connections on (e.g., 443): " ACCEPT_PORT
    read -p "Enter the local service port to tunnel (e.g., 22 for SSH): " CONNECT_PORT

    print_color blue "Updating system packages..."
    apt update -y && apt upgrade -y

    print_color blue "Installing stunnel4..."
    apt install -y stunnel4

    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4

    SSL_FILE="/etc/stunnel/stunnel.pem"
    mkdir -p /etc/stunnel
    print_color blue "Creating self-signed certificate for IP $VPS_IP..."
    openssl req -new -x509 -days 365 -nodes \
      -out "$SSL_FILE" \
      -keyout "$SSL_FILE" \
      -subj "/C=PH/ST=Philippines/L=City/O=MyCompany/OU=IT/CN=$VPS_IP"

    chmod 600 "$SSL_FILE"

    if [ -f /etc/stunnel/stunnel.conf ]; then
        mv /etc/stunnel/stunnel.conf /etc/stunnel/stunnel.conf.bak
    fi

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

    print_color green "---------------------------------------------"
    print_color green "Stunnel setup complete!"
    print_color green "Listening on $VPS_IP:$ACCEPT_PORT -> local port $CONNECT_PORT"
    print_color green "Certificate stored at $SSL_FILE (valid 1 year)"
    print_color green "---------------------------------------------"

    log_action "Stunnel installed on $VPS_IP:$ACCEPT_PORT -> $CONNECT_PORT"
}

# ---------------------------
# SSH + Squid Installation
# ---------------------------
function install_ssh_squid() {
    sudo apt update
    sudo apt install -y openssh-server squid || { print_color red "Failed to install SSH or Squid"; return; }

    sudo systemctl enable ssh squid
    sudo systemctl restart ssh squid

    sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.backup
    sudo bash -c "cat > /etc/squid/squid.conf <<EOF
http_port 80
http_port 8080
http_port 8888
acl localnet src 127.0.0.1/32
http_access allow localnet
http_access deny all
access_log /var/log/squid/access.log
EOF"

    sudo systemctl restart squid
    print_color green "SSH and Squid installed."
    log_action "SSH and Squid installed"
}

# ---------------------------
# DNSTT Deployment (Safe)
# ---------------------------
function deploy_dnstt() {
    TMP_SCRIPT=$(mktemp)
    curl -Ls -o "$TMP_SCRIPT" https://raw.githubusercontent.com/noelrubio143/stunneling/refs/heads/main/dnstt
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
    sudo reboot
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
    print_color blue "Squid Ports: $SQUID_PORTS"
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
