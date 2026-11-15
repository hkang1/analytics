# Analytics reports for swanpan.io and hoyoul.com.
#
# Dedicated hostname, own certificate. Nothing here can affect the product
# sites: if this vhost is broken, checkout and sign-in are untouched.
#
# The reports list visitor IPs, so access is gated at the edge by Cloudflare
# Access (app "Analytics reports", allow-list by email). There is no basic auth
# here and no password file on the box: one place decides who gets in, and it is
# not this vhost. That only holds because the origin answers Cloudflare alone --
# see "Origin lock" in the README.
#
# The certificate is a Cloudflare **Origin CA** cert, valid 15 years, trusted by
# the Cloudflare edge and by nothing else. That is the point: no public CA needs
# to reach this box, so there is no ACME challenge to serve and no renewal timer
# to fail silently. The old Let's Encrypt webroot blocks are gone with it.
#
# NOTE: use `root`, not `alias`. `alias` substitutes the matched location
# prefix, so `location = /` with `alias .../index.html` produced
# ".../index.htmlindex.html" and a 500. `root` appends the URI to the
# directory, which is the behaviour we actually want.

server {
    listen 80;
    listen [::]:80;
    server_name analytics.limeyeti.com;

    # No ACME path any more: the certificate is not issued by a public CA, so
    # nothing ever fetches a challenge from here. Plain HTTP does one thing --
    # send the visitor to HTTPS.
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name analytics.limeyeti.com;

    # Cloudflare Origin CA. The full chain (leaf + intermediate) lives in one
    # file; the key never leaves this box.
    ssl_certificate     /etc/ssl/cloudflare/analytics.limeyeti.com.pem;
    ssl_certificate_key /etc/ssl/cloudflare/analytics.limeyeti.com.key;

    add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    add_header Cache-Control "private, no-store" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        root /var/www/traffic;
        index index.html;
        autoindex off;
        try_files $uri $uri/ =404;
    }
}
