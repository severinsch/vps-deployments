# DPSG Letter service deployment

## Full deployment guide

(All for both letter-frontend and letter-api)

1. build docker containers
   - `docker build -t letter-frontend .`

2. tag docker containers:
   - `docker tag letter-frontend severinsch/letter-frontend:latest`

3. push docker containers
   - `docker push severinsch/letter-frontend:latest`

On VPS:

1. `cd dpsg-letter`
2. `docker pull severinsch/letter-frontend:latest`
3. `docker compose down`
4. `docker compose up -d`

## Set up certificate auto-renewal

- `crontab -e`
Add the following to the bottom of the file:

```sh
# At 4:30 AM and 4:30 PM every day, run the certificate renewal script.
# Using two times a day is the standard recommendation from Certbot.
#
# The '>> ... 2>&1' part logs the output of the script, which is
# extremely useful for debugging if something goes wrong.
30 4,16 * * * /home/deploy/vps-deployments/dpsg-letter/renew-certs.sh >> /home/deploy/vps-deployments/dpsg-letter/cron.log 2>&1
```

- `docker compose run --rm certbot renew`: Trigger check
- `docker compose run --rm certbot renew --force-renewal`: Force renewal
- `docker compose run --rm certbot certificates`: Check status, expiration date, etc