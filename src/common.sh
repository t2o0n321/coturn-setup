#!/bin/bash

# --------------------------------------------------
# Constants
# --------------------------------------------------
# Get the directory of this script
declare -r CALLER_SOURCE="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
declare -r SCRIPT_DIR="$(cd "$(dirname "${CALLER_SOURCE}")" && pwd)"
declare -r PROJECT_ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
declare -r SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${CALLER_SOURCE}")"

# Log file path
declare -r LOG_FILE="/var/log/setup_coturn.log"

# Ensure log file exists with secure permissions
sudo touch "$LOG_FILE" || error_exit "Failed to create $LOG_FILE"
sudo chmod 600 "$LOG_FILE" || error_exit "Failed to set permissions on $LOG_FILE"
sudo chown root:root "$LOG_FILE" || error_exit "Failed to set ownership on $LOG_FILE"

declare -r COTURN_USERNAME=$(openssl rand -base64 8)
declare -r COTURN_PWD=$(openssl rand -base64 12)
declare -r COTURN_CONFIG="/etc/turnserver.conf"
declare -r COTURN_DEFAULT="/etc/default/coturn"
declare -r COTURN_CERT_DIR="/etc/coturn"

# --------------------------------------------------
# Common Functions
# --------------------------------------------------
get_timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]"
}

check_permission() {
    if [ "$EUID" -ne 0 ]; then
        echo "$(get_timestamp) This script must be run with sudo."
        exit 1
    fi
}

log() {
    local level="$1"
    local message="$2"
    echo "$(get_timestamp) [$level] $message" | tee -a "$LOG_FILE"
    logger -t "coturn_setup" "[$level] $message"
}

error_exit() {
    log "ERROR" "$1"
    exit 1
}


confirm() {
    local prompt_message="$1"
    local log_message="$2"

    local response

    log "INFO" "$log_message"

    read -r -p "$prompt_message" response

    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        return 0
    else
        return 1
    fi
}