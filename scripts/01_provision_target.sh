# Runs ON THE TARGET as root. Fed via: { cat config.env; cat this; } | ssh root@host bash -s
# Installs system deps, MariaDB, Redis, Node, yarn, bench CLI, nginx, supervisor, wkhtmltopdf
# and creates TARGET_USER with sudo + SSH key access.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "== apt packages"
apt-get update -qq
apt-get install -y -qq git curl ca-certificates gnupg build-essential pkg-config \
  python3-dev python3-venv python3-pip python3-setuptools libffi-dev libssl-dev \
  mariadb-server mariadb-client libmariadb-dev redis-server \
  nginx supervisor cron xvfb fontconfig libfontconfig1 xfonts-75dpi xfonts-base \
  wkhtmltopdf >/dev/null

echo "== node ${NODE_MAJOR} + yarn ${YARN_VERSION}"
if ! node --version 2>/dev/null | grep -q "^v${NODE_MAJOR}\."; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
npm install -g "yarn@${YARN_VERSION}" >/dev/null 2>&1
node --version; yarn --version

echo "== bench CLI ${BENCH_CLI_VERSION}"
pip3 install -q --break-system-packages "frappe-bench==${BENCH_CLI_VERSION}"
bench --version

echo "== user ${TARGET_USER}"
id "$TARGET_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$TARGET_USER"
echo "${TARGET_USER}:${TARGET_USER_PASS}" | chpasswd
usermod -aG sudo "$TARGET_USER"
chmod o+x "/home/${TARGET_USER}"          # nginx must traverse to sites/assets
install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "/home/${TARGET_USER}/.ssh"
cat /root/.ssh/authorized_keys >> "/home/${TARGET_USER}/.ssh/authorized_keys"
sort -u -o "/home/${TARGET_USER}/.ssh/authorized_keys" "/home/${TARGET_USER}/.ssh/authorized_keys"
chown "$TARGET_USER:$TARGET_USER" "/home/${TARGET_USER}/.ssh/authorized_keys"
chmod 600 "/home/${TARGET_USER}/.ssh/authorized_keys"

echo "== mariadb"
cat > /etc/mysql/mariadb.conf.d/99-frappe.cnf <<'CNF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_file_per_table = 1
innodb_buffer_pool_size = 1G
max_allowed_packet = 256M

[mysql]
default-character-set = utf8mb4
CNF
systemctl restart mariadb
# set root password (works whether root currently uses unix_socket or a password)
if mysql -uroot -e "select 1" >/dev/null 2>&1; then
  mysql -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${TARGET_DB_ROOT_PASS}');
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
fi
mysql -uroot -p"${TARGET_DB_ROOT_PASS}" -e "select version();"

echo "== services"
systemctl enable --now nginx supervisor cron >/dev/null
rm -f /etc/nginx/sites-enabled/default    # otherwise it catches requests by IP
echo "PROVISION OK"
