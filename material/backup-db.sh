#!/bin/bash
# Backup of the material database: a pg_dump kept on the VPS for 30 days, pushed to Cloudflare R2 with restic.
# healthchecks.io is pinged only when every step succeeded; a missing ping raises the alert.
# Setup and restore: README.md, "Backups".
set -euo pipefail
umask 077   # the dumps contain personal data

cd /home/deploy/vps-deployments/material/
echo "Database backup started at $(date)"

[ -f backup.env ] || { echo "backup.env is missing, see README.md (Backups)" >&2; exit 1; }
set -a; . ./backup.env; set +a   # export the variables to restic

# Dump the database in Postgres' custom format (restore with pg_restore).
mkdir -p backups
file="backups/scout_material-$(date +%F).dump"
docker compose exec -T material-db pg_dump -U scout -d scout_material -Fc > "$file" || { rm -f "$file"; exit 1; }

# Keep the last 30 days locally.
find backups -name 'scout_material-*.dump' -mtime +30 -delete

# Off-site: every snapshot holds the dump as scout_material.dump, so a restore is `restic dump latest
# scout_material.dump`. The fixed host name keeps a rebuilt server in the same series of snapshots.
restic backup --host material --stdin-filename scout_material.dump --stdin < "$file"
restic forget --quiet --host material --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
restic check --quiet --read-data   # downloads and verifies everything stored (a few MB)

curl -fsS -m 10 --retry 5 -o /dev/null "$HC_PING_URL"
echo "Database backup $file finished at $(date)"
