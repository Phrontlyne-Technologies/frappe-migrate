# frappe-migrate

Copy a running **Frappe / ERPNext** site from one server to a **fresh Ubuntu VPS** in one command, with
everything production-ready on the other side: MariaDB, Redis, Node, bench, nginx, supervisor, wkhtmltopdf,
a dedicated bench user, your app code *exactly as it is on the source*, the restored database and files, a
completed `bench migrate`, and a spreadsheet with every credential involved.

It works as a plain set of bash scripts, and also as a [Claude Code](https://claude.com/claude-code) **skill**,
so you can say *"migrate the ERP to 203.0.113.10 as new.site"* and Claude will run it, watch it, and fix problems.

---

## Contents
- [What it does](#what-it-does)
- [Why not just `bench get-app` / Docker?](#why-not-just-bench-get-app--docker)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Configuration (`config.env`)](#configuration-configenv)
- [The steps in detail](#the-steps-in-detail)
- [Using it as a Claude Code skill](#using-it-as-a-claude-code-skill)
- [Verifying the migration](#verifying-the-migration)
- [The credentials spreadsheet](#the-credentials-spreadsheet)
- [Troubleshooting](#troubleshooting)
- [After the migration](#after-the-migration)
- [Security notes](#security-notes)
- [Repository layout](#repository-layout)

---

## What it does

```
 SOURCE server (your running ERP)                  TARGET VPS (fresh Ubuntu)
 ─────────────────────────────────                 ──────────────────────────
 step 0  SSH key ───────────────────────────────▶  root can be reached without a password
                                                   step 1  apt deps, MariaDB, Redis, Node, yarn,
                                                           bench CLI, nginx, supervisor, wkhtmltopdf,
                                                           bench user (sudo + SSH key)
 step 2  backup --with-files, row counts,
         pip freeze, rsync apps/ + backup ──────▶  ~/frappe-bench/apps, ~/migrate/
                                                   step 3  venv (exact source packages), yarn, build,
                                                           new-site, restore, copy encryption_key,
                                                           migrate, enable scheduler, compare row counts
                                                   step 4  supervisor + nginx configs, start everything
 step 5  credentials .xlsx  ◀── reads site DB creds from target
```

The site can be **renamed** on the way (e.g. `newERP` → `best.site`). All ERP users, including Administrator,
keep their passwords because they come from the database backup.

## Why not just `bench get-app` / Docker?

Real-world benches drift from their git remotes: hot-fixes edited in place, custom apps that were never
pushed, apps with no remote at all. `bench get-app` would clone clean upstream code and **silently drop all of
that**. This tool rsyncs `apps/` as-is (including `.git`) and prints a per-app report of uncommitted changes
and missing remotes before copying, so you know what exists only on the source.

Docker would mean building custom images that include the modified apps and switching to a different way of
running things. When both ends run the same Ubuntu, a native install is simpler and matches what you
already operate.

What is **not** copied (it is regenerated, because it's machine-specific): `env/`, `node_modules/`,
`sites/assets`, redis/supervisor/nginx configs.

## Requirements

**Source server** (where you run this):
- A working bench (tested with Frappe/ERPNext v15, bench CLI 5.22) and the bench user's shell.
- `rsync`, `ssh`, `git`. `sshpass` is optional (step 0 fetches it locally if missing; no sudo needed).
- The site you want to copy.

**Target server:**
- A **fresh Ubuntu 24.04** VPS (22.04 should work; same release as the source is best), root SSH access by
  password or key. 2 GB+ RAM recommended for `bench build` (4 GB+ for comfort).
- Outbound internet (apt, NodeSource, PyPI, npm).
- Ports 22 and 80 reachable (443 later for HTTPS).

## Quick start

On the **source** server, as the bench user (e.g. `frappe-user`):

```bash
git clone https://github.com/i-ninte/frappe-migrate.git ~/.claude/skills/frappe-migrate
cd ~/.claude/skills/frappe-migrate
cp config.env.example config.env && chmod 600 config.env
nano config.env          # fill in IPs, site names, passwords (see below)

./migrate.sh             # runs steps 0–5; logs go to ./logs/step<N>.log
```

Then open `http://<TARGET_HOST>` and log in with your usual ERP credentials.

Run individual steps (e.g. after fixing something):

```bash
./migrate.sh 3 4         # only steps 3 and 4
```

Steps 2 and 3 take the longest (rsync of `apps/`, `pip install`, `yarn`, `bench build`: about 10–20 minutes
in total on a 2-vCPU VPS). For long runs use `tmux` or `nohup ./migrate.sh > migrate.log 2>&1 &`.

## Configuration (`config.env`)

Copy `config.env.example` to `config.env`. **`config.env` is gitignored, so never commit it.**

| Variable | Meaning |
|---|---|
| `SRC_BENCH` | Path of the bench on the source, e.g. `/home/frappe-user/frappe-bench` |
| `SRC_SITE` | Site to copy, e.g. `newERP` |
| `TARGET_HOST` | IP or hostname of the new VPS |
| `TARGET_ROOT_PASS` | Root password of the new VPS. Used **once** in step 0 to install the SSH key; leave empty if your key already works |
| `TARGET_USER` | Bench user to create on the target (also your SSH user for day-to-day access) |
| `TARGET_USER_PASS` | Password set for that user (login + sudo) |
| `TARGET_BENCH` | Bench path on the target, e.g. `/home/frappe-user/frappe-bench` |
| `TARGET_SITE` | Site name on the target. Can differ from `SRC_SITE` |
| `TARGET_DB_ROOT_PASS` | MariaDB root password to set on the target |
| `NODE_MAJOR` / `YARN_VERSION` / `BENCH_CLI_VERSION` | Toolchain versions. Match the source (`node --version`, `yarn --version`, `bench --version`) |
| `SRC_HOST_LABEL`, `SRC_USER`, `SRC_USER_PASS`, `SRC_DB_ROOT_USER`, `SRC_DB_ROOT_PASS` | Source credentials, **only** used to fill the credentials spreadsheet |

Passwords may contain `#`, `!`, `+` etc.; keep them in single quotes. They're passed to the target over the
SSH session's stdin, never on a command line.

## The steps in detail

### Step 0: SSH key (source)
Creates `~/.ssh/id_ed25519` if needed and installs it for `root@TARGET_HOST` using `TARGET_ROOT_PASS`.
If `sshpass` isn't installed and you can't `apt install` (e.g. a broken apt state on the source), it downloads
the `.deb` and extracts it into a temp dir instead. Skipped if key login already works.

### Step 1: Provision the target (`scripts/01_provision_target.sh`, root)
- apt: build tools, Python dev/venv, MariaDB server/client + `libmariadb-dev`, Redis, nginx, supervisor, cron,
  fonts, `wkhtmltopdf`.
- Node `NODE_MAJOR` from NodeSource (system-wide, so supervisor and root find it; not nvm) and yarn.
- `frappe-bench==BENCH_CLI_VERSION` via pip.
- Creates `TARGET_USER` with the password, `sudo` group, and root's authorized SSH keys; `chmod o+x` on its home
  so nginx can serve assets.
- MariaDB: `utf8mb4` / `utf8mb4_unicode_ci`, 1 GB buffer pool, 256 MB packets; sets the root password and
  removes anonymous users and the test DB.
- Removes nginx's default site (it would otherwise catch requests by IP).
- Idempotent: safe to re-run.

### Step 2: Backup and sync (`scripts/02_backup_and_sync.sh`, source)
- Prints, per app: number of uncommitted changes and the git remote (or `NONE`).
- `bench --site SRC_SITE backup --with-files` (DB + public + private files + site config).
- Exact row counts for every table (one generated `UNION ALL` query), used to verify in step 3.
- `pip freeze` of the source venv, to reproduce it exactly.
- rsync `apps/` (minus `node_modules`, `__pycache__`), `Procfile`, `sites/apps.txt`, `apps.json`,
  `common_site_config.json`, the backup and the source `site_config.json` to the target.

### Step 3: Bench + site (`scripts/03_setup_bench_target.sh`, bench user)
- **New venv that mirrors the source exactly**: `pip install --no-deps -r constraints.txt`, then each app
  `pip install --no-deps -e`. (Resolving dependencies afresh tends to break: see Troubleshooting.)
- `bench setup requirements --node`, `bench setup redis`, `bench build`.
- Starts temporary Redis, runs `bench new-site TARGET_SITE` then `bench restore` with public and private files.
- Merges the source `site_config.json` into the new one (keeps the new DB name/password). This carries
  **`encryption_key`**, without which stored passwords (email accounts, integrations) can't be decrypted.
- `bench migrate`, `bench use TARGET_SITE`, maintenance off, **`scheduler enable`** + resume.
- Compares row counts with the source and prints any differences.

### Step 4: Production (`scripts/04_production_target.sh`, root)
- Generates fresh `bench setup supervisor` and `bench setup nginx` configs as the bench user, links them into
  `/etc/supervisor/conf.d` and `/etc/nginx/conf.d`, adds the `log_format main` that bench's nginx config expects,
  lets the bench user control supervisor, restarts everything and prints `supervisorctl status`.

### Step 5: Credentials spreadsheet (`scripts/05_credentials_xlsx.sh`, source)
See [below](#the-credentials-spreadsheet).

## Using it as a Claude Code skill

Clone into `~/.claude/skills/frappe-migrate` on the source server (as in Quick start). Claude Code picks up
`SKILL.md` automatically. Then just ask:

> Copy the newERP site to 203.0.113.10 as best.site. Root password is …, use frappe-user, MariaDB root password …

Claude fills `config.env`, checks toolchain versions against the source, runs the steps (backgrounding the
long ones), checks each result, fixes failures, and finishes by handing you the credentials spreadsheet.

## Verifying the migration

Step 3 prints row-count differences. A few are normal after `migrate`:
- DocTypes that exist in the app code but were never migrated on the source get created (`tabDocType`,
  `tabDocField` +N).
- `__global_search`, `tabComment`, `tabDeleted Document`, patch/error logs.

Anything else deserves a look. Then:

```bash
curl http://TARGET_HOST/api/method/ping                    # {"message":"pong"}
ssh root@TARGET_HOST supervisorctl status                  # all RUNNING
ssh TARGET_USER@TARGET_HOST 'cd frappe-bench && bench --site TARGET_SITE scheduler status'   # enabled
ssh TARGET_USER@TARGET_HOST "cd frappe-bench && bench --site TARGET_SITE execute frappe.utils.pdf.get_pdf --args '[\"<h1>t</h1>\"]'" | head -c 40   # PDF bytes
```

Log in through the browser, open a few documents, print one to PDF, and check that background jobs run.

## The credentials spreadsheet

Step 5 writes `~/migration_credentials_<TARGET_SITE>_<YYYYMMDD>.xlsx` on the source (mode `600`) and prints
the `scp` command to download it. It lists, for both servers:

| Row | Example |
|---|---|
| SSH root | `root` / … |
| SSH bench user (use this for remote access) | `frappe-user` / … |
| MariaDB root | `root` / … |
| MariaDB site DB user | `_4b17…` / generated by `bench new-site` |
| Site `encryption_key` | needed to restore backups elsewhere |
| ERP web login | `Administrator`: same as the source site (stored hashed, so it can't be listed) |
| SSH key used for the migration | `~/.ssh/id_ed25519` on the source |

**Download it, then delete it from the server.**

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `bench new-site` → `ImportError: Module import failed for Dropbox Settings` / `No module named 'pkg_resources'` | setuptools ≥ 81 removed `pkg_resources`. Step 3 reproduces the source's setuptools; don't `pip install -U setuptools` |
| `ResolutionImpossible` during pip install | The source venv's dependencies don't match its own app code (code updated without reinstalling deps) or contain unresolvable pins. That's why step 3 uses `--no-deps` with the frozen list |
| `nginx: unknown log format "main"` | Stock nginx lacks it; step 4 writes `/etc/nginx/conf.d/00-log-format.conf` |
| Site works but scheduled jobs never run | Restore leaves the scheduler disabled: `bench --site X scheduler enable` (step 3 does this) |
| Step 3 failed half way, re-run complains the site exists | `bench drop-site X --force --no-backup --db-root-username root --db-root-password '…'`, then `./migrate.sh 3` |
| Browsing to the IP shows "Welcome to nginx" | `/etc/nginx/sites-enabled/default` still exists. Remove it and `systemctl reload nginx` |
| Stored email/integration passwords fail to decrypt | `encryption_key` in the target `site_config.json` differs from the source. Copy it over |
| `ssh-copy-id` asks for a password interactively | `TARGET_ROOT_PASS` is wrong or empty, or the VPS has root password login disabled. Add your key through the provider console |
| `bench build` killed / out of memory | Use a VPS with more RAM, or add swap: `fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile` |

Each step logs to `logs/step<N>.log`.

## After the migration

- **Domain + HTTPS:** point DNS to the VPS, then
  `bench setup add-domain --site TARGET_SITE erp.example.com` and `sudo bench setup lets-encrypt TARGET_SITE`.
- **Developer mode:** if the source had it on, it's copied. For production:
  `bench --site TARGET_SITE set-config developer_mode 0`.
- **Hardening:** `PermitRootLogin prohibit-password` in `/etc/ssh/sshd_config`,
  `ufw allow OpenSSH && ufw allow 'Nginx Full' && ufw enable`.
- **Backups:** set up off-site backups on the new server (Frappe's S3 backup settings, or cron + rsync).
- **Cut-over:** if the new server replaces the old one, put the source in maintenance mode before step 2
  (`bench --site SRC_SITE set-maintenance-mode on`) so no data is written after the backup.

## Security notes

- `config.env` and `*.xlsx` are gitignored. Keep `config.env` at mode `600`.
- The root password is used only once, in step 0. Afterwards access is by SSH key.
- Passwords are sent to the target inside the SSH session (stdin), not on command lines visible in `ps`.
- Change any password that has been pasted into chats, tickets or shell history.
- The scripts don't change SSH or firewall settings on the target. That's left to you (see above).

## Repository layout

```
frappe-migrate/
├── README.md                     this file
├── SKILL.md                      instructions for Claude Code
├── migrate.sh                    runs steps 0–5 (or the ones you pass)
├── config.env.example            template → copy to config.env (gitignored)
├── .gitignore
└── scripts/
    ├── 01_provision_target.sh    target, root: packages, MariaDB, Node, bench, user
    ├── 02_backup_and_sync.sh     source: report, backup, counts, freeze, rsync
    ├── 03_setup_bench_target.sh  target, bench user: venv, build, restore, migrate, verify
    ├── 04_production_target.sh   target, root: supervisor + nginx
    └── 05_credentials_xlsx.sh    source: credentials spreadsheet
```
