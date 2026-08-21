#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Source common functions and variables
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

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

display_instructions() {
    local domain=$1
    local prompt_message=$(cat << EOF
* Coturn is now running.
* 
* The Coturn server credentials are (see $COTURN_CONFIG):
* - username=$COTURN_USERNAME
* - password=$COTURN_PWD
* 
* Do you want to save this information in current folder ($PROJECT_ROOT_DIR)? (Yn)
EOF
)
    local log_message="Prompting user instructions"

    if confirm "$prompt_message" "$log_message"; then
        local info_file="$PROJECT_ROOT_DIR/coturn_info.txt"
        log "INFO" "Saving information to $info_file"
        echo "$prompt_message" | sudo tee "$info_file" > /dev/null || error_exit "Failed to save coturn_info.txt"
        log "INFO" "Information saved to $info_file successfully"
    fi
    log "INFO" "Installation and configuration completed"
}

# Main function
main() {
    local domain=""
    local cert_src=""
    local key_src=""
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain | -d)
                domain="$2"
                shift 2
                ;;
            --cert | -c)
                cert_src="$2"
                shift 2
                ;;
            --key | -k)
                key_src="$2"
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
    # Both or neither. One alone would silently fall back to the certbot path for
    # the other half of the pair, pairing a supplied certificate with a private key
    # from somewhere else -- coturn would start and every TLS handshake would fail.
    if [ -n "$cert_src" ] && [ -z "$key_src" ]; then
        error_exit "--cert was given without --key. Supply both, or neither to let certbot obtain one."
    fi
    if [ -n "$key_src" ] && [ -z "$cert_src" ]; then
        error_exit "--key was given without --cert. Supply both, or neither to let certbot obtain one."
    fi

    # Propagate credentials to child scripts so the values stay consistent
    export COTURN_USERNAME COTURN_PWD

    local machine_ip=$(check_domain "$domain")

    local -a cert_args=()
    if [ -n "$cert_src" ]; then
        # The caller already holds a certificate for this domain, so certbot is not
        # merely unnecessary -- it cannot run. Its standalone authenticator binds
        # port 80 itself, and a host that has its own ACME client (Caddy, say) is
        # already listening there:
        #
        #   Could not bind TCP port 80 because it is already in use by another
        #   process on this system (such as a web server).
        #
        # Its renewal timer is skipped for the same reason: it would renew nothing
        # and would be a second ACME client competing for one domain. Whoever
        # supplied the certificate is responsible for keeping it current.
        log "INFO" "Using the certificate supplied by the caller; skipping certbot and its renewal timer"
        log "INFO" "  certificate: $cert_src"
        log "INFO" "  private key: $key_src"
        cert_args=(--cert "$cert_src" --key "$key_src")
    else
        bash "${SCRIPT_DIR}/ssl.sh" --domain "$domain"
    fi

    bash "${SCRIPT_DIR}/coturn.sh" --domain "$domain" --ip "$machine_ip" ${cert_args[@]+"${cert_args[@]}"}
    display_instructions "$domain"
}

main "$@"
