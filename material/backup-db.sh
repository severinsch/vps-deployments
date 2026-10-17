#!/bin/bash

cd /home/deploy/vps-deployments/material/ || exit 1
mkdir -p backups

# Dump the database in Postgres' custom format (restore with pg_restore).
file="backups/scout_material-$(date +%F).dump"
docker compose exec -T material-db pg_dump -U scout -d scout_material -Fc > "$file" || { rm -f "$file"; exit 1; }

# Keep the last 30 days.
find backups -name 'scout_material-*.dump' -mtime +30 -delete

echo "Database backup $file finished at $(date)"
