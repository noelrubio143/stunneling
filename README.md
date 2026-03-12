ssh stunnel

curl -sSL https://raw.githubusercontent.com/noelrubio143/stunneling/refs/heads/main/stunnel-menu.sh -o /tmp/stunnel-menu.sh && sudo mv /tmp/stunnel-menu.sh /usr/local/bin/menu && sudo chmod +x /usr/local/bin/menu && echo "Installation complete. Type 'menu' to open the SSH + Stunnel menu."



vless


curl -sSL https://raw.githubusercontent.com/noelrubio143/stunneling/refs/heads/main/vless -o /tmp/vless && sudo mv /tmp/vless /usr/local/bin/vless && sudo chmod +x /usr/local/bin/vless && echo "Installation complete. Type 'vless' to open the vless menu."
