# analytics

Traffic reporting for **swanpan.io** and **hoyoul.com**, from nginx access logs,
rendered as static HTML by [GoAccess](https://goaccess.io) and served behind
basic auth at <https://analytics.limeyeti.com/>.

It exists on its own domain and its own vhost on purpose: a mistake here cannot
break checkout or sign-in on the product sites. Nothing in this repo touches the
application code.

## Why GoAccess

The droplet is 1 vCPU / 2 GB. Plausible, Matomo and Umami all want roughly a
gigabyte before they draw a chart. GoAccess is a single binary that reads log
files, writes HTML and exits — no idle cost, no JS tag, no cookies, no consent
banner. That last point matters: there are children aged 6+ on the platform, so
the less we observe about visitors, the better.

Reports are generated on a timer into static files. `--real-time-html` is
deliberately not used: it holds a websocket server open, which on this box means
a long-lived process sitting on rotated log files.

Cloudflare already offers free traffic analytics — this exists for the history
GoAccess keeps and for country data pulled from nginx's own logs.

## What runs where

| Path | What |
|---|---|
| `/usr/local/bin/swanpan-traffic` | report job (from `bin/`) |
| `/etc/systemd/system/swanpan-traffic.{service,timer}` | oneshot, every 10 min |
| `/etc/nginx/sites-available/analytics.limeyeti.com` | vhost |
| `/etc/nginx/conf.d/{cloudflare-realip,swanpan-logformat,swanpan-cfcountry}.conf` | real IP + log format |
| `/var/www/traffic/` | generated reports (`www-data`, `750`) |
| `/var/lib/swanpan-traffic/<site>/` | GoAccess persistence, one dir per site |
| `/etc/nginx/.htpasswd-limeyeti` | basic auth, `640 root:www-data` |

The reports live **outside** the product web roots so a deploy can't wipe them
or sync them back into git.

## Install

```sh
sudo bash install/install.sh
```

Idempotent; safe to re-run. It copies files, creates directories, reloads nginx
and can issue the certificate if one is missing.

## Traps worth knowing

Every one of these cost real time. They are not hypothetical.

1. **Cloudflare's `ips-v4` / `ips-v6` have no trailing newline.** Concatenating
   them into a `set_real_ip_from` block produces
   `...2c0f:f248::/32real_ip_header CF-Connecting-IP;` and nginx reports
   `invalid number of arguments in "set_real_ip_from" directive`. Always
   `printf '\n'` between the chunks.

2. **The nginx error line number is where it gave up, not where the fault is.**
   It pointed at line 24 for a file whose real problem was line 3.

3. **`--db-path` is a DIRECTORY.** `goaccess.conf`: "Path where the persisted
   database files are stored on disk". Passing a file gives
   `set_db_path:73 Database path is not a directory`.

4. **GoAccess state files are not namespaced per site.** It writes ~150 files
   with generic names (`II32_REQUESTS_MTRC_HITS.db`, `SI32_DB_PROPS.db`, …).
   Two sites sharing one `--db-path` means the second run overwrites the first's
   history, and `--restore` compounds the damage. One subdirectory per site.

5. **Never `2>/dev/null` a job whose purpose is producing output.** An early
   version ended with `|| echo "render failed"` and exited 0 with an empty
   directory. A green timer that writes nothing is worse than a red one.

6. **`alias` is not `root`.** With `alias`, a location matched by prefix gets
   that prefix *substituted*, so `location = /` with
   `alias /var/www/traffic/index.html` resolves the request `/` to
   `/var/www/traffic/index.htmlindex.html` — a 500. `root` appends the URI
   instead, which is what a directory listing wants.

7. **A config with two `server` blocks cannot be safely regex-edited.** A
   "replace the first `location /`" pass hit the port-80 block instead of the
   :443 one, which would have served reports over plain HTTP with the auth
   directive only in the HTTPS block. `nginx -t` caught it (duplicate location)
   and `set -e` stopped the reload, so nothing went live. Write the whole file.

8. **Verify from outside the box.** Testing `174.138.42.13` from the droplet
   itself goes over loopback, which the firewall permits by design — it returns
   200 whether or not the firewall works. The same goes for `real_ip`: a
   `127.0.0.1` request proves nothing, you must load the site through Cloudflare.

## Referrer filtering

Two flags that are easy to mix up:

- `--hide-referrer=<needle>` hides the source from the REFERRING SITES panel but
  **still counts the visit**. Use for self-referrals: the visit is real, it just
  isn't an acquisition.
- `--ignore-referrer=<needle>` drops the hit entirely. Use for spam referrers
  that inflate totals.

Currently hidden: `swanpan.io` for its own report; `hoyoul.com` and
`calebkang.com` for theirs. `174.138.42.13` is excluded as a client IP because
it is the droplet itself.

## Origin lock

`hoyoul.com` ran for a long time with DNS-only records — all four hostnames
resolved straight to the droplet, so there was no WAF, no bot rules and no rate
limiting in front of it. One Google Cloud address was responsible for 190 of the
last 200 requests, probing `/dashboard`, `/settings` and `/api/auth` (all 405).

Proxying the records helps only clients that resolve through DNS. Anything
holding the origin IP goes straight past Cloudflare. The fix is a packet filter:
allow 80/443 only from Cloudflare's published ranges, keep SSH open so the box
can't be locked out, and arm a rollback timer in case the rule set is wrong.

That script lives in the swanpan repo rather than here — it covers the product
sites too.

## Reading the reports

Two caveats, both temporary:

- **Country panels** are only meaningful once a day or two of post-`real_ip`
  traffic has accumulated. Older lines have no `CF-IPCountry` header.
- **Before proxying**, `hoyoul.html` was mostly one bot. Ignore historical
  spikes there; they are not visitors.
