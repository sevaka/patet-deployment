# Patet production deployment scripts

Scripts on the VPS under `/var/www/patet-deployment` (paths in `deploy.sh`).

## Backend PM2: cluster mode (`patet-api`)

`ecosystem.config.js` runs **`patet-api`** in **`cluster`** mode with **`instances: 2`** so `pm2 reload` (used by `deploy.sh` and `rollback.sh`) can rotate workers one-by-one for near-zero downtime on a single host.

**RAM:** expect roughly twice the peak memory of one API process; confirm `free -h` headroom before adoption.

### One-time adoption (fork → cluster) on production

Run on the Linux server after pulling this repo’s updated `ecosystem.config.js`:

1. Note current status: `pm2 describe patet-api`
2. Recreate the process from the ecosystem file (brief listener gap possible during this single cutover):
   - `pm2 delete patet-api`
   - `pm2 start /var/www/patet-deployment/ecosystem.config.js --only patet-api --update-env`
3. Persist PM2: `pm2 save`
4. Verify two workers: `pm2 list` (cluster shows multiple ids under `patet-api`)
5. Health check (same as deploy script): `curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:57303/api/v1/auth/me` — expect `200` or `401`.

After this, routine deploys use `./deploy.sh backend`, which updates `/var/www/patet-api/current` and runs **`pm2 reload`** for rolling reloads.

## Frontend PM2: cluster mode (`patet-website`)

`ecosystem.config.js` runs **`patet-website`** (Next.js production server) in **`cluster`** mode with **`instances: 2`** on **`127.0.0.1:4993`**, so deploys can rotate workers without a full hard stop of every Next process at once.

**Layout:** app directory is **`/var/www/patet-website/current`** (release dirs under `/var/www/patet-website/releases/…`, same symlink pattern as the API).

**RAM:** expect roughly twice the peak memory of one Next worker; confirm `free -h` headroom.

### Deploy and rollback behavior

- **`deploy.sh frontend`** updates `/var/www/patet-website/current` after `yarn build`, then runs **`pm2 startOrReload`** for `patet-website` (cluster-friendly reload when the app already exists).
- **`rollback.sh`** (frontend or `all`) uses **`pm2 reload`** when the process exists (same rolling idea as the backend section).

### One-time recreate on production (optional)

Use if you need to re-register `patet-website` from this ecosystem file (e.g. fresh PM2 state). Expect a short gap while listeners restart:

1. `pm2 describe patet-website`
2. `pm2 delete patet-website`
3. `pm2 start /var/www/patet-deployment/ecosystem.config.js --only patet-website --update-env`
4. `pm2 save`
5. Verify cluster workers: `pm2 list`
6. Health check: `curl -fsS http://127.0.0.1:4993/` (same check `deploy.sh` / `rollback.sh` rely on).

Routine deploys: `./deploy.sh frontend`.

## Related scripts

- `deploy.sh` — clone/build releases, symlink `current`, PM2 reload/start (backend reload; frontend `startOrReload`)
- `rollback.sh` — point `current` at a release, PM2 reload/start
- `migrate_backend.sh` — run TypeORM migrations from `current`
