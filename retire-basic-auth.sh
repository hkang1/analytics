#!/usr/bin/env bash
# Retire origin basic auth on analytics.limeyeti.com.
#
# Run ON THE ANALYTICS DROPLET as root, from a checkout of this repo.
# Cloudflare Access must already be proven working -- it is the only gate left
# once this removes the password prompt.
set -euo pipefail

DOMAIN=analytics.limeyeti.com
HTPASSWD=/etc/nginx/.htpasswd-limeyeti
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }

say() { printf '\n== %s\n' "$*"; }

say "1. Backup the current vhost"
cp "/etc/nginx/sites-available/$DOMAIN" "/root/$DOMAIN.$(date +%Y%m%d-%H%M%S).bak"
echo "   saved under /root"

say "2. Install the vhost without auth_basic"
install -m 644 "$REPO/nginx/$DOMAIN" "/etc/nginx/sites-available/$DOMAIN"

say "3. Test before reloading"
if ! nginx -t; then
  echo "   nginx -t FAILED -- restoring the backup, nothing changed" >&2
  cp "$(ls -t /root/$DOMAIN.*.bak | head -1)" "/etc/nginx/sites-available/$DOMAIN"
  exit 1
fi

say "4. Reload"
systemctl reload nginx

say "5. Delete the password file"
if [[ -f $HTPASSWD ]]; then
  rm -f "$HTPASSWD"
  echo "   removed $HTPASSWD"
else
  echo "   already gone"
fi

say "6. Prove the site still answers"
# Ask Cloudflare for the hostname. A 302 to the access login is the pass:
# it means the edge is still gating and nginx is still serving.
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" || echo 000)
echo "   origin-direct status: $CODE (403/404/200 are all fine; 502/000 is not)"
if [[ "$CODE" == "502" || "$CODE" == "000" ]]; then
  echo "   the origin is not answering -- ROLLING BACK" >&2
  # Restore the vhost AND the password file. The file is only deleted in the
  # next section, so at this point it still exists; restoring the config is
  # enough to put the old gate back exactly as it was.
  cp "$(ls -t /root/$DOMAIN.*.bak | head -1)" "/etc/nginx/sites-available/$DOMAIN"
  systemctl reload nginx
  echo "   restored the previous vhost; basic auth is back" >&2
  exit 1
fi

echo
echo "Now check from your own machine, which is the real test:"
echo "    curl -sI https://$DOMAIN/ | head -3"
echo "Expect a 302 to cloudflareaccess.com. A 401 with Basic means the edge"
echo "stopped applying -- put the app back in Cloudflare before trusting this."
