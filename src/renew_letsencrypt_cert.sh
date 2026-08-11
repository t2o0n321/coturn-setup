#!/bin/bash
#
# Renews the Let's Encrypt certificate and hands the result to coturn.
#
# This runs from /usr/local/bin via renew-ssl-cert.service, detached from the repo,
# so it cannot source common.sh and has to carry its own error handling. An earlier
# version called error_exit() without defining it: with no `set -e` either, a failed
# renewal hit "error_exit: command not found", the script carried on, and it copied
# the old certificate over the old certificate and reported success.
set -euo pipefail

# certbot starts renewing at 30 days left; matching that leaves the same margin and
# ~30 daily attempts before anything actually expires. The previous value of 7 gave
# a week, inside the window where a few consecutive failures mean an outage.
RENEW_THRESHOLD="${RENEW_THRESHOLD:-30}"
COTURN_CERT_DIR="${COTURN_CERT_DIR:-/etc/coturn}"
COTURN_USER="${COTURN_USER:-turnserver}"
COTURN_GROUP="${COTURN_GROUP:-turnserver}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"
    logger -t "coturn_renew_ssl" "[$1] $2" 2>/dev/null || true
}

error_exit() {
    log "ERROR" "$1"
    exit 1
}

# --------------------------------------------------
# Parse arguments
# --------------------------------------------------
if [ $# -eq 0 ]; then
    echo
    echo "Error: No domain provided."
    echo "Usage: $(basename "$0") your_domain"
    echo
    exit 1
fi

# Everything below needs root (reading /etc/letsencrypt, installing into /etc/coturn,
# restarting the service). Fail here rather than part-way through.
if [ "$EUID" -ne 0 ]; then
    error_exit "This script must be run as root."
fi

domain="$1"
cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
key_path="/etc/letsencrypt/live/$domain/privkey.pem"

[ -r "$cert_path" ] || error_exit "Certificate not found or unreadable: $cert_path"

# --------------------------------------------------
# Is it time yet?
# --------------------------------------------------
expiry_date=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2)
expiry_seconds=$(date -d "$expiry_date" +%s)
now_seconds=$(date +%s)
days_left=$(( (expiry_seconds - now_seconds) / 86400 ))

if (( days_left > RENEW_THRESHOLD )); then
    log "INFO" "Certificate for $domain expires in $days_left days; nothing to do"
    exit 0
fi

# --------------------------------------------------
# Renew
# --------------------------------------------------
# The renewal inherits authenticator=standalone from the initial `certbot certonly
# --standalone`, which needs port 80 to itself. If a web server was installed later
# it now holds that port and every renewal fails. Say so plainly instead of leaving
# the operator to find it in the certbot log after the certificate has expired.
if ss -tlnH "sport = :80" 2>/dev/null | grep -q .; then
    # `|| true`: under `set -euo pipefail` a grep that matches nothing would abort the
    # script here, and the message below -- the whole point of this branch -- would
    # never be printed. The holder name is a nicety; not knowing it is not fatal.
    holder=$(ss -tlnpH "sport = :80" 2>/dev/null | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
    error_exit "Port 80 is in use${holder:+ by $holder}, but renewal uses certbot's standalone authenticator which needs it. Stop that service for the renewal, or switch this certificate to --webroot / another ACME client."
fi

log "INFO" "Renewing Let's Encrypt certificate for $domain ($days_left days left)"
before=$(sha256sum "$cert_path" | cut -d' ' -f1)
certbot renew --non-interactive --quiet || error_exit "Failed to renew SSL certificate for $domain"
after=$(sha256sum "$cert_path" | cut -d' ' -f1)

if [ "$before" = "$after" ]; then
    log "WARNING" "certbot exited cleanly but the certificate is unchanged; not touching coturn"
    exit 0
fi

# --------------------------------------------------
# Hand it to coturn
# --------------------------------------------------
# `install` and not `cp`: turnserver runs as $COTURN_USER and cannot read a
# 0600 root:root key, and when it cannot read the key it starts anyway with its TLS
# and DTLS listeners disabled.
install -o root -g "$COTURN_GROUP" -m 644 "$cert_path" "$COTURN_CERT_DIR/fullchain.pem" \
    || error_exit "Failed to install fullchain.pem for coturn"
install -o root -g "$COTURN_GROUP" -m 640 "$key_path" "$COTURN_CERT_DIR/privkey.pem" \
    || error_exit "Failed to install privkey.pem for coturn"

sudo -u "$COTURN_USER" test -r "$COTURN_CERT_DIR/privkey.pem" \
    || error_exit "User '$COTURN_USER' cannot read $COTURN_CERT_DIR/privkey.pem after renewal"

# coturn reads its certificate once at startup, so copying the files in is not
# enough -- without this it would keep serving the expired one until something else
# restarted it.
systemctl restart coturn || error_exit "Renewed the certificate but failed to restart coturn"

for attempt in 1 2 3 4 5; do
    if ss -tlnH "sport = :5349" 2>/dev/null | grep -q .; then
        log "INFO" "Certificate renewed and coturn restarted; TLS listener is up"
        exit 0
    fi
    sleep 1
done

error_exit "coturn restarted after renewal but nothing is listening on 5349; check 'journalctl -u coturn'"
