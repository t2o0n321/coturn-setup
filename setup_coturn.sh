#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Source common functions and variables
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --------------------------------------------------------
# Arts (ANSI Shandow) https://patorjk.com/software/taag
# --------------------------------------------------------
ARTS_TITLE=$(cat <<'EOF'
    ██╗                                                         
   ██╔╝                                                         
  ██╔╝█████╗█████╗█████╗█████╗█████╗█████╗█████╗█████╗█████╗    
 ██╔╝ ╚════╝╚════╝╚════╝╚════╝╚════╝╚════╝╚════╝╚════╝╚════╝    
██╔╝    ███████╗███████╗████████╗██╗   ██╗██████╗               
╚═╝     ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗              
        ███████╗█████╗     ██║   ██║   ██║██████╔╝              
        ╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝               
        ███████║███████╗   ██║   ╚██████╔╝██║                   
        ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝                   
     ██████╗ ██████╗ ████████╗██╗   ██╗██████╗ ███╗   ██╗       
    ██╔════╝██╔═══██╗╚══██╔══╝██║   ██║██╔══██╗████╗  ██║       
    ██║     ██║   ██║   ██║   ██║   ██║██████╔╝██╔██╗ ██║       
    ██║     ██║   ██║   ██║   ██║   ██║██╔══██╗██║╚██╗██║       
    ╚██████╗╚██████╔╝   ██║   ╚██████╔╝██║  ██║██║ ╚████║    ██╗
     ╚═════╝ ╚═════╝    ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝   ██╔╝
    █████╗█████╗█████╗█████╗█████╗█████╗█████╗█████╗█████╗ ██╔╝ 
    ╚════╝╚════╝╚════╝╚════╝╚════╝╚════╝╚════╝╚════╝╚════╝██╔╝  
                                                         ██╔╝   
                                                         ╚═╝    
EOF
)

# --------------------------------------------------------
# Functions
# --------------------------------------------------------
check_domain() {
    local domain="$1"
    log "INFO" "Checking domain resolution for $domain"
    local ip
    ip=$(nslookup "$domain" | grep 'Address:' | tail -n1 | awk '{print $2}' || echo "")
    if [ -z "$ip" ]; then
        error_exit "Failed to resolve domain $domain"
    fi
    local machine_ip
    machine_ip=$(curl -s ipinfo.io/ip || echo "")
    if [ -z "$machine_ip" ]; then
        error_exit "Failed to retrieve machine IP"
    fi
    if [ "$ip" != "$machine_ip" ]; then
        error_exit "The domain $domain resolves to $ip, but machine IP is $machine_ip"
    fi
    log "INFO" "Domain $domain resolves correctly to $machine_ip"
    echo "$machine_ip"
}

# Setup SSL using certbot
setup_ssl() {
    local domain="$1"
    log "INFO" "Installing certbot and requesting SSL certificate for $domain"
    sudo apt update
    sudo apt install certbot -y || error_exit "Failed to install certbot"
    sudo ufw allow 80/tcp || error_exit "Failed to open port 80"
    sudo certbot certonly --standalone -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email || error_exit "Failed to obtain SSL certificate"
    sudo ufw delete allow 80/tcp || error_exit "Failed to close port 80"
    sudo systemctl disable certbot.timer || error_exit "Failed to disable default certbot timer" # Certbot's default timer may conflict the custom timer
    log "INFO" "SSL certificate obtained for $domain"
}

# Setup renewal of SSL certificate using systemd timer
setup_renew_ssl_cert() {
    log "INFO" "Setting up SSL renewal timer"

    local domain=$1

    if [ ! -f "$RENEW_SSL_CERT_SH" ]; then
        error_exit "Renewal script not found at $RENEW_SSL_CERT_SH"
    fi
    local renew_ssl_sh_basename=$(basename "$RENEW_SSL_CERT_SH")
    local renew_service_script_path="/usr/local/bin/$renew_ssl_sh_basename"

    sudo cp "$RENEW_SSL_CERT_SH" "$renew_service_script_path" \
        || error_exit "Failed to copy $RENEW_SSL_CERT_SH to $renew_service_script_path"

    sudo chmod +x "$renew_service_script_path" \
        || error_exit "Failed to make $renew_service_script_path executable"

    local renew_ssl_service=$(cat << EOF
[Unit]
Description=SSL Certificate Renewal Service
After=network-online.target

[Service]
Type=oneshot
ExecStart=$renew_service_script_path $domain
RemainAfterExit=yes
EOF
)
    echo "$renew_ssl_service" | sudo tee "$RENEW_SSL_SERVICE_FILE" > /dev/null \
        || error_exit "Failed to create $RENEW_SSL_SERVICE_FILE"

    local renew_ssl_timer=$(cat << EOF
[Unit]
Description=Run SSL Certificate Renewal

[Timer]
OnCalendar=$RENEW_SSL_SERVICE_TIMER_CALENDAR
Persistent=true

[Install]
WantedBy=timers.target
EOF
)
    echo "$renew_ssl_timer" | sudo tee "$RENEW_SSL_SERVICE_TIMER_FILE" > /dev/null \
        || error_exit "Failed to create $RENEW_SSL_SERVICE_TIMER_FILE"

    sudo systemctl daemon-reload \
        || error_exit "Failed to reload systemd daemon"
    sudo systemctl enable "${RENEW_SSL_SERVICE_NAME}.timer" \
        || error_exit "Failed to enable ${RENEW_SSL_SERVICE_NAME}.timer"
    sudo systemctl start "${RENEW_SSL_SERVICE_NAME}.timer" \
        || error_exit "Failed to start ${RENEW_SSL_SERVICE_NAME}.timer"
    
    log "INFO" "SSL renewal timer is up"
}

setup_coturn() {
    local domain="$1"
    local machine_ip="$2"
    log "INFO" "Installing and configuring Coturn"
    sudo apt update
    sudo apt install coturn -y || error_exit "Failed to install Coturn"
    sudo mkdir -p "$COTURN_CERT_DIR" || error_exit "Failed to create Coturn certificate directory"

    local lower_case_domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]')
    sudo cp "/etc/letsencrypt/live/$lower_case_domain/fullchain.pem" "$COTURN_CERT_DIR/fullchain.pem" || error_exit "Failed to copy fullchain.pem for Coturn"
    sudo cp "/etc/letsencrypt/live/$lower_case_domain/privkey.pem" "$COTURN_CERT_DIR/privkey.pem" || error_exit "Failed to copy privkey.pem for Coturn"

    # Configure turnserver.conf
    log "INFO" "Configuring Coturn server"
    sudo tee "$COTURN_CONFIG" > /dev/null <<EOF
listening-port=3478
tls-listening-port=5349
alt-listening-port=3479
alt-tls-listening-port=5350
external-ip=$machine_ip
fingerprint
lt-cred-mech
server-name=$domain
user=$COTURN_USERNAME:$COTURN_PWD
realm=$domain
cert=$COTURN_CERT_DIR/fullchain.pem
pkey=$COTURN_CERT_DIR/privkey.pem
cipher-list="DEFAULT"
log-file=/var/log/turnserver.log
simple-log
verbose
TURNSERVER_ENABLED=1
EOF
    sudo chmod 640 "$COTURN_CONFIG" || error_exit "Failed to set permissions on turnserver.conf"
    sudo chown root:root "$COTURN_CONFIG" || error_exit "Failed to set ownership on turnserver.conf"

    # Enable Coturn in default config
    log "INFO" "Enabling Coturn service"
    sudo sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' "$COTURN_DEFAULT" || error_exit "Failed to enable Coturn in $COTURN_DEFAULT"

    # Add turn admin user
    log "INFO" "Adding Coturn admin user"
    sudo turnadmin -a -u $COTURN_USERNAME -r "$domain" -p "$COTURN_PWD" || error_exit "Failed to add Coturn admin user"

    # Start Coturn
    sudo systemctl start coturn || error_exit "Failed to start Coturn"
    sudo systemctl enable coturn || error_exit "Failed to enable Coturn"
    if ! systemctl is-active --quiet coturn; then
        error_exit "Coturn service is not running"
    fi
    log "INFO" "Coturn configured and started successfully"
}

display_instructions() {
    local domain="$1"
    local prompt_message=$(cat << EOF
* Coturn is now running.
* 
* The Coturn server credentials are (see $COTURN_CONFIG):
* - username=$COTURN_USERNAME
* - password=$COTURN_PWD
* 
* Do you want to save these informations in current folder($SCRIPT_DIR)? (Yn)
EOF
)
    local log_message="Prompting user instructions"

    if confirm "$prompt_message" "$log_message"; then
        local info_file="$SCRIPT_DIR/openfire_info.txt"
        log "INFO" "Saving informations to $info_file"
        echo "$prompt_message" | sudo tee "$info_file" > /dev/null || error_exit "Failed to save openfire_info.txt"
        log "INFO" "Informations saved to $info_file successfully"
    fi
    log "INFO" "Installation and configuration completed"
}

# Main function
main() {
    check_permission

    echo "$ARTS_TITLE"

    local domain=""
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain | -d)
                domain="$2"
                shift 2
                ;;
            *)
                error_exit "Unknown argument: $1"
                ;;
        esac
    done
    if [ -z "$domain" ]; then
        error_exit "Domain name is required. Use 'sudo ./setup_coturn.sh --domain|-d <your_domain>'"
    fi

    local machine_ip=$(check_domain "$domain")
    setup_ssl "$domain"
    setup_renew_ssl_cert "$domain"
    setup_coturn "$domain" "$machine_ip"
    display_instructions "$domain"
}

main "$@"
