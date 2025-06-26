#!/bin/bash

cd /home/deploy/vps-deployments/dpsg-letter/ || exit

# run the Certbot renew command
docker compose run --rm certbot renew

# reload the Nginx proxy to pick up the new certificate
docker compose restart proxy

echo "Certificate renewal script finished at $(date)"
