#!/bin/bash

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USER_DB="$CONFIG_DIR/udpusers.db"
SYSTEMD_SERVICE="/etc/systemd/system/hysteria-server.service"
SCRIPT_PATH="$0"

mkdir -p "$CONFIG_DIR"
touch "$USER_DB"

# Set timezone to Manila/Philippines
export TZ="Asia/Manila"

# Function to get server IP
get_server_ip() {
    # Try different methods to get the public IP
    local ip=""
    
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -s -4 ifconfig.me 2>/dev/null) || \
        ip=$(curl -s -4 icanhazip.com 2>/dev/null) || \
        ip=$(curl -s -4 ipecho.net/plain 2>/dev/null)
    fi

    if [[ -z "$ip" ]] && command -v wget >/dev/null 2>&1; then
        ip=$(wget -qO- ifconfig.me 2>/dev/null) || \
        ip=$(wget -qO- icanhazip.com 2>/dev/null)
    fi

    if [[ -z "$ip" ]]; then
        ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127' | head -n 1)
    fi

    if [[ -z "$ip" ]]; then
        ip=$(hostname -I | awk '{print $1}')
    fi

    echo "$ip"
}

# Function to clear screen after command execution
clear_after_command() {
    echo -e "\nPress Enter to continue..."
    read
    clear
    show_banner
}

fetch_users() {
    if [[ -f "$USER_DB" ]]; then
        sqlite3 "$USER_DB" "SELECT username || ':' || password FROM users;" | paste -sd, -
    fi
}

update_userpass_config() {
    local users=$(fetch_users)
    local user_array=$(echo "$users" | awk -F, '{for(i=1;i<=NF;i++) printf "\"" $i "\"" ((i==NF) ? "" : ",")}')
    jq ".auth.config = [$user_array]" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

display_connection_info() {
    local username="$1"
    local password="$2"
    local server_ip=$(get_server_ip)
    local obfs_method=$(jq -r ".obfs" "$CONFIG_FILE")
    
    echo -e "\n\e[1;33m═══════════ Connection Information ═══════════\e[0m"
    echo -e "\e[1;32mServer IP   : \e[0m$server_ip"
    echo -e "\e[1;32mUsername    : \e[0m$username"
    echo -e "\e[1;32mPassword    : \e[0m$password"
    echo -e "\e[1;32mUDP Port    : \e[0m10000-65000"
    echo -e "\e[1;32mOBFS        : \e[0m$obfs_method"
    echo -e "\e[1;33m═════════════════════════════════════════\e[0m"
}

add_user() {
    echo -e "\n\e[1;34mEnter username:\e[0m"
    read -r username
    echo -e "\e[1;34mEnter password:\e[0m"
    read -r password
    sqlite3 "$USER_DB" "INSERT INTO users (username, password) VALUES ('$username', '$password');"
    if [[ $? -eq 0 ]]; then
        echo -e "\e[1;32mUser $username added successfully.\e[0m"
        display_connection_info "$username" "$password"
        update_userpass_config
        restart_server
    else
        echo -e "\e[1;31mError: Failed to add user $username.\e[0m"
    fi
    clear_after_command
}

edit_user() {
    echo -e "\n\e[1;34mEnter username to edit:\e[0m"
    read -r username
    echo -e "\e[1;34mEnter new password:\e[0m"
    read -r password
    sqlite3 "$USER_DB" "UPDATE users SET password = '$password' WHERE username = '$username';"
    if [[ $? -eq 0 ]]; then
        echo -e "\e[1;32mUser $username updated successfully.\e[0m"
        display_connection_info "$username" "$password"
        update_userpass_config
        restart_server
    else
        echo -e "\e[1;31mError: Failed to update user $username.\e[0m"
    fi
    clear_after_command
}

delete_user() {
    echo -e "\n\e[1;34mEnter username to delete:\e[0m"
    read -r username
    sqlite3 "$USER_DB" "DELETE FROM users WHERE username = '$username';"
    if [[ $? -eq 0 ]]; then
        echo -e "\e[1;32mUser $username deleted successfully.\e[0m"
        update_userpass_config
        restart_server
    else
        echo -e "\e[1;31mError: Failed to delete user $username.\e[0m"
    fi
    clear_after_command
}

show_users() {
    echo -e "\n\e[1;34mCurrent users:\e[0m"
    sqlite3 "$USER_DB" "SELECT username FROM users;"
    clear_after_command
}

change_up_speed() {
    echo -e "\n\e[1;34mEnter new upload speed (Mbps):\e[0m"
    read -r up_speed
    jq ".up_mbps = $up_speed" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq ".up = \"$up_speed Mbps\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "\e[1;32mUpload speed changed to $up_speed Mbps successfully.\e[0m"
    restart_server
    clear_after_command
}

change_down_speed() {
    echo -e "\n\e[1;34mEnter new download speed (Mbps):\e[0m"
    read -r down_speed
    jq ".down_mbps = $down_speed" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq ".down = \"$down_speed Mbps\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "\e[1;32mDownload speed changed to $down_speed Mbps successfully.\e[0m"
    restart_server
    clear_after_command
}

change_server() {
    echo -e "\n\e[1;34mEnter the new server address (e.g., example.com):\e[0m"
    read -r server
    jq ".server = \"$server\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "\e[1;32mServer changed to $server successfully.\e[0m"
    restart_server
    clear_after_command
}

change_obfs() {
    echo -e "\n\e[1;34mEnter the new OBFS method (e.g., tfn, tls, etc.):\e[0m"
    read -r obfs_method
    jq ".obfs = \"$obfs_method\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "\e[1;32mOBFS method changed to $obfs_method successfully.\e[0m"
    restart_server
    clear_after_command
}

change_udp_port() {
    echo -e "\n\e[1;34mEnter the new UDP port:\e[0m"
    read -r udp_port
    jq ".udp_port = $udp_port" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "\e[1;32mUDP port changed to $udp_port successfully.\e[0m"
    restart_server
    clear_after_command
}

restart_server() {
    systemctl restart hysteria-server
    if [[ $? -eq 0 ]]; then
        echo -e "\e[1;32mServer restarted successfully.\e[0m"
    else
        echo -e "\e[1;31mError: Failed to restart the server.\e[0m"
    fi
}

display_ram_and_cores() {
    local total_ram=$(free -m | awk '/Mem:/ { print $2 }')
    local used_ram=$(free -m | awk '/Mem:/ { print $3 }')
    local total_cores=$(nproc)

    echo -e "\e[1;35mRAM Usage: $used_ram/$total_ram MB | CPU Cores: $total_cores\e[0m"
}

uninstall_server() {
    echo -e "\n\e[1;34mUninstalling TFN-UDP server...\e[0m"
    systemctl stop hysteria-server
    systemctl disable hysteria-server
    rm -f "$SYSTEMD_SERVICE"
    systemctl daemon-reload
    rm -rf "$CONFIG_DIR"
    rm -f /usr/local/bin/hysteria
    echo -e "\e[1;32mTFN-UDP server uninstalled successfully.\e[0m"
    
    cat > /tmp/remove_script.sh << EOF
#!/bin/bash
sleep 1
rm -f "$SCRIPT_PATH"
rm -f /tmp/remove_script.sh
EOF
    
    chmod +x /tmp/remove_script.sh
    echo -e "\e[1;32mRemoving menu script...\e[0m"
    nohup /tmp/remove_script.sh >/dev/null 2>&1 &
    
    exit 0
}

show_banner() {
    clear
    echo -e "\e[1;36m╔═══════════════════════════════════════╗"
    echo -e "║           TFN-UDP Manager             ║"
    echo -e "║                                       ║"
    echo -e "║       Telegram: @jerico555            ║"
    echo -e "╚═══════════════════════════════════════╝\e[0m"
    echo -e "\e[1;33mServer Time : $(TZ='Asia/Manila' date '+%I:%M %p')"
    echo -e "Time Zone   : Manila/Philippines"
    echo -e "Date        : $(TZ='Asia/Manila' date '+%Y-%m-%d')\e[0m"
    display_ram_and_cores
}

show_menu() {
    echo -e "\e[1;36m╔═══════════════════════════════════════╗"
    echo -e "║           UDP Manager                 ║"
    echo -e "╚═══════════════════════════════════════╝\e[0m"
    echo -e "\e[1;32m[\e[0m1\e[1;32m]\e[0m Add new user"
    echo -e "\e[1;32m[\e[0m2\e[1;32m]\e[0m Edit user password"
    echo -e "\e[1;32m[\e[0m3\e[1;32m]\e[0m Delete user"
    echo -e "\e[1;32m[\e[0m4\e[1;32m]\e[0m Show users"
    echo -e "\e[1;32m[\e[0m5\e[1;32m]\e[0m Change upload speed"
    echo -e "\e[1;32m[\e[0m6\e[1;32m]\e[0m Change download speed"
    echo -e "\e[1;32m[\e[0m7\e[1;32m]\e[0m Change domain"
    echo -e "\e[1;32m[\e[0m8\e[1;32m]\e[0m Change obfs"
    echo -e "\e[1;32m[\e[0m9\e[1;32m]\e[0m Uninstall Script"
    echo -e "\e[1;32m[\e[0m0\e[1;32m]\e[0m Exit"
    echo -e "\e[1;36m═══════════════════════════════════════\e[0m"
    echo -e "\e[1;32mEnter your choice:\e[0m"
}

show_banner
while true; do
    show_menu
    read -r choice
    case $choice in
        1) add_user ;;
        2) edit_user ;;
        3) delete_user ;;
        4) show_users ;;
        5) change_up_speed ;;
        6) change_down_speed ;;
        7) change_server ;;
        8) change_obfs ;;
        9) uninstall_server;;
        0) clear; exit 0 ;;
        *) echo -e "\e[1;31mInvalid choice. Please try again.\e[0m"; clear_after_command ;;
    esac
done
