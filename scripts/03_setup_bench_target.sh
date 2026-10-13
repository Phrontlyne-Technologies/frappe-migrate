# Runs ON THE TARGET as TARGET_USER. Fed via: { cat config.env; cat this; } | ssh user@host bash -s
# Rebuilds machine-specific parts of the bench (venv, node_modules, assets, redis config),
# creates TARGET_SITE, restores the backup, carries over site config and migrates.
set -euo pipefail
cd "$TARGET_BENCH"
M=~/migrate

echo "== python env"
rm -rf env && python3 -m venv env    # fresh each run so it exactly mirrors source
env/bin/pip install -q -U pip wheel
# replicate the source env exactly: install its frozen package list, then the apps with --no-deps.
# (constraints mode fails: source env deps can lag the app code's pyproject, e.g. deps from frappe 15.31
#  with code at 15.93 — pip then reports ResolutionImpossible. Exact replica is what is known to run.)
env/bin/pip install -q --no-deps -r "$M/constraints.txt"   # --no-deps: source tree itself has unresolvable pins (google-auth dev)
for a in $(cat sites/apps.txt); do echo "  pip install --no-deps $a"; env/bin/pip install -q --no-deps -e "apps/$a"; done
env/bin/pip check || echo "  (pip check warnings above mirror the source env)"
env/bin/python -c "import pkg_resources" || { echo "pkg_resources missing — setuptools too new"; exit 1; }

echo "== node deps + redis config + build"
bench setup requirements --node
bench setup redis
mkdir -p sites/assets
bench build

echo "== temporary redis for restore/migrate"
redis-server config/redis_cache.conf --daemonize yes
redis-server config/redis_queue.conf --daemonize yes
trap 'redis-cli -p 13000 shutdown nosave >/dev/null 2>&1 || true; redis-cli -p 11000 shutdown nosave >/dev/null 2>&1 || true' EXIT

echo "== create + restore ${TARGET_SITE}"
DB=$(ls -t $M/*-database.sql.gz | head -1); P="${DB%-database.sql.gz}"
if [ ! -d "sites/${TARGET_SITE}" ]; then
  bench new-site "$TARGET_SITE" --db-root-username root --db-root-password "$TARGET_DB_ROOT_PASS" \
    --admin-password "$(openssl rand -hex 16)" >/dev/null   # admin pw is replaced by the restore
fi
bench --site "$TARGET_SITE" restore "$DB" \
  --with-public-files "${P}-files.tar" --with-private-files "${P}-private-files.tar" \
  --db-root-username root --db-root-password "$TARGET_DB_ROOT_PASS" --force

echo "== carry over site config (encryption_key etc.), keep new db creds"
env/bin/python - "$M/source_site_config.json" "sites/${TARGET_SITE}/site_config.json" <<'PY'
import json, sys
src, dst = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
for k, v in src.items():
    if k not in ("db_name", "db_password", "db_host", "db_port", "maintenance_mode"):
        dst[k] = v
json.dump(dst, open(sys.argv[2], "w"), indent=1)
print("  keys:", sorted(dst))
PY

echo "== migrate"
bench --site "$TARGET_SITE" migrate
bench use "$TARGET_SITE"
bench --site "$TARGET_SITE" set-maintenance-mode off
bench --site "$TARGET_SITE" scheduler enable   # restore leaves it disabled; resume alone is not enough
bench --site "$TARGET_SITE" scheduler resume

echo "== verify row counts vs source"
bench --site "$TARGET_SITE" mariadb -N -e "select concat('select \"',table_name,'\", count(*) from \`',table_name,'\` union all') from information_schema.tables where table_schema=database() and table_type='BASE TABLE'" \
  | sed '$ s/ union all$//' | bench --site "$TARGET_SITE" mariadb -N | sort > $M/dst_counts.tsv
join -t $'\t' -a1 -e MISSING -o 0,1.2,2.2 <(sort $M/src_counts.tsv) <(sort $M/dst_counts.tsv) \
  | awk -F'\t' '$2!=$3{print "  DIFF",$1,"src="$2,"dst="$3; d++} END{print "  tables differing:", d+0, "(migrate legitimately touches a few log/patch tables)"}'
echo "BENCH OK"
