#!/bin/bash

# Function to add color
function print_color {
  COLOR=$1
  MESSAGE=$2
  NC='\033[0m' # No Color
  case $COLOR in
    "red")
      echo -e "\033[0;31m${MESSAGE}${NC}"
      ;;
    "green")
      echo -e "\033[0;32m${MESSAGE}${NC}"
      ;;
    "yellow")
      echo -e "\033[0;33m${MESSAGE}${NC}"
      ;;
    "blue")
      echo -e "\033[0;34m${MESSAGE}${NC}"
      ;;
    *)
      echo "${MESSAGE}"
      ;;
  esac
}

# Default Squid port
SQUID_PORT=8080

# Function to install stunnel if needed
install_stunnel() {
    if ! command -v stunnel &>/dev/null; then
        print_color "blue" "Installing stunnel4..."
        sudo apt update && sudo apt install -y stunnel4
    fi
}

# Function to create a user with password and expiration in days
create_user() {
    read -p "Enter new username: " u
    read -sp "Enter password for $u: " p
    echo
    read -p "Enter expiration period in days (e.g., 30 for 30 days, leave blank for no expiration): " exp_days
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
            # Set the expiration date
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
    fi
}

# Function to delete a user
delete_user() {
    read -p "Enter the username to delete: " u
    if id "$u" &>/dev/null; then
        sudo deluser --remove-home "$u"
        print_color "green" "User $u deleted successfully."
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

# Function to set up Stunnel
setup_stunnel() {
    # Install and configure Stunnel
    install_stunnel

    # Stunnel configuration
    sudo bash -c "cat > /etc/stunnel/stunnel.conf <<EOF
client = no
[ssh]
accept = 443
connect = 22
cert = /etc/stunnel/stunnel.pem
EOF"
    sudo openssl req -new -x509 -days 365 -nodes \
        -out /etc/stunnel/stunnel.pem \
        -keyout /etc/stunnel/stunnel.pem \
        -subj "/CN=localhost"
    sudo systemctl enable stunnel4
    sudo systemctl restart stunnel4
    print_color "green" "Stunnel SSH setup complete (port 443)."
}

# Function to deploy DNSTT
deploy_dnstt() {
    print_color "blue" "Downloading and executing the DNSTT deployment script..."
    bash <(curl -Ls https://raw.githubusercontent.com/bugfloyd/dnstt-deploy/main/dnstt-deploy.sh)
}

# Function to install SSH server and Squid Proxy
install_ssh_squid() {
    # Parse custom port from command line arguments
    while getopts p: flag
    do
        case "${flag}" in
            p) SQUID_PORT=${OPTARG};;
        esac
    done

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

    # Configure Squid to handle VPN connections by allowing all traffic (example configuration)
    print_color "blue" "Configuring Squid with custom port ${SQUID_PORT}..."
    sudo bash -c "cat > /etc/squid/squid.conf <<EOF
# Squid configuration file

# Define allowed ports
acl SSL_ports port 443
acl Safe_ports port 80      # http
acl Safe_ports port 21      # ftp
acl Safe_ports port 443     # https
acl Safe_ports port 70      # gopher
acl Safe_ports port 210     # wais
acl Safe_ports port 1025-65535  # unregistered ports
acl Safe_ports port 280     # http-mgmt
acl Safe_ports port 488     # gss-http
acl Safe_ports port 591     # filemaker
acl Safe_ports port 777     # multiling http
acl CONNECT method CONNECT

# Allow all traffic (example configuration)
http_access allow all

# Squid listening port
http_port ${SQUID_PORT}

# DNS nameservers
dns_nameservers 8.8.8.8 8.8.4.4

# Log file locations
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

# Main menu loop
while true; do
    clear
    print_color "blue" "==== Main Menu ===="
    echo "1) Create new user"
    echo "2) Set up Stunnel"
    echo "3) Deploy DNSTT"
    echo "4) Install SSH and Squid Proxy"
    echo "5) Delete a user"
    echo "6) List users"
    echo "7) Quit"
    read -p "Choose option [1-7]: " choice
    case $choice in
        1) create_user; read -p "Press Enter to return to menu...";;
        2) setup_stunnel; read -p "Press Enter to return to menu...";;
        3) deploy_dnstt; read -p "Press Enter to return to menu...";;
        4) install_ssh_squid; read -p "Press Enter to return to menu...";;
        5) delete_user; read -p "Press Enter to return to menu...";;
        6) list_users; read -p "Press Enter to return to menu...";;
        7) print_color "red" "Exiting..."; exit 0;;
        *) print_color "red" "Invalid choice!"; sleep 1;;
    esac
done
