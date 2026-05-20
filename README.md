# Patet production deployment scripts

Scripts on the VPS live under `/var/www/patet-deployment` (paths in `deploy-config.sh`).

## Quick reference: which deploy path?

| Goal | Where | Command |
|------|--------|---------|
| Build on Windows, run on Ubuntu (recommended for heavy Next.js builds) | Windows PC | `.\deploy-from-windows.ps1 -Target all` |
| Build and deploy entirely on the server | Ubuntu VPS | `./deploy.sh all --with-migrate` |
| Backend only from Windows | Windows PC | `.\deploy-from-windows.ps1 -Target backend` |
| Frontend only from Windows | Windows PC | `.\deploy-from-windows.ps1 -Target frontend` |
| Check what is running | Ubuntu VPS | `./deploy.sh status all` |
| Roll back | Ubuntu VPS | `./rollback.sh` (interactive) or `./rollback.sh backend <release_id>` |

**Rule:** never upload `node_modules` from Windows. Native modules (e.g. bcrypt) must be installed on Linux via `yarn install` during finalize.

---

## One-time setup

### A. Ubuntu server

Run as a user with write access to `/var/www` (often `root`).

| Step | Action |
|------|--------|
| 1 | Install **Node 20.12.2+** and **Yarn** (this VPS often uses **nvm** under `~/.nvm`). |
| 2 | Install **PM2** globally (`pm2 -v` should work after loading nvm). |
| 3 | Clone or copy this repo to `/var/www/patet-deployment`. |
| 4 | Create release layout: `cd /var/www/patet-deployment && bash bootstrap_release_layout.sh` |
| 5 | Place shared env files: `/var/www/patet-api/shared/.env` and `/var/www/patet-website/shared/.env` (and `ca-certificate.crt` for the API if used). |
| 6 | Start PM2 apps once from the ecosystem file (see [PM2 cluster](#backend-pm2-cluster-mode-patet-api) below). |
| 7 | `pm2 save` and enable PM2 on boot if not already (`pm2 startup`). |

Verify on the server (interactive SSH, after nvm loads):

```bash
node -v    # expect v20.12.2 or newer
yarn -v
pm2 list
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:57303/api/v1/auth/me   # 200 or 401
curl -fsS http://127.0.0.1:4993/ || echo "frontend not up yet"
```

### B. Windows PC

| Step | Action |
|------|--------|
| 1 | Install **Node ≥ 20.12.2**, **Yarn**, **Git**. |
| 2 | Use **OpenSSH** (`ssh`, `scp`) — built into Windows 10+. |
| 3 | Clone repos next to each other, e.g. `Front_and_Back/patet-back-nestjs`, `patet-website`, `patet-deployment`. |
| 4 | Copy `deploy.local.env.example` → `deploy.local.env` (gitignored). |
| 5 | Set `PATET_SSH_HOST`, `PATET_SSH_USER`, and `PATET_SSH_EXTRA_ARGS` (see [SSH keys](#ssh-keys-windows--ubuntu)). |
| 6 | Test SSH: `ssh -i C:\Users\YOU\.ssh\id_rsa USER@HOST "echo ok"` |

### C. First Windows deploy (sync scripts to server)

Server scripts must include `finalize-release.sh` and the current `deploy-common.sh` (nvm + CRLF fixes). Either:

**Option 1 — from Windows:**

```powershell
cd c:\path\to\Front_and_Back\patet-deployment
.\deploy-from-windows.ps1 -Target backend -SyncDeploymentScripts
```

**Option 2 — on the server:**

```bash
cd /var/www/patet-deployment && git pull
sed -i 's/\r$//' *.sh && chmod +x finalize-release.sh deploy.sh rollback.sh
```

Then run a full deploy (backend, frontend, or both).

---

## Routine deploy from Windows

Default flow: **local build → upload → finalize on Linux** (`yarn install`, symlink `.env`, migrations, PM2 reload).

```powershell
cd c:\path\to\Front_and_Back\patet-deployment
.\deploy-from-windows.ps1 -Target all
```

| Flag | When to use |
|------|----------------|
| `-Target backend` / `frontend` / `all` | Ship one stack or both |
| `-SkipBuild` | Artifacts already built locally |
| `-SkipMigrate` | Backend finalize without `yarn migration:run` |
| `-SkipUpload` | Build only; no upload or finalize |
| `-ReleaseId 2026-05-20_120000` | Reuse or fix a specific release folder |
| `-SyncDeploymentScripts` | Push updated `finalize-release.sh`, `deploy-common.sh`, etc. to the server |

What the script does:

1. `yarn install` + `yarn build` locally (backend → `dist/src/main.js`, frontend → `.next/BUILD_ID`).
2. Writes `.patet-upload-sha` from local `git HEAD`.
3. Uploads to `/var/www/patet-api/releases/<id>` and/or `/var/www/patet-website/releases/<id>`.
4. SSH runs `./finalize-release.sh <target> <id>` on the server.

**Typical cadence:** use `-SyncDeploymentScripts` when deployment scripts changed; otherwise routine deploy is just `-Target all`.

### Resume after a failed upload

If build succeeded but upload/finalize failed, reuse the same release id:

```powershell
.\deploy-from-windows.ps1 -Target backend -SkipBuild -ReleaseId 2026-05-20_041834
```

### Manual finalize (upload already on server)

```bash
cd /var/www/patet-deployment
./finalize-release.sh backend 2026-05-20_143022
./finalize-release.sh frontend 2026-05-20_143022
./finalize-release.sh all 2026-05-20_143022
./finalize-release.sh backend 2026-05-20_143022 --skip-migrate
```

---

## Routine deploy on the server (no Windows build)

Push app code to Bitbucket, then on Ubuntu:

```bash
cd /var/www/patet-deployment
git pull
./deploy.sh backend --with-migrate
./deploy.sh frontend
# or:
./deploy.sh all --with-migrate
```

Default branches: `sevak_develop` (API), `develop_intermediate` (website) — see `deploy-config.sh`.

| Situation | Prefer |
|-----------|--------|
| VPS OOM on `next build` | Windows `deploy-from-windows.ps1` |
| No local Node / only server access | `./deploy.sh` on server |
| Hotfix after git push only | `./deploy.sh` on server |

---

## SSH keys (Windows → Ubuntu)

`deploy-from-windows.ps1` uses **OpenSSH** (`ssh` / `scp`), not PuTTY `.ppk` files.

### Use an existing OpenSSH key

In `deploy.local.env`:

```env
PATET_SSH_EXTRA_ARGS=-i C:\Users\YOU\.ssh\id_rsa
```

**Private key permissions:** OpenSSH rejects keys that other users can read. In PowerShell (replace path if needed):

```powershell
icacls "C:\Users\YOU\.ssh\id_rsa" /inheritance:r
icacls "C:\Users\YOU\.ssh\id_rsa" /grant:r "${env:USERNAME}:(R)"
```

Test:

```powershell
ssh -i C:\Users\YOU\.ssh\id_rsa USER@HOST "echo ok"
```

### PuTTY `.ppk` only?

Convert in **PuTTYgen**: Load `.ppk` → **Conversions** → **Export OpenSSH key** → save without `.ppk` extension, then point `PATET_SSH_EXTRA_ARGS` at that file.

### New key (optional)

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_ed25519_patet" -C "patet-deploy"
type $env:USERPROFILE\.ssh\id_ed25519_patet.pub | ssh USER@HOST "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

### Install public key on server (one time)

```powershell
type C:\Users\YOU\.ssh\id_rsa.pub | ssh USER@HOST "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

---

## Upload: rsync vs tar+scp

| Method | When |
|--------|------|
| **rsync** (native or WSL with `rsync` installed) | Faster; incremental |
| **tar + scp** (automatic fallback) | Default on many Windows PCs; no WSL/rsync required |

The Windows script tries rsync only if it is actually available (native `rsync` on PATH, or `rsync` inside WSL). If rsync fails or is missing, it falls back to tar+scp automatically.

Optional faster uploads — install rsync in WSL:

```bash
wsl sudo apt update && wsl sudo apt install -y rsync
```

---

## Health checks, status, rollback

| Stack | Check |
|-------|--------|
| Backend | `curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:57303/api/v1/auth/me` → `200` or `401` |
| Frontend | `curl -fsS http://127.0.0.1:4993/` |

```bash
cd /var/www/patet-deployment
./deploy.sh status all
pm2 logs patet-api --lines 100
pm2 logs patet-website --lines 100
```

Rollback (same release folders as Windows upload):

```bash
./rollback.sh                    # interactive menu
./rollback.sh backend <release_id>
./rollback.sh frontend <release_id>
```

---

## `deploy.local.env` reference

Copy from `deploy.local.env.example`:

| Variable | Purpose |
|----------|---------|
| `PATET_SSH_HOST` | VPS IP or hostname |
| `PATET_SSH_USER` | SSH user (e.g. `root`, `deploy`) |
| `PATET_SSH_EXTRA_ARGS` | e.g. `-i C:\Users\YOU\.ssh\id_rsa` |
| `PATET_API_ROOT` | Default `/var/www/patet-api` |
| `PATET_WEB_ROOT` | Default `/var/www/patet-website` |
| `PATET_DEPLOYMENT_ROOT` | Default `/var/www/patet-deployment` |
| `PATET_LOCAL_BACKEND` | Relative or absolute path to API repo |
| `PATET_LOCAL_FRONTEND` | Relative or absolute path to website repo |
| `PATET_WITH_BACKEND_MIGRATE` | `1` = run migrations on Windows artifact deploy (default) |

---

## Related scripts

| File | Role |
|------|------|
| `deploy-config.sh` | Paths, branches, health URLs |
| `deploy-common.sh` | Shared helpers (nvm PATH, activate, finalize) |
| `deploy.sh` | Clone/build on **server**, symlink `current`, PM2 |
| `finalize-release.sh` | Finalize **Windows-uploaded** release |
| `deploy-from-windows.ps1` | Build on Windows, upload, SSH finalize |
| `deploy.local.env.example` | Template for Windows SSH settings |
| `bootstrap_release_layout.sh` | One-time `releases/` + `shared/` dirs |
| `rollback.sh` | Point `current` at older release, PM2 reload |
| `migrate_backend.sh` | Run migrations from `current` only |
| `ecosystem.config.js` | PM2 cluster config for API + website |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|----------------|-----|
| Stuck at **tar+scp** for a long time | Packing **`.next/cache`** (~800MB+) or locked **`.next/trace`** | Pull latest `deploy-from-windows.ps1` (excludes cache/trace); stop `next dev` before deploy; watch for `Archive ready: N MB` log line |
| `rsync: not found` (WSL) | WSL without rsync | Ignore — script falls back to tar+scp; or install rsync in WSL |
| `pipefail: invalid option name` | Shell scripts have Windows **CRLF** | On server: `sed -i 's/\r$//' /var/www/patet-deployment/*.sh`; re-run with `-SyncDeploymentScripts` |
| `Missing command: yarn` over SSH | **nvm** not loaded in non-interactive shell | Pull latest `deploy-common.sh` (auto-loads nvm) or run finalize from a login shell |
| `Permission denied (publickey)` | Wrong key, or `.ppk` instead of OpenSSH key | Use `PATET_SSH_EXTRA_ARGS=-i ...\id_rsa`; fix key permissions (see [SSH keys](#ssh-keys-windows--ubuntu)) |
| `UNPROTECTED PRIVATE KEY FILE` | Key readable by other Windows users | `icacls` commands in SSH section above |
| `finalize-release.sh: command not found` | Stale/missing server scripts | `git pull` in `/var/www/patet-deployment` or `-SyncDeploymentScripts` |
| Missing `dist` or `.next/BUILD_ID` | Local build failed or incomplete upload | Re-run without `-SkipBuild` |
| Migration errors | DB/schema issue | Fix DB, `./rollback.sh backend`, redeploy; `--skip-migrate` only when intentional |
| Hostname `patet-website` in `uname -a` | **Machine hostname**, not the PM2 app name | No action needed |

---

## Validate scripts locally (no VPS)

```bash
bash -n deploy.sh finalize-release.sh deploy-common.sh deploy-config.sh
```

```powershell
powershell -NoProfile -File scripts/validate-deploy-scripts.ps1
```

Or:

```powershell
powershell -NoProfile -Command "& { $null = [System.Management.Automation.Language.Parser]::ParseFile('deploy-from-windows.ps1', [ref]$null, [ref]$errs); if ($errs) { $errs; exit 1 } }"
```

---

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

## Frontend build memory cap

Deploy sets **`BUILD_MEM_MAX=2G`** and **`BUILD_CPU_MAX_PERCENT=40`** (40% per logical CPU) for builds unless you override. Example: `BUILD_MEM_MAX=1536M ./deploy.sh frontend`
