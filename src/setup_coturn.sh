#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Source common functions and variables
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --------------------------------------------------------
# Functions
# --------------------------------------------------------
check_domain() {
    local domain=""
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
    local domain=""
    local prompt_message=$(cat << EOF
* Coturn is now running.
* 
* The Coturn server credentials are (see $COTURN_CONFIG):
* - username=$COTURN_USERNAME
* - password=$COTURN_PWD
* 
* Do you want to save these informations in current folder($PROJECT_ROOT_DIR)? (Yn)
EOF
)
    local log_message="Prompting user instructions"

    if confirm "$prompt_message" "$log_message"; then
        local info_file="$PROJECT_ROOT_DIR/coturn_info.txt"
        log "INFO" "Saving informations to $info_file"
        echo "$prompt_message" | sudo tee "$info_file" > /dev/null || error_exit "Failed to save coturn_info.txt"
        log "INFO" "Informations saved to $info_file successfully"
    fi
    log "INFO" "Installation and configuration completed"
}

# Main function
main() {
    local domain=""
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case  in
            --domain | -d) 
                domain="$2"
                shift 2
                ;; 
            *)
                error_exit "Unknown argument: "
                ;; 
        esac
    done
    if [ -z "$domain" ]; then
        error_exit "Domain name is required. Use 'sudo ./setup_coturn.sh --domain|-d <your_domain>'"
    fi

    local machine_ip=$(check_domain "$domain")
    bash "${SCRIPT_DIR}/ssl.sh" --domain "$domain"
    bash "${SCRIPT_DIR}/coturn.sh" --domain "$domain" --ip "$machine_ip"
    display_instructions "$domain"
}

main "$@"

