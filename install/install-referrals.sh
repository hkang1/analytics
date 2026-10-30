#!/usr/bin/env bash
# Install the referral-URL reporter. Run as root on the droplet.
#
#   sudo bash /tmp/install-referrals.sh          # install + one test run
#   sudo bash /tmp/install-referrals.sh --no-run # install only
#
# Idempotent. Does not touch the existing swanpan-traffic job or its state.
set -euo pipefail

# Find the payload. Tried in order, first one that actually CONTAINS the files
# wins. Testing for the directory is not enough: run from /tmp and
# "$HERE/../bin" resolves to /bin, which exists, so a [[ -d ]] check silently
# picks an empty dir.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ $HERE == */install ]]; then
  SRC=$(cd "$HERE/.." && pwd)
else
  SRC=$HERE
fi
for cand in "$SRC" "$SRC/bin" /tmp/referral-tools; do
  if [[ -s $cand/swanpan-referrals && -s $cand/swanpan-referrals-render \
        && -s $cand/swanpan-index ]]; then
    SRC=$cand
    break
  fi
done
BIN=/usr/local/bin
OUT=/var/www/traffic
STATE=/var/lib/swanpan-traffic-referrals

SPAM_DST=/etc/swanpan-referral-spam.txt

for f in swanpan-referrals swanpan-referrals-render swanpan-index; do
  if [[ ! -s $SRC/$f ]]; then
    echo "ERROR: $SRC/$f missing -- copy the files up first" >&2
    exit 1
  fi
done

install -m 0755 -o root -g root "$SRC/swanpan-referrals"        "$BIN/swanpan-referrals"
install -m 0755 -o root -g root "$SRC/swanpan-referrals-render" "$BIN/swanpan-referrals-render"
install -m 0755 -o root -g root "$SRC/swanpan-index"            "$BIN/swanpan-index"
echo "installed:"
ls -la "$BIN/swanpan-referrals" "$BIN/swanpan-referrals-render" "$BIN/swanpan-index"

# Rewrite the landing page now, so it links the new reports immediately rather
# than waiting for a timer tick. Also replaces the old hand-written index,
# which had stale hardcoded sizes and dates.
if /usr/local/bin/swanpan-index "$OUT"; then
  chown www-data:www-data "$OUT/index.html"
fi

# Blocklist. Only installed if absent, so local edits survive a re-install.
SPAM_SRC=""
for cand in "$SRC/etc/referral-spam.txt" "$SRC/../etc/referral-spam.txt" \
            "$SRC/referral-spam.txt" /tmp/referral-tools/referral-spam.txt; do
  [[ -s $cand ]] && { SPAM_SRC=$cand; break; }
done
if [[ -n $SPAM_SRC ]]; then
  if [[ -f $SPAM_DST ]]; then
    echo "kept existing $SPAM_DST (not overwritten)"
  else
    install -m 0644 -o root -g root "$SPAM_SRC" "$SPAM_DST"
    echo "installed $SPAM_DST (from $SPAM_SRC)"
  fi
else
  echo "WARNING: no referral-spam.txt found -- spam filtering will be off" >&2
fi

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

# Once a day, at 04:17 UTC -- deliberately NOT on the hour, and deliberately
# well away from log rotation.
#
# nginx logs rotate DAILY at ~23:55 (see /etc/logrotate.d/nginx, 'daily' +
# postrotate 'nginx rotate'). Whatever remains in *.log at that moment is
# renamed to *.log.1 and starts over. This job is fed ONLY the live *.log, so
# a run must happen INSIDE each rotation window or the day's tail is skipped.
#
# 23:55 -> 04:17 leaves a ~20h window, so a run always sees everything logged
# since the last rotation plus ~4h of the previous day's tail: no gap, and the
# overlap is harmless because --persist de-duplicates by the visit key.
#
# Refusing 'OnCalendar=*-*-* 00:00' here: midnight UT is within minutes of
# rotation, so any clock skew or a slow logrotate would silently skip a day.
cat > /etc/systemd/system/swanpan-referrals.timer <<'EOF'
[Unit]
Description=Rebuild referral-URL reports daily at 04:17 UTC

[Timer]
OnCalendar=*-*-* 04:17:00 UTC
# Fire late-but-not-lost if the box was down at 04:17.
Persistent=true
RandomizedDelaySec=120
AccuracySec=60s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
# Re-load the new timer definition and restart it, so an earlier install's
# 'every 30 minutes' schedule is replaced rather than both running.
systemctl enable swanpan-referrals.timer
systemctl restart swanpan-referrals.timer
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
