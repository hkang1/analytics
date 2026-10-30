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
| `/usr/local/bin/swanpan-referrals` | referral-URL report job (from `bin/`) |
| `/usr/local/bin/swanpan-referrals-render` | its JSON → HTML renderer |
| `/etc/systemd/system/swanpan-referrals.{service,timer}` | oneshot, every 30 min |
| `/var/lib/swanpan-traffic-referrals/` | **separate** persistence for the above |
| `/etc/nginx/sites-available/analytics.limeyeti.com` | vhost |
| `/etc/nginx/conf.d/{cloudflare-realip,swanpan-logformat,swanpan-cfcountry}.conf` | real IP + log format |
| `/var/www/traffic/` | generated reports (`www-data`, `750`) — incl. `referrals-<site>.html` |
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

9. **`--hide-referrer` matches the panel value exactly, not a substring.** See
   the Referrer filtering section. A needle that looks obviously right
   (`174.138.42.13`) can hide a 1-hit row and leave a 273-hit row standing,
   because the panel stored the second one with a port.

10. **Use `-o out.json` to inspect reports, not the HTML.** GoAccess's HTML is
    a JavaScript payload: panel metadata and row data live in separate
    structures, `"referring_sites": {…}` describes the columns while the rows
    sit in a later `"data": […]` array, and grepping for a hostname finds
    matches in whichever panel happens to be nearby. Three separate attempts to
    parse that HTML by hand gave three different wrong answers. The JSON output
    has real panels and real arrays:

    ```sh
    goaccess <log> --log-format="$FORMAT" --no-global-config -o /tmp/x.json
    python3 -c 'import json;print(json.load(open("/tmp/x.json"))["referring_sites"]["data"])'
    ```

11. **A green timer and a rewritten report do not mean the filters applied.**
    Both were true while self-referrals were still visible. Check the content of
    the panel you changed, in the format the tool stores it.

## Referral URLs (full path, not just the host)

Two GoAccess panels, and they are not the same thing:

| Panel | Shows | Default |
|---|---|---|
| `REFERRING_SITES` | host only — `google.com` | enabled |
| `REFERRERS` | **full URL** — `google.com/search?q=...` | **disabled** |

The shipped `/etc/goaccess/goaccess.conf` contains `ignore-panel REFERRERS`
(line 534). That is why the main reports only ever show hosts: the full-URL
data is parsed and then thrown away. Our `log_format` already records
`"$http_referer"`, so nothing needs re-logging — only re-displaying.

`swanpan-referrals` produces `referrals-swanpan.html` and
`referrals-hoyoul.html` alongside the main reports, served from the same
basic-auth vhost.

### Why the self-referral filter is Python, not `--hide-referrer`

`--hide-referrer` is an **exact match** on the stored value. The `REFERRERS`
panel stores the **full URL including the path**, so the set of values to hide
is unbounded — `https://www.swanpan.io/store`, `/learn`, `/learn/1-2`, and every
other path the site can build. No fixed needle list covers that, and wildcards
are documented for `--ignore-referrer` but **not** for `--hide-referrer`.

So `swanpan-referrals` asks GoAccess for unfiltered JSON and filters **by host**
in `swanpan-referrals-render`. That is the rule we actually want: drop referers
whose host is one of ours. Empirically, a bare `https://www.swanpan.io` needle
hides **0** of the 265 path-bearing rows; only exact full-URL forms match, and
those change every time a new route ships.

The report keeps four buckets rather than one flat list:

- **External referral URLs** — the useful one
- **External referring hosts** — deduped by host
- **Self-referrals** — internal navigation, kept visible but labelled
- **No referer** — the count of hits with no `Referer` header at all

That last bucket matters more than it looks. A share near zero on a site with
real traffic means most hits are logged-in navigation, not new arrivals.

### Separate state dir, on purpose

`/var/lib/swanpan-traffic-referrals/`, not `/var/lib/swanpan-traffic/`. The main
job's state was seeded under different flags, and `--persist`/`--restore`
replays already-ingested rows — sharing it would resurrect rows this report
exists to exclude. The two jobs cannot poison each other.

### Referer values are attacker-controlled

Real garbage in our logs: `https://google.com, http://www.hoyoul.com/photos/...`
— two URLs stuffed into one header. The renderer splits on the comma and
classifies by the **last** URL, then buckets anything that will not parse as a
URL into **Unparseable referers** rather than dropping it silently.

## Referrer filtering

Two flags that are easy to mix up:

- `--hide-referrer=<needle>` hides the source from the REFERRING SITES panel but
  **still counts the visit**. Use for self-referrals: the visit is real, it just
  isn't an acquisition.
- `--ignore-referrer=<needle>` drops the hit entirely. Use for spam referrers
  that inflate totals.

### The needle must equal the panel value EXACTLY

This is trap 9 and it cost hours. `--hide-referrer` does **not** substring-match.
It compares against the value GoAccess stores in the referring-sites row, and
that value is the **host, with the port if one was present** — not the URL.

Measured on one log, counting the rows left afterwards:

| needle | drops | leaves behind |
|---|---|---|
| `174.138.42.13` | `174.138.42.13` (1 hit) | **`174.138.42.13:443` (273 hits)** |
| `174.138.42.13:443` | `174.138.42.13:443` | `174.138.42.13` |
| `*174.138.42.13*` | nothing | everything |
| `http://www.hoyoul.com` | nothing | everything |
| `www.hoyoul.com` | `www.hoyoul.com` | — |

So the needle list has to spell out every literal form the panel can hold.
`hoyoul.com` and `www.hoyoul.com` are two rows, and hiding one leaves the other.
The same referrer seen with and without a port is two rows.

Wildcards do not help — a `*needle*` pattern matched nothing. Scheme-prefixed
needles (`http://…`) also match nothing, because the panel never stores the
scheme.

### Changing the needle list needs a state reseed

`--hide-referrer` filters at **ingest**. `--persist`/`--restore` replays rows
that are already in the database, and those rows were ingested under whatever
flags existed at the time. A row that got in before the needle did stays in
every subsequent report forever.

Symptom: you edit the flags, the timer goes green, the report is rewritten
(bytes change), and the offending row is still there. Nothing is broken — the
row is being restored, not re-parsed.

Reseed after any filter change:

```sh
systemctl stop swanpan-traffic.timer
mv /var/lib/swanpan-traffic /var/lib/swanpan-traffic.bak-$(date +%s)
install -d -o www-data -g www-data /var/lib/swanpan-traffic
systemctl start swanpan-traffic.timer
```

Use `mv`, not `rm`, and **do not run the job by hand immediately afterwards**.
Let the timer produce the report, and make any verification wait for a report
whose mtime is newer than the reseed — checking "is the file recent?" against
the clock happily passes on the run you just did manually, which is how a stale
report gets mistaken for a fixed one.

Cost of a reseed is small: the job reads only the current `*.access.log`, not the
rotated `.1`/`.2.gz` files, so history beyond the current file was never in the
report to begin with.

Currently hidden:

- swanpan: `swanpan.io`, `www.swanpan.io`, `174.138.42.13`, `174.138.42.13:443`
- hoyoul: `hoyoul.com`, `www.hoyoul.com`, `calebkang.com`, `www.calebkang.com`,
  `174.138.42.13`, `174.138.42.13:443`

The droplet's own IP appears as a **referrer** (not just a client), because hits
to `https://174.138.42.13/` produce redirects that carry it as the source.
`--exclude-ip` cannot touch that — it filters the client column. It needs a
`--hide-referrer` needle like any other referrer.

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
