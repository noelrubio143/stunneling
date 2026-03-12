#!/bin/bash
# === SSH + Stunnel Menu ===

# Function to install stunnel if needed
install_stunnel() {
    if ! command -v stunnel &>/dev/null; then
        echo "Installing stunnel4..."
        apt update && apt install -y stunnel4
    fi
}

# Function to create a user with password
create_user() {
    read -p "Enter new username: " u
    read -sp "Enter password for $u: " p
    echo
    if id "$u" &>/dev/null; then
        echo "User $u already exists!"
    else
        useradd -m "$u" -s /bin/bash
        echo "$u:$p" | chpasswd
        echo "User $u created."
        install_stunnel
        # Stunnel configuration
        cat <<EOF > /etc/stunnel/stunnel.conf
client = no
[ssh]
accept = 443
connect = 22
cert = /etc/stunnel/stunnel.pem
EOF
        openssl req -new -x509 -days 365 -nodes \
            -out /etc/stunnel/stunnel.pem \
            -keyout /etc/stunnel/stunnel.pem \
            -subj "/CN=localhost"
        systemctl enable stunnel4
        systemctl restart stunnel4
        echo "Stunnel SSH setup complete (port 443)."
    fi
}

# Main menu loop
while true; do
    clear
    echo "==== SSH + Stunnel Menu ===="
    echo "1) Create new user with Stunnel"
    echo "2) Quit"
    read -p "Choose option [1-2]: " choice
    case $choice in
        1) create_user; read -p "Press Enter to return to menu...";;
        2) echo "Exiting..."; exit 0;;
        *) echo "Invalid choice!"; sleep 1;;
    esac
done
