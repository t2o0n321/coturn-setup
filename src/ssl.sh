#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Source common functions and variables
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --------------------------------------------------------
# Functions
# --------------------------------------------------------
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

setup_renew_ssl_cert() {
    log "INFO" "Setting up SSL renewal timer"

    local domain=$1

    local renew_ssl_cert_sh_path="${SCRIPT_DIR}/renew_letsencrypt_cert.sh"
    if [ ! -f "$renew_ssl_cert_sh_path" ]; then
        error_exit "Renewal script not found at $renew_ssl_cert_sh_path"
    fi
    local renew_ssl_sh_basename=$(basename "$renew_ssl_cert_sh_path")
    local renew_service_script_path="/usr/local/bin/$renew_ssl_sh_basename"

    sudo cp "$renew_ssl_cert_sh_path" "$renew_service_script_path" \
        || error_exit "Failed to copy $renew_ssl_cert_sh_path to $renew_service_script_path"

    sudo chmod +x "$renew_service_script_path" \
        || error_exit "Failed to make $renew_service_script_path executable"

    local renew_ssl_service_name="renew-ssl-cert"
    local renew_ssl_service_file="/etc/systemd/system/${renew_ssl_service_name}.service"
    local renew_ssl_service_timer_file="/etc/systemd/system/${renew_ssl_service_name}.timer"
    local renew_ssl_service_timer_calendar="*-*-* 03:00:00"

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
    echo "$renew_ssl_service" | sudo tee "$renew_ssl_service_file" > /dev/null \
        || error_exit "Failed to create $renew_ssl_service_file"

    local renew_ssl_timer=$(cat << EOF
[Unit]
Description=Run SSL Certificate Renewal

[Timer]
OnCalendar=$renew_ssl_service_timer_calendar
Persistent=true

[Install]
WantedBy=timers.target
EOF
)
    echo "$renew_ssl_timer" | sudo tee "$renew_ssl_service_timer_file" > /dev/null \
        || error_exit "Failed to create $renew_ssl_service_timer_file"

    sudo systemctl daemon-reload \
        || error_exit "Failed to reload systemd daemon"
    sudo systemctl enable "${renew_ssl_service_name}.timer" \
        || error_exit "Failed to enable ${renew_ssl_service_name}.timer"
    sudo systemctl start "${renew_ssl_service_name}.timer" \
        || error_exit "Failed to start ${renew_ssl_service_name}.timer"
    
    log "INFO" "SSL renewal timer is up"
}

# --------------------------------------------------------
# Main function
# --------------------------------------------------------
main() {
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
        error_exit "Domain name is required. Use 'sudo ./ssl.sh --domain|-d <your_domain>'"
    fi

    setup_ssl "$domain"
    setup_renew_ssl_cert "$domain"
}

main "$@"
