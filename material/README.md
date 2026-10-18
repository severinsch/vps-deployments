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

Before an update with a schema change, take a backup: `./backup-db.sh`.

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

Not set up yet (test phase). Once real data exists, enable the cron job below and copy the backups off the VPS.

`backup-db.sh` writes a daily `pg_dump` to `backups/` and keeps 30 days. `crontab -e`:

```sh
15 3 * * * /home/deploy/vps-deployments/material/backup-db.sh >> /home/deploy/vps-deployments/material/backup.log 2>&1
```

Backups on the same VPS don't survive losing the VPS; copy them off occasionally, e.g.
`scp deploy@<vps>:vps-deployments/material/backups/* .`

Restore into the running database (replaces the existing objects):

```sh
docker compose exec -T material-db pg_restore -U scout -d scout_material --clean --if-exists < backups/<file>.dump
```

## Future improvements

- **Build images in CI:** a GitHub Actions workflow per repository that builds on every push to `main` and pushes to
  the GitHub Container Registry (`ghcr.io/severinsch/...`), tagged with the commit SHA and `latest`. Avoids pushing
  stale local builds and allows rolling back to an exact version (pin the tag in `docker-compose.yml`).
- **Off-site backups:** backups on the VPS are lost with the VPS. Enable Hetzner's server backups, or copy
  `backups/` nightly to a Hetzner Storage Box (`rsync` over SSH).
- **Health check for the API:** a `/health` endpoint would let the frontend wait for the API on startup.

