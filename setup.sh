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
        echo ""
    else
        log "WARNING" "arts.txt not found"
    fi

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
        error_exit "Domain name is required. Use 'sudo ./setup.sh --domain|-d <your_domain> [--cert <fullchain.pem> --key <privkey.pem>]'"
    fi

    # Word splitting here honours IFS, which is newline and tab -- so an unquoted
    # ${cert_src:+--cert "$cert_src"} would arrive as ONE argument with a space in
    # it. An array keeps the pair separate. The ${a[@]+...} form is what makes an
    # empty array safe under `set -u`.
    local -a cert_args=()
    if [ -n "$cert_src" ]; then
        cert_args+=(--cert "$cert_src")
    fi
    if [ -n "$key_src" ]; then
        cert_args+=(--key "$key_src")
    fi

    bash "${SCRIPT_DIR}/src/setup_coturn.sh" --domain "$domain" ${cert_args[@]+"${cert_args[@]}"}
}

main "$@"
