# Runs ON THE TARGET as root. Fed via: { cat config.env; cat this; } | ssh root@host bash -s
# Generates fresh supervisor + nginx configs as the bench user (old ones hold stale paths),
# links them in and starts everything.
set -euo pipefail
cd "$TARGET_BENCH"
as_user() { sudo -u "$TARGET_USER" -H bash -lc "cd $TARGET_BENCH && $*"; }

echo "== generate configs"
as_user "bench setup supervisor --yes"
as_user "bench setup nginx --yes"
bench setup sudoers "$TARGET_USER" >/dev/null 2>&1 || true

ln -sf "$TARGET_BENCH/config/supervisor.conf" /etc/supervisor/conf.d/frappe-bench.conf
ln -sf "$TARGET_BENCH/config/nginx.conf"      /etc/nginx/conf.d/frappe-bench.conf
rm -f /etc/nginx/sites-enabled/default
# bench's nginx.conf uses `access_log ... main`; stock Ubuntu nginx doesn't define it (`bench setup production` would)
cat > /etc/nginx/conf.d/00-log-format.conf <<'NGX'
log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                '$status $body_bytes_sent "$http_referer" '
                '"$http_user_agent" "$http_x_forwarded_for"';
NGX

# let the bench user control supervisor without root
if ! grep -q "chown=${TARGET_USER}" /etc/supervisor/supervisord.conf; then
  sed -i "s|^chmod=0700.*|chmod=0760\nchown=${TARGET_USER}:${TARGET_USER}|" /etc/supervisor/supervisord.conf
fi

nginx -t
systemctl restart supervisor
systemctl reload nginx
sleep 8
supervisorctl status
echo "PRODUCTION OK"
