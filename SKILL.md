---
name: frappe-migrate
description: Clone a Frappe/ERPNext bench site from this server onto a fresh Ubuntu VPS (native install, not Docker) — provisions MariaDB/Redis/Node/bench/nginx/supervisor, creates the bench user, copies app code as-is (keeping uncommitted changes), restores the site under a new name, migrates, puts it into production and produces a credentials spreadsheet. Use when the user asks to copy/move/migrate/replicate the ERP to another server.
---

# Frappe bench → new VPS migration

See README.md for the full guide. Short version for running it:

1. `cp config.env.example config.env && chmod 600 config.env` if missing, then fill it from what the user gives you
   (target IP + root password, bench user + password, target site name, MariaDB root password, source site,
   source credentials for the spreadsheet). Check toolchain versions match the source:
   `bench --version`, `node --version`, `yarn --version`.
2. Run the pre-flight from step 2 mentally first: `git status --porcelain | wc -l` per app and apps without a remote.
   Tell the user if code exists only on this server — that is why the bench is rsynced, not re-cloned.
3. `./migrate.sh` (all steps) or `./migrate.sh <n> ...` for specific steps. Steps 2 and 3 can exceed a 10-minute
   tool timeout: run in the background, logs are in `logs/step<n>.log`.
4. **Step 5 is mandatory**: give the user the printed `scp` command for the credentials `.xlsx` and remind them
   to delete it from the server after downloading.

| Step | Where | What |
|---|---|---|
| 0 | source | SSH key → target root (only use of the root password) |
| 1 | target, root | apt deps, MariaDB (utf8mb4, root pw), Node, yarn, bench CLI, bench user with sudo + key, nginx, supervisor, wkhtmltopdf |
| 2 | source | per-app dirty/remote report, `backup --with-files`, row counts, `pip freeze`, rsync apps + backup |
| 3 | target, bench user | fresh venv = exact source packages, yarn, build, new-site, restore, site_config merge (encryption_key), migrate, scheduler enable, row-count diff |
| 4 | target, root | fresh supervisor + nginx configs, start all |
| 5 | source | `~/migration_credentials_<site>_<date>.xlsx` (chmod 600) |

## Rules
- Never `bench get-app` the apps — rsync them (uncommitted edits / remote-less apps would be lost).
- Never copy `env/`, `node_modules/`, `sites/assets`, or supervisor/nginx/redis configs — they are regenerated.
- The source `encryption_key` must end up in the target site_config (step 3 does it).
- Don't change SSH/firewall settings on the target unless the user asks.

## Gotchas (handled in the scripts — keep them handled)
- Latest setuptools has no `pkg_resources` → `new-site` fails importing Dropbox Settings. Venv is an exact
  `pip install --no-deps -r` replica of the source; constraint mode fails because source envs often have
  deps that lag the app code or contain unresolvable pins.
- Stock Ubuntu nginx lacks `log_format main` → step 4 writes `conf.d/00-log-format.conf`.
- Restore leaves the scheduler disabled → step 3 runs `scheduler enable`.
- Failed `new-site` leaves a half site → `bench drop-site <site> --force --no-backup --db-root-password ...`, then re-run step 3.
- `pkill -f <name>` from a shell whose own command line contains `<name>` kills that shell.
- Expected row-count diffs: a handful (DocTypes in code but never migrated on the source, `__global_search`,
  `tabComment`, `tabDeleted Document`). Investigate anything else.

## Verify
`curl http://$TARGET_HOST/api/method/ping` → pong · login page + an `/assets/...css` → 200 ·
`supervisorctl status` all RUNNING · `bench --site X scheduler status` enabled · PDF:
`bench --site X execute frappe.utils.pdf.get_pdf --args '["<h1>t</h1>"]'`.

## Follow-ups to offer
Domain + Let's Encrypt (`bench setup add-domain`, `sudo bench setup lets-encrypt <site>`), `developer_mode 0`,
SSH root key-only + ufw, rotating any passwords shared in chat.
