#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Source common functions and variables
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --------------------------------------------------------
# Functions
# --------------------------------------------------------
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
    log "INFO" "Opening firewall ports for Coturn"
    sudo ufw allow 3478/udp || error_exit "Failed to open port 3478"
    sudo ufw allow 3478/tcp || error_exit "Failed to open port 3478"
    log "INFO" "Coturn configured and started successfully"
}

# --------------------------------------------------------
# Main function
# --------------------------------------------------------
main() {
    local domain=""
    local machine_ip=""
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain | -d) 
                domain="$2"
                shift 2
                ;; 
            --ip | -i) 
                machine_ip="$2"
                shift 2
                ;; 
            *)
                error_exit "Unknown argument: $1"
                ;; 
        esac
    done
    if [ -z "$domain" ]; then
        error_exit "Domain name is required. Use 'sudo ./coturn.sh --domain|-d <your_domain>'
    fi
    if [ -z "$machine_ip" ]; then
        error_exit "Machine IP is required. Use 'sudo ./coturn.sh --ip|-i <your_machine_ip>'
    fi

    setup_coturn "$domain" "$machine_ip"
}

main "$@"
