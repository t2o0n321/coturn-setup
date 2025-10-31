#!/bin/bash

# --------------------------------------------------
# Parse arguments
# --------------------------------------------------
# If no argument is provided, display an error message
if [ $# -eq 0 ]; then
  echo
  echo "Error: No domain provided."
  echo "Usage: $(basename $0) your_domain"
  echo
  exit 1
fi

domain=$1
cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
RENEW_THRESHOLD=7

# Check if the certificate is about to expire (within 7 days)
expiry_date=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2)
expiry_seconds=$(date -d "$expiry_date" +%s)
now_seconds=$(date +%s)
days_left=$(( (expiry_seconds - now_seconds) / 86400 ))

if (( days_left > RENEW_THRESHOLD )); then
    echo "The certificate for $domain will expire in $days_left days, no need to renew"
    exit 0
fi

# Renew SSL certificate
echo "Renewing Let's Encrypt certificate for $domain..."
sudo certbot renew --non-interactive --quiet || error_exit "Failed to renew SSL certificate"

# Update Openfire Keystore
tmp_dir=$(mktemp -d)
cd "$tmp_dir"
sudo cp "/etc/letsencrypt/live/$domain/fullchain.pem" fullchain.pem || error_exit "Failed to copy fullchain.pem"
sudo cp "/etc/letsencrypt/live/$domain/privkey.pem" privkey.pem || error_exit "Failed to copy privkey.pem"
sudo openssl pkcs12 -export -in fullchain.pem -inkey privkey.pem -out openfire.p12 -name openfire -password pass:changeit || error_exit "Failed to export to pkcs12"
sudo keytool -delete -alias openfire -keystore /usr/share/openfire/resources/security/keystore -storepass changeit || error_exit "Failed to delete old certificate"
sudo keytool -importkeystore -srckeystore openfire.p12 -srcstoretype PKCS12 -destkeystore /usr/share/openfire/resources/security/keystore -deststoretype JKS -srcstorepass changeit -deststorepass changeit || error_exit "Failed to import new certificate"
cd ..
rm -rf "$tmp_dir"

# Update coturn certificates
sudo cp "/etc/letsencrypt/live/$domain/fullchain.pem" /etc/coturn/fullchain.pem || error_exit "Failed to copy fullchain.pem for coturn"
sudo cp "/etc/letsencrypt/live/$domain/privkey.pem" /etc/coturn/privkey.pem || error_exit "Failed to copy privkey.pem for coturn"