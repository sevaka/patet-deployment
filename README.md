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
- **`rollback.sh`** (frontend or `all`) uses **`pm2 reload`** when the process exists (same rolling idea as the backend section). From an interactive shell, `./rollback.sh` with no args opens a menu (list / set stable / rollback) with numbered selections.

### One-time recreate on production (optional)

Use if you need to re-register `patet-website` from this ecosystem file (e.g. fresh PM2 state). Expect a short gap while listeners restart:

1. `pm2 describe patet-website`
2. `pm2 delete patet-website`
3. `pm2 start /var/www/patet-deployment/ecosystem.config.js --only patet-website --update-env`
4. `pm2 save`
5. Verify cluster workers: `pm2 list`
6. Health check: `curl -fsS http://127.0.0.1:4993/` (same check `deploy.sh` / `rollback.sh` rely on).

Routine deploys: `./deploy.sh frontend`.

## Build-time PM2 scale-down (low-memory VPS)

Before **`yarn build`** (backend or frontend), `deploy.sh` scales **`patet-api`** and **`patet-website`** from **2 → 1** cluster worker each (when those apps are already registered in PM2). That frees roughly one API + one Next worker worth of RAM during compile. After a successful build, cluster size is restored to **2** before `pm2 reload` / `startOrReload` (which also match `instances: 2` in `ecosystem.config.js`). On build failure, the same restore runs via an `EXIT` trap.

Disable: `PATET_BUILD_SCALE_PM2_DOWN=0 ./deploy.sh frontend`

## Related scripts

- `deploy.sh` — clone/build releases, symlink `current`, PM2 reload/start (backend reload; frontend `startOrReload`). Optional **`--with-migrate`** (or `PATET_WITH_BACKEND_MIGRATE=1`) on backend deploy: after a successful `yarn build`, run `yarn migration:run` on `current`, then `pm2 reload` (default deploy does not run migrations).
- `rollback.sh` — point `current` at a release, PM2 reload/start. On a TTY, run `./rollback.sh` with **no arguments** for an interactive menu (list releases with current/stable flags, set stable marker, or rollback) using numbered choices only; `backend|frontend|all|stable|status` with explicit arguments still work for automation.
- `migrate_backend.sh` — run TypeORM migrations from `current` (standalone; also used by deploy when `--with-migrate` is set)
