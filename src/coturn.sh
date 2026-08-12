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

    # turnserver runs as $COTURN_USER, so it has to be able to read the key it is
    # pointed at. A plain `cp` out of /etc/letsencrypt leaves privkey.pem as
    # 0600 root:root; turnserver then logs
    #   "cannot start TLS and DTLS listeners because private key file is not set properly"
    # and carries on serving plain TURN on 3478 only. The service stays "active"
    # throughout, so nothing looks wrong until a client needs TURNS.
    sudo install -o root -g "$COTURN_GROUP" -m 644 \
        "/etc/letsencrypt/live/$lower_case_domain/fullchain.pem" \
        "$COTURN_CERT_DIR/fullchain.pem" \
        || error_exit "Failed to install fullchain.pem for Coturn"
    sudo install -o root -g "$COTURN_GROUP" -m 640 \
        "/etc/letsencrypt/live/$lower_case_domain/privkey.pem" \
        "$COTURN_CERT_DIR/privkey.pem" \
        || error_exit "Failed to install privkey.pem for Coturn"

    # Assert it rather than assume it -- this is the exact condition that made TLS
    # silently unavailable.
    sudo -u "$COTURN_USER" test -r "$COTURN_CERT_DIR/privkey.pem" \
        || error_exit "User '$COTURN_USER' cannot read $COTURN_CERT_DIR/privkey.pem; TLS listeners would not start"

    # turnserver cannot create this itself once it has dropped privileges, and
    # without it every start logs "Cannot open log file for writing" and silently
    # falls back to /var/tmp/turn.log. Create it only when absent so re-running the
    # installer does not truncate existing logs.
    if [ ! -e /var/log/turnserver.log ]; then
        sudo install -o "$COTURN_USER" -g "$COTURN_GROUP" -m 640 /dev/null /var/log/turnserver.log \
            || error_exit "Failed to create /var/log/turnserver.log"
    else
        sudo chown "$COTURN_USER:$COTURN_GROUP" /var/log/turnserver.log \
            || error_exit "Failed to set ownership on /var/log/turnserver.log"
        sudo chmod 640 /var/log/turnserver.log \
            || error_exit "Failed to set permissions on /var/log/turnserver.log"
    fi

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
EOF
    # root:turnserver, not root:root. turnserver reads this file after dropping
    # privileges; owned root:root at 0640 it cannot, and coturn does not treat that
    # as an error -- it silently falls back to its built-in defaults. The result
    # looks like a working server: 3478 and 3479 come up, because those are the
    # defaults, and 5349 never does, because the certificate lines were in the file
    # it could not read. This is what dpkg-statoverride records for the file too:
    #
    #   $ dpkg-statoverride --list /etc/turnserver.conf
    #   root turnserver 640 /etc/turnserver.conf
    #
    # root still owns it, so coturn can read its configuration but not rewrite it.
    sudo chmod 640 "$COTURN_CONFIG" || error_exit "Failed to set permissions on turnserver.conf"
    sudo chown "root:$COTURN_GROUP" "$COTURN_CONFIG" || error_exit "Failed to set ownership on turnserver.conf"

    # Enable Coturn in default config
    log "INFO" "Enabling Coturn service"
    sudo sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' "$COTURN_DEFAULT" || error_exit "Failed to enable Coturn in $COTURN_DEFAULT"

    # Add turn admin user
    log "INFO" "Adding Coturn admin user"
    sudo turnadmin -a -u $COTURN_USERNAME -r "$domain" -p "$COTURN_PWD" || error_exit "Failed to add Coturn admin user"

    # Restart rather than start: apt already started the service, and `start` on a
    # running unit is a no-op, so it would keep the packaged config we just replaced.
    sudo systemctl restart coturn || error_exit "Failed to start Coturn"
    sudo systemctl enable coturn || error_exit "Failed to enable Coturn"
    if ! systemctl is-active --quiet coturn; then
        error_exit "Coturn service is not running"
    fi

    # "is-active" is not evidence that TLS works. turnserver stays active with its
    # TLS and DTLS listeners disabled whenever it cannot read the private key, which
    # is how a broken TURNS setup goes unnoticed. Check the listener itself.
    local tls_port=5349
    local attempt
    for attempt in 1 2 3 4 5; do
        if sudo ss -tlnH "sport = :$tls_port" 2>/dev/null | grep -q .; then
            break
        fi
        if [ "$attempt" -eq 5 ]; then
            error_exit "Coturn is running but nothing is listening on $tls_port (TLS). Check 'journalctl -u coturn' for private key errors."
        fi
        sleep 1
    done

    log "INFO" "Opening firewall ports for Coturn"
    sudo ufw allow 3478/udp || error_exit "Failed to open port 3478"
    sudo ufw allow 3478/tcp || error_exit "Failed to open port 3478"
    # 5349 is configured as tls-listening-port above, so it has to be reachable --
    # previously it was configured but never opened, which hid the fact that the
    # listener was not running either.
    sudo ufw allow 5349/tcp || error_exit "Failed to open port 5349"
    sudo ufw allow 5349/udp || error_exit "Failed to open port 5349"
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
        error_exit "Domain name is required. Use 'sudo ./coturn.sh --domain|-d <your_domain>'"
    fi
    if [ -z "$machine_ip" ]; then
        error_exit "Machine IP is required. Use 'sudo ./coturn.sh --ip|-i <your_machine_ip>'"
    fi

    setup_coturn "$domain" "$machine_ip"
}

main "$@"
