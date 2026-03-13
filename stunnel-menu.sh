#!/bin/bash

# Function to add color to output
function print_color {
  COLOR=$1
  MESSAGE=$2
  NC='\033[0m' # No Color
  case $COLOR in
    "red") echo -e "\033[0;31m${MESSAGE}${NC}" ;;
    "green") echo -e "\033[0;32m${MESSAGE}${NC}" ;;
    "yellow") echo -e "\033[0;33m${MESSAGE}${NC}" ;;
    "blue") echo -e "\033[0;34m${MESSAGE}${NC}" ;;
    *) echo "${MESSAGE}" ;;
  esac
}

# Default Squid ports
SQUID_PORTS="80, 8080, 8888"
STUNNEL_PORT="443"
SSH_PORT="22"
BANNER_TEXT="==== AMBERVPN ===="  # Default banner

# Function to get RAM and CPU core information
get_system_info() {
    RAM_TOTAL=$(free -h | grep Mem | awk '{print $2}')
    RAM_USED=$(free -h | grep Mem | awk '{print $3}')
    RAM_FREE=$(free -h | grep Mem | awk '{print $4}')
    CPU_CORES=$(nproc)
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
}

# Function to install stunnel if needed
install_stunnel() {
    if ! command -v stunnel &>/dev/null; then
        print_color "blue" "Installing stunnel4..."
        if ! sudo apt update && sudo apt install -y stunnel4; then
            print_color "red" "Failed to install stunnel4. Please check your package sources."
            exit 1
        fi
    fi
}

# Function to create a user with password and expiration in days
create_user() {
    read -p "Enter new username: " u
    read -sp "Enter password for $u: " p
    echo
    read -p "Enter expiration period in days (leave blank for no expiration): " exp_days
    echo

    if id "$u" &>/dev/null; then
        print_color "red" "User $u already exists!"
    else
        sudo useradd -m "$u" -s /bin/bash
        echo "$u:$p" | sudo chpasswd
        print_color "green" "User $u created."

        # Set expiration date if days are provided
        if [ -n "$exp_days" ]; then
            expiration_date=$(date -d "+$exp_days days" '+%Y-%m-%d')
            sudo chage -E "$expiration_date" "$u"
            print_color "yellow" "Account $u will expire on $expiration_date."
        else
            print_color "yellow" "No expiration date set for $u."
        fi

        # Display the account details
        print_color "blue" "Account Details:"
        echo "================"
        echo "Username: $u"
        echo "Password: $p"
        echo "Home Directory: /home/$u"
        echo "Shell: /bin/bash"
        echo "================"

        # Log the user creation
        echo "$(date) - User $u created" >> /var/log/ambervpn.log
    fi
}

# Function to delete a user
delete_user() {
    read -p "Enter the username to delete: " u
    if id "$u" &>/dev/null; then
        sudo deluser --remove-home "$u"
        print_color "green" "User $u deleted successfully."

        # Log the user deletion
        echo "$(date) - User $u deleted" >> /var/log/ambervpn.log
    else
        print_color "red" "User $u does not exist!"
    fi
}

# Function to list all users
list_users() {
    print_color "blue" "Listing all users..."
    # Get all non-system users by filtering /etc/passwd
    awk -F: '$3 >= 1000 {print $1}' /etc/passwd
}

# Function to list online users
list_online_users() {
    print_color "blue" "Currently online users on the VPS:"
    who
}

# Function to set up Stunnel
setup_stunnel() {
    # Install and configure Stunnel
    install_stunnel

    # Stunnel configuration
    sudo bash -c "cat > /etc/stunnel/stunnel.conf <<EOF
client = no
[ssh]
accept = ${STUNNEL_PORT}
connect = 22
cert = /etc/stunnel/stunnel.pem
EOF"
    sudo openssl req -new -x509 -days 365 -nodes \
        -out /etc/stunnel/stunnel.pem \
        -keyout /etc/stunnel/stunnel.pem \
        -subj "/CN=localhost"
    sudo systemctl enable stunnel4
    sudo systemctl restart stunnel4
    print_color "green" "Stunnel SSH setup complete (port ${STUNNEL_PORT})."
}

# Function to deploy DNSTT using the updated script
deploy_dnstt() {
    print_color "blue" "Downloading and running the latest DNSTT deploy script..."
    bash <(curl -Ls https://raw.githubusercontent.com/noelrubio143/stunneling/refs/heads/main/dnstt)
}

# Function to install SSH server and Squid Proxy with specified ports
install_ssh_squid() {
    # Update the package list
    print_color "blue" "Updating the package list..."
    sudo apt update

    # Install SSH server
    print_color "blue" "Installing SSH server..."
    sudo apt install -y openssh-server

    # Enable and start SSH service
    print_color "blue" "Enabling and starting SSH service..."
    sudo systemctl enable ssh
    sudo systemctl start ssh

    # Install Squid
    print_color "blue" "Installing Squid..."
    sudo apt install -y squid

    # Backup the original Squid configuration file
    print_color "blue" "Backing up the original Squid configuration file..."
    sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.backup

    # Configure Squid to listen on ports 80, 8080, and 8888
    print_color "blue" "Configuring Squid with ports 80, 8080, and 8888..."
    sudo bash -c "cat > /etc/squid/squid.conf <<EOF
# Squid configuration file for ports 80, 8080, and 8888
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 8080
acl Safe_ports port 8888
acl Safe_ports port 21  # FTP
acl Safe_ports port 70  # Gopher
acl Safe_ports port 1025-65535 # High numbered ports
acl Safe_ports port 280  # HTTP Alternate
acl Safe_ports port 488  # gopher
acl Safe_ports port 591  # File Transfer
acl Safe_ports port 777  # HTTP Alternate
acl CONNECT method CONNECT

# Allow access for all specified ports
http_access allow all
http_port 80
http_port 8080
http_port 8888
dns_nameservers 8.8.8.8 8.8.4.4
access_log /var/log/squid/access.log
cache_log /var/log/squid/cache.log
EOF"

    # Enable and start Squid service
    print_color "blue" "Enabling and restarting Squid service..."
    sudo systemctl enable squid
    sudo systemctl restart squid

    # Print status of SSH and Squid services
    print_color "green" "SSH and Squid installation and configuration complete."
    print_color "yellow" "SSH service status:"
    sudo systemctl status ssh | grep Active

    print_color "yellow" "Squid service status:"
    sudo systemctl status squid | grep Active
}

# Function to reboot the VPS
reboot_vps() {
    print_color "yellow" "Rebooting the VPS now..."
    sudo reboot
}

# Function to get the number of online users
get_online_user_count() {
    ONLINE_COUNT=$(who | wc -l)
    echo "$ONLINE_COUNT"
}

# Function to update the SSH login banner
update_ssh_banner() {
    echo "Enter the new SSH banner text:"
    read -p "New banner text: " new_banner
    new_banner=$(echo "$new_banner" | xargs)  # Removes any extra spaces
    if [ -n "$new_banner" ]; then
        echo "$new_banner" | sudo tee /etc/issue > /dev/null
        echo "$new_banner" | sudo tee /etc/motd > /dev/null
        sudo sed -i 's/#Banner none/Banner \/etc\/motd/' /etc/ssh/sshd_config
        sudo systemctl restart ssh
        print_color "green" "SSH banner updated successfully!"
    else
        print_color "yellow" "No banner text entered. Banner remains unchanged."
    fi
}

# Main menu loop
while true; do
    clear
    get_system_info
    ONLINE_USERS=$(get_online_user_count)
    
    # Display AMBERVPN in Green with System Info, Squid Ports, and Usage in Blue
    print_color "green" "$BANNER_TEXT"
    print_color "blue" "System Info:"
    echo "RAM: $RAM_TOTAL (Used: $RAM_USED, Free: $RAM_FREE)"
    echo "CPU Cores: $CPU_CORES"
    echo "CPU Usage: $CPU_USAGE%"
    echo "SSH Port: $SSH_PORT"
    echo "Stunnel Port: $STUNNEL_PORT"
    print_color "blue" "Squid Ports: $SQUID_PORTS"
    print_color "blue" "Online Users: $ONLINE_USERS"
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
        0) print_color "red" "Exiting..."; exit 0;;
        1) create_user; read -p "Press Enter to return to menu...";;
        2) setup_stunnel; read -p "Press Enter to return to menu...";;
        3) deploy_dnstt; read -p "Press Enter to return to menu...";;
        4) install_ssh_squid; read -p "Press Enter to return to menu...";;
        5) delete_user; read -p "Press Enter to return to menu...";;
        6) list_users; read -p "Press Enter to return to menu...";;
        7) reboot_vps; read -p "Press Enter to return to menu...";;
        8) list_online_users; read -p "Press Enter to return to menu...";;
        9) update_ssh_banner; read -p "Press Enter to return to menu...";;
        *) print_color "red" "Invalid choice!"; sleep 1;;
    esac
done
