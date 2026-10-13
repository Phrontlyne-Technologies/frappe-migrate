#!/usr/bin/env bash
# Orchestrates a full Frappe/ERPNext site migration to a fresh Ubuntu VPS.
# Run on the SOURCE server as the bench user.
#   ./migrate.sh            # all steps 0-5
#   ./migrate.sh 3 4        # only the given steps (e.g. re-run after fixing something)
set -euo pipefail
cd "$(dirname "$0")"
[ -f config.env ] || { echo "config.env missing: cp config.env.example config.env && chmod 600 config.env, then edit it"; exit 1; }
chmod 600 config.env
set -a; source config.env; set +a
mkdir -p logs
STEPS=("${@:-0 1 2 3 4 5}"); STEPS=(${STEPS[*]})
on_target() { { cat config.env; cat "$2"; } | ssh -o BatchMode=yes "$1@${TARGET_HOST}" bash -s; }

step0() {  # install this server's SSH key on target root (password used only here)
  [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${TARGET_HOST}" true 2>/dev/null; then
    echo "key already authorised for root@${TARGET_HOST}"; return; fi
  SP=$(command -v sshpass || true)
  if [ -z "$SP" ]; then   # no sshpass and maybe no sudo/apt: extract the .deb locally
    D=$(mktemp -d); (cd "$D" && apt-get download sshpass >/dev/null && dpkg-deb -x sshpass_*.deb r); SP="$D/r/usr/bin/sshpass"
  fi
  SSHPASS="$TARGET_ROOT_PASS" "$SP" -e ssh-copy-id -o StrictHostKeyChecking=accept-new "root@${TARGET_HOST}"
}
step1() { on_target root scripts/01_provision_target.sh; }
step2() { bash scripts/02_backup_and_sync.sh; }
step3() { on_target "$TARGET_USER" scripts/03_setup_bench_target.sh; }
step4() { on_target root scripts/04_production_target.sh; }
step5() { bash scripts/05_credentials_xlsx.sh; }

for s in "${STEPS[@]}"; do
  echo "================ step $s ================"
  "step$s" 2>&1 | tee "logs/step$s.log"
done
echo "Done. Open http://${TARGET_HOST}  (logs in ./logs)"
