#!/usr/bin/env bash
# Runs ON THE SOURCE as the bench user. Backs up SRC_SITE and rsyncs the bench code as-is
# (preserving uncommitted changes and remote-less apps) to the target.
set -euo pipefail
source "$(dirname "$0")/../config.env"
T="${TARGET_USER}@${TARGET_HOST}"
cd "$SRC_BENCH"

echo "== pre-flight: uncommitted changes / apps without remote (these are why we rsync, not git clone)"
for a in $(cat sites/apps.txt); do
  printf '  %-16s dirty=%-5s remote=%s\n' "$a" \
    "$(git -C apps/$a status --porcelain 2>/dev/null | wc -l)" \
    "$(git -C apps/$a remote get-url upstream 2>/dev/null || git -C apps/$a remote get-url origin 2>/dev/null || echo NONE)"
done

echo "== backup ${SRC_SITE}"
bench --site "$SRC_SITE" backup --with-files | tail -8
BK="sites/${SRC_SITE}/private/backups"
DB=$(ls -t $BK/*-database.sql.gz | head -1)
PREFIX="${DB%-database.sql.gz}"
FILES=("$DB" "${PREFIX}-files.tar" "${PREFIX}-private-files.tar" "${PREFIX}-site_config_backup.json")
ls -la "${FILES[@]}"

echo "== table row counts on source (for verification)"
# one generated UNION query instead of one bench call per table
bench --site "$SRC_SITE" mariadb -N -e "select concat('select \"',table_name,'\", count(*) from \`',table_name,'\` union all') from information_schema.tables where table_schema=database() and table_type='BASE TABLE'" \
  | sed '$ s/ union all$//' | bench --site "$SRC_SITE" mariadb -N | sort > /tmp/src_counts.tsv

echo "== rsync bench code -> ${T}:${TARGET_BENCH}"
ssh "$T" "mkdir -p ${TARGET_BENCH}/sites ${TARGET_BENCH}/config/pids ${TARGET_BENCH}/logs ~/migrate"
rsync -az --delete \
  --exclude 'node_modules/' --exclude '__pycache__/' --exclude '*.pyc' \
  apps/ "${T}:${TARGET_BENCH}/apps/"
rsync -az Procfile "${T}:${TARGET_BENCH}/"
rsync -az sites/apps.txt sites/common_site_config.json "${T}:${TARGET_BENCH}/sites/"
[ -f sites/apps.json ] && rsync -az sites/apps.json "${T}:${TARGET_BENCH}/sites/"
rsync -az "${FILES[@]}" "${T}:migrate/"
rsync -az "sites/${SRC_SITE}/site_config.json" "${T}:migrate/source_site_config.json"
# exact python package versions from source (latest setuptools drops pkg_resources and breaks new-site)
env/bin/pip freeze --exclude-editable --all | grep -v -E '^(pip|wheel)==' > /tmp/constraints.txt
rsync -az /tmp/constraints.txt "${T}:migrate/constraints.txt"
ssh "$T" "chmod 600 ~/migrate/*"

rsync -az /tmp/src_counts.tsv "${T}:migrate/src_counts.tsv"
echo "SYNC OK ($(wc -l < /tmp/src_counts.tsv) tables counted)"
