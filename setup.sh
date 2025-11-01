#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Source common functions and variables
source "$(dirname "${BASH_SOURCE[0]}")/src/common.sh"

# --------------------------------------------------------
# Main function
# --------------------------------------------------------
main() {
    check_permission

    local arts_title_file="${SCRIPT_DIR}/arts.txt"
    if [ -f "$arts_title_file" ]; then
        cat "$arts_title_file"
    else
        log "WARNING" "arts.txt not found"
    fi

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
        error_exit "Domain name is required. Use 'sudo ./setup.sh --domain|-d <your_domain>'"
    fi

    bash "${SCRIPT_DIR}/src/setup_coturn.sh" --domain "$domain"
}

main "$@"
