#!/bin/bash

cd /home/deploy/vps-deployments/proxy/ || exit

# Renew all certificates managed by Certbot
docker compose run --rm certbot renew

# Reload Nginx to pick up renewed certificates (no downtime)
docker compose exec nginx nginx -s reload

echo "Certificate renewal finished at $(date)"
