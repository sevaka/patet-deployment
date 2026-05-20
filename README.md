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

## Build-time PM2 scale-down / scale-up (default on)

Before **`yarn build`**, deploy scales **`patet-api`** and **`patet-website`** to **1** instance each (when registered in PM2). After build (or on failure via `EXIT` trap), it scales back to **2** each. If PM2 errors (e.g. `Nothing to do`), deploy **continues anyway**.

Disable: `PATET_BUILD_SCALE_PM2_DOWN=0 ./deploy.sh frontend`

`pm2 reload` / `startOrReload` at the end still applies the ecosystem config.

## Related scripts

- `deploy-config.sh` — paths, branches, health URLs (override with `PATET_API_ROOT`, etc.)
- `deploy-common.sh` — shared activate/finalize helpers (sourced by other scripts)
- `deploy.sh` — clone/build releases on the **server**, symlink `current`, PM2 reload/start. Optional **`--with-migrate`** (or `PATET_WITH_BACKEND_MIGRATE=1`) on backend deploy: run `yarn migration:run` on `current`, then `pm2 reload` (default: migrations off).
- `finalize-release.sh` — finalize a **Windows-uploaded** release (`yarn install` on Linux, symlink, migrate, PM2). Default: **runs backend migrations**.
- `deploy-from-windows.ps1` — build on Windows, upload, SSH to `finalize-release.sh`
- `deploy.local.env.example` — copy to `deploy.local.env` (gitignored) for SSH host/user
- `rollback.sh` — point `current` at a release, PM2 reload/start. On a TTY, run `./rollback.sh` with **no arguments** for an interactive menu (list releases with current/stable flags, set stable marker, or rollback) using numbered choices only; `backend|frontend|all|stable|status` with explicit arguments still work for automation.
- `migrate_backend.sh` — run TypeORM migrations from `current` (standalone)

---

## Deploy from Windows (build locally, push to Ubuntu)

Use this when the VPS struggles with Next.js build RAM, or when you want faster iteration from a dev PC.

**Do not upload `node_modules` from Windows.** Backend uses native modules (e.g. bcrypt); the server always runs `yarn install` on Linux inside the release directory.

### Windows prerequisites

| Item | Notes |
|------|--------|
| Node ≥ 20.12.2 | Matches `patet-website` engines |
| Yarn | Both app repos |
| Git | For `.patet-upload-sha` / status |
| OpenSSH (`ssh`, `scp`) | Built into Windows 10+ |
| Optional `rsync` or WSL | Faster uploads than tar+scp fallback |

### One-time setup

1. On the **server**: ensure release layout exists (`bootstrap_release_layout.sh`), shared `.env` files, PM2 apps, and this repo at `/var/www/patet-deployment` (`git pull` or copy scripts).
2. On **Windows**: in `patet-deployment`, copy `deploy.local.env.example` → `deploy.local.env` and set `PATET_SSH_HOST`, `PATET_SSH_USER`.
3. SSH key login to the VPS with write access to `/var/www/patet-api`, `/var/www/patet-website`, `/var/www/patet-deployment`.

**First Windows deploy:** sync server scripts if the server repo is stale:

```powershell
cd patet-deployment
.\deploy-from-windows.ps1 -Target all -SyncDeploymentScripts
```

Or on the server: `cd /var/www/patet-deployment && git pull`.

### Routine Windows deploy

```powershell
cd c:\path\to\Back_and_Front\patet-deployment
.\deploy-from-windows.ps1 -Target all
```

| Flag | Effect |
|------|--------|
| `-Target backend` / `frontend` / `all` | What to build and ship |
| `-SkipBuild` | Upload only (already built) |
| `-SkipMigrate` | Backend finalize without `yarn migration:run` |
| `-SkipUpload` | Build only, no upload/finalize |
| `-ReleaseId 2026-05-19_120000` | Fixed release folder name |
| `-SyncDeploymentScripts` | Copy `finalize-release.sh` + helpers to the server |

Flow:

1. `yarn build` locally (backend → `dist/src/main.js`, frontend → `.next/BUILD_ID`).
2. Write `.patet-upload-sha` from local `git HEAD`.
3. Upload to `/var/www/patet-api/releases/<id>` and `/var/www/patet-website/releases/<id>` (rsync or tar+scp).
4. SSH: `./finalize-release.sh all <id>` — Linux `yarn install`, symlink shared `.env`, **migrations**, PM2 reload, health checks.

Manual finalize on the server (if upload was done separately):

```bash
cd /var/www/patet-deployment
./finalize-release.sh backend 2026-05-19_143022
./finalize-release.sh frontend 2026-05-19_143022
# or: ./finalize-release.sh all 2026-05-19_143022
./finalize-release.sh backend 2026-05-19_143022 --skip-migrate
```

### Fallback: git push + server `deploy.sh`

When you do not want a Windows build:

1. Push to Bitbucket (`sevak_develop` / `develop_intermediate` by default in `deploy-config.sh`).
2. SSH to Ubuntu:

```bash
cd /var/www/patet-deployment
git pull
./deploy.sh backend --with-migrate
./deploy.sh frontend
# or: ./deploy.sh all --with-migrate
```

| Situation | Prefer |
|-----------|--------|
| VPS OOM on `next build` | Windows `deploy-from-windows.ps1` |
| No local Node / CI on Linux | `./deploy.sh` on server |
| Hotfix after git push only | `./deploy.sh` on server |

### Health checks and rollback

| Stack | Check |
|-------|--------|
| Backend | `curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:57303/api/v1/auth/me` → `200` or `401` |
| Frontend | `curl -fsS http://127.0.0.1:4993/` |

Status: `./deploy.sh status all`

Rollback: `./rollback.sh` (interactive) or `./rollback.sh backend <release_id>` — same release folders as Windows upload.

### Troubleshooting

- **`finalize-release.sh: command not found`** — `git pull` in `/var/www/patet-deployment` or re-run with `-SyncDeploymentScripts`.
- **Missing `dist` or `.next/BUILD_ID` on server** — build failed on Windows or upload excluded artifacts; re-run without `-SkipBuild`.
- **Migration errors** — fix DB issue, `./rollback.sh backend`, or redeploy previous release; use `--skip-migrate` only when intentional.
- **`pm2 logs patet-api` / `patet-website`** — runtime errors after activate.
- **Hostname `patet-website` in `uname -a`** — that is the **machine name**, not only the frontend app.

### Validate scripts locally (no VPS)

```bash
bash -n deploy.sh finalize-release.sh deploy-common.sh deploy-config.sh
```

```powershell
powershell -NoProfile -Command "& { $null = [System.Management.Automation.Language.Parser]::ParseFile('deploy-from-windows.ps1', [ref]$null, [ref]$errs); if ($errs) { $errs; exit 1 } }"
```
