# Material service deployment

Stack for [material-frontend](https://github.com/severinsch/material-frontend) and
[material-api](https://github.com/severinsch/material-api) at `material.dpsg-langenbach.de`.

- `material-frontend` (SvelteKit, port 3000) is the only service on `proxy-tier`. It forwards `/api/*` to the API.
- `material-api` (Ktor, port 8080) and `material-db` (Postgres) are only on the stack's internal network.
- Users log in with username and password; accounts are created by admins, see "Accounts" below. nginx limits
  `POST` to `/login` and `/setup` per IP (`proxy/nginx.conf`), in addition to the API's throttling of failed logins.

## Build and push images

Locally, in each repository:

```sh
# material-api
docker build -t severinsch/material-api:latest .
docker push severinsch/material-api:latest

# material-frontend
docker build -t severinsch/material-frontend:latest .
docker push severinsch/material-frontend:latest
```

## First deployment

On the VPS:

1. Point `material.dpsg-langenbach.de` at the VPS.
2. Prepare the stack:

   ```sh
   cd ~/vps-deployments/material
   cp .env.example .env    # set POSTGRES_PASSWORD, e.g. openssl rand -base64 32
   docker compose pull
   docker compose up -d
   docker compose logs -f material-api   # shows the Flyway migrations on first start
   ```

3. Issue the certificate. The 443 block for the domain in `proxy/nginx.conf` must be commented out until the
   certificate exists (see "HOW TO ADD A NEW APPLICATION" there):

   ```sh
   cd ~/vps-deployments/proxy
   docker compose exec nginx nginx -s reload
   docker compose run --rm certbot certonly --webroot -w /var/www/certbot -d material.dpsg-langenbach.de
   ```

4. Uncomment the 443 block and run `docker compose exec nginx nginx -s reload`.
5. Set up the backups, see "Backups" below.

## Update

```sh
cd ~/vps-deployments/material
docker compose pull
docker compose up -d
```

The data lives in the named volume `material_material_db_data` and survives `docker compose down`, image updates and
reboots. Only `docker compose down -v` (or `docker volume rm`) deletes it.

Schema changes are applied by the API itself (Flyway migrations) when the new version starts. If a migration fails,
the API doesn't start and the database is left as it was before that migration; `docker compose logs material-api`
shows why. While testing, the database can be reset with `docker compose down -v && docker compose up -d`.

Before an update with a schema change, take a backup: `./backup-db.sh` (also pushes to R2).

## Accounts

**First admin:** on startup, if there is no platform admin, the API creates the user `admin` and logs a setup link
until its password is set:

```sh
docker compose logs material-api | grep -i 'setup link'
```

Open the link, set the password, then create the tenants (Stämme) and accounts under "Administration". Admins pass
each new account's setup link on themselves (no email).

**Forgotten password:** admins of a Stamm create a new setup link on its members page. If the only platform admin
forgot theirs, start the API once with a new link for them:

```sh
ADMIN_SETUP_LINK_FOR=<username> docker compose up -d --force-recreate material-api
docker compose logs material-api | grep -i 'setup link'
```

After setting the password, run `docker compose up -d` once more: it recreates the container without the variable,
which would otherwise log a new link on every restart.

## Backups

`backup-db.sh` runs daily from cron. It writes a `pg_dump` to `backups/` on the VPS (kept 30 days, readable only by
`deploy`) and pushes it with [restic](https://restic.net) to a Cloudflare R2 bucket: encrypted, one snapshot per day for
a week, per week for 5 weeks, per month for a year. Afterwards it verifies everything stored and pings
[healthchecks.io](https://healthchecks.io), which sends an e-mail when a day's ping is missing, i.e. when any step
failed or the job stopped running. Output goes to `backup.log`.

Only the database needs a backup: everything else is in this repository or can be made again (certificates).
Deleted personal data stays in the backups until they expire (up to 12 months).

**Secrets:** `backup.env` (restic password, R2 keys, ping URL) exists only on the VPS and in the Bitwarden item
"material backups" of the owner (severinsch), who also owns the Cloudflare and healthchecks.io accounts. Without the
restic password, the backups can't be decrypted. This repository is public: never commit `backup.env`.

### One-time setup

1. **Cloudflare** (R2): create the bucket `material-backups` with jurisdiction **EU** (not just a location hint). Under
   "Manage API tokens", create a token with "Object Read & Write" for this bucket only; note the access key ID, the
   secret and the account ID. Under "Client IP Address Filtering", allow only the VPS's IPv4 address and its IPv6
   range (`/64`; connections to R2 may use either). An EU bucket is only reachable through the `.eu.` endpoint; if
   `restic init` says Access Denied, check the jurisdiction, the token's bucket and its IP filter first.
2. **healthchecks.io:** create a check with schedule type "Cron", `15 3 * * *`, the VPS's timezone and a grace time
   of 1 hour; note the ping URL.
3. **VPS:**

   ```sh
   sudo apt install restic
   cd ~/vps-deployments/material
   cp backup.env.example backup.env && chmod 600 backup.env   # fill in; RESTIC_PASSWORD: openssl rand -hex 32
   set -a; . ./backup.env; set +a
   restic init
   ./backup-db.sh                                               # once by hand; the check turns green
   crontab -e
   ```

   ```sh
   15 3 * * * /home/deploy/vps-deployments/material/backup-db.sh >> /home/deploy/vps-deployments/material/backup.log 2>&1
   ```

4. **Bitwarden:** store all values of `backup.env` in the item "material backups".

### Checking

The e-mail from healthchecks.io is the signal. By hand: `tail backup.log`, or the snapshots in R2:

```sh
cd ~/vps-deployments/material
set -a; . ./backup.env; set +a
restic snapshots
```

### Restore into the running database

Replaces the existing objects. Stop the API first so no one writes in between:

```sh
cd ~/vps-deployments/material
docker compose stop material-api
# from the local dumps:
docker compose exec -T material-db pg_restore -U scout -d scout_material --clean --if-exists \
  --exit-on-error --single-transaction < backups/<file>.dump
# or from R2 (latest, or a snapshot ID from `restic snapshots`):
set -a; . ./backup.env; set +a
restic dump latest scout_material.dump | docker compose exec -T material-db pg_restore -U scout -d scout_material \
  --clean --if-exists --exit-on-error --single-transaction
docker compose up -d
```

`--exit-on-error --single-transaction` makes a failed restore change nothing; without them `pg_restore` carries on past
errors and leaves a partial database.

### Restore onto a fresh server

Install Docker, clone this repository to `~/vps-deployments`, set up `proxy/` and the certificate (see "First
deployment"). The R2 token only accepts the old server's addresses: in Cloudflare (R2, "Manage API tokens"), add the new
server's IPv4 address and IPv6 range to the token's IP filter, or restic gets Access Denied. Then:

```sh
sudo apt install restic
cd ~/vps-deployments/material
cp .env.example .env                                        # a new POSTGRES_PASSWORD is fine
cp backup.env.example backup.env && chmod 600 backup.env    # values from Bitwarden
docker compose up -d --wait material-db
# The role belongs to the server, not the database, so the dump doesn't contain it; its GRANTs fail without it.
docker compose exec -T material-db psql -U scout -d scout_material -c 'CREATE ROLE material_app NOLOGIN'
set -a; . ./backup.env; set +a
restic dump latest scout_material.dump \
  | docker compose exec -T material-db pg_restore -U scout -d scout_material --exit-on-error --single-transaction
docker compose up -d
```

The API sees the migration history from the dump and only applies newer migrations. If `pg_restore` fails, the
database is still empty: fix the cause and run the `restic dump` line again. Then set up cron and healthchecks.io as
in "One-time setup" (step 3 from `crontab -e`).

### Test a restore

Restores the latest snapshot into a throwaway container and compares a few row counts with the live database:

```sh
cd ~/vps-deployments/material
set -a; . ./backup.env; set +a
docker run -d --name restore-test -e POSTGRES_USER=scout -e POSTGRES_PASSWORD=test -e POSTGRES_DB=scout_material \
  postgres:18-alpine
until docker exec restore-test pg_isready -q -h 127.0.0.1 -U scout -d scout_material; do sleep 1; done
docker exec restore-test psql -U scout -d scout_material -c 'CREATE ROLE material_app NOLOGIN'
restic dump latest scout_material.dump \
  | docker exec -i restore-test pg_restore -U scout -d scout_material --exit-on-error --single-transaction
counts="SELECT (SELECT count(*) FROM tenants) tenants, (SELECT count(*) FROM users) users,
  (SELECT count(*) FROM materials) materials, (SELECT count(*) FROM individual_items) items,
  (SELECT count(*) FROM loans) loans, (SELECT max(installed_rank) FROM flyway_schema_history) migrations"
docker exec restore-test psql -U scout -d scout_material -c "$counts"
docker compose exec -T material-db psql -U scout -d scout_material -c "$counts"
docker rm -f restore-test
```

The counts match unless something changed since the last backup (03:15).

## Future improvements

- **Build images in CI:** a GitHub Actions workflow per repository that builds on every push to `main` and pushes to
  the GitHub Container Registry (`ghcr.io/severinsch/...`), tagged with the commit SHA and `latest`. Avoids pushing
  stale local builds and allows rolling back to an exact version (pin the tag in `docker-compose.yml`).
- **Hetzner Cloud Backups** (20 % of the server price): whole-server images, quick to roll back a broken update.
  They're deleted with the server, so they don't replace the R2 backups.
- **Health check for the API:** a `/health` endpoint would let the frontend wait for the API on startup.

