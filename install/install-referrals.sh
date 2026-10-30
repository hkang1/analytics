#!/usr/bin/env bash
# Install the referral-URL reporter. Run as root on the droplet.
#
#   sudo bash /tmp/install-referrals.sh          # install + one test run
#   sudo bash /tmp/install-referrals.sh --no-run # install only
#
# Idempotent. Does not touch the existing swanpan-traffic job or its state.
set -euo pipefail

# Defaults to the sibling bin/ when run from the repo; falls back to the staged
# copy when run as a standalone upload on the droplet.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SRC:-$HERE/../bin}
[[ -d $SRC ]] || SRC=/tmp/referral-tools
BIN=/usr/local/bin
OUT=/var/www/traffic
STATE=/var/lib/swanpan-traffic-referrals

for f in swanpan-referrals swanpan-referrals-render; do
  if [[ ! -s $SRC/$f ]]; then
    echo "ERROR: $SRC/$f missing -- copy the files up first" >&2
    exit 1
  fi
done

install -m 0755 -o root -g root "$SRC/swanpan-referrals"        "$BIN/swanpan-referrals"
install -m 0755 -o root -g root "$SRC/swanpan-referrals-render" "$BIN/swanpan-referrals-render"
echo "installed:"
ls -la "$BIN/swanpan-referrals" "$BIN/swanpan-referrals-render"

install -d -m 0750 -o root -g root "$STATE"
# Per-site db dirs. goaccess does not create these and fails hard without them
# (persistence.c set_db_path - 67). The runtime script also creates them, so a
# deleted dir self-heals; doing it here means the first run cannot fail.
for site in swanpan hoyoul; do
  install -d -m 0750 -o root -g root "$STATE/$site/db"
done

# Separate oneshot unit. Deliberately NOT bolted onto swanpan-traffic.service:
# if this job breaks, the main reports keep generating, and vice versa.
cat > /etc/systemd/system/swanpan-referrals.service <<'EOF'
[Unit]
Description=Regenerate referral-URL reports (full URLs, not just hosts)
After=nginx.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/swanpan-referrals
EOF

cat > /etc/systemd/system/swanpan-referrals.timer <<'EOF'
[Unit]
Description=Rebuild referral-URL reports every 30 minutes

[Timer]
OnBootSec=6min
OnUnitActiveSec=30min
AccuracySec=60s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now swanpan-referrals.timer
echo
echo "timer:"
systemctl list-timers swanpan-referrals.timer --no-pager

if [[ "${1:-}" != "--no-run" ]]; then
  echo
  echo "=== test run ==="
  /usr/local/bin/swanpan-referrals
  echo
  echo "=== output ==="
  ls -la "$OUT"/referrals-*.html
fi

echo
echo "=== served check (expect 401 anon) ==="
curl -s -o /dev/null -w "  /referrals-swanpan.html -> %{http_code}\n" \
  https://analytics.limeyeti.com/referrals-swanpan.html
curl -s -o /dev/null -w "  /referrals-hoyoul.html  -> %{http_code}\n" \
  https://analytics.limeyeti.com/referrals-hoyoul.html
