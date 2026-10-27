# Analytics reports for swanpan.io and hoyoul.com.
#
# Dedicated hostname, own certificate, own password file. Nothing here can
# affect the product sites: if this vhost is broken, checkout and sign-in are
# untouched.
#
# The reports list visitor IPs, so access is gated by basic auth over HTTPS
# only. Port 80 exists solely to serve ACME challenges and to redirect.
#
# NOTE: use `root`, not `alias`. `alias` substitutes the matched location
# prefix, so `location = /` with `alias .../index.html` produced
# ".../index.htmlindex.html" and a 500. `root` appends the URI to the
# directory, which is the behaviour we actually want.

server {
    listen 80;
    listen [::]:80;
    server_name analytics.limeyeti.com;

    # Token validation must work without auth and without a redirect.
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type "text/plain";
        try_files $uri =404;
    }

    # Everything else over plain HTTP goes to HTTPS. No content served here.
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name analytics.limeyeti.com;

    ssl_certificate     /etc/letsencrypt/live/analytics.limeyeti.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/analytics.limeyeti.com/privkey.pem;

    add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    add_header Cache-Control "private, no-store" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;

    # Also serve the challenge on 443: Cloudflare's "Always Use HTTPS" turns the
    # validator's http-01 request into an HTTPS one, and without this the
    # challenge 404s and webroot validation fails. That failure is exactly what
    # pushed the original issuance onto the standalone authenticator.
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type "text/plain";
        try_files $uri =404;
    }

    location / {
        root /var/www/traffic;
        index index.html;
        auth_basic "Traffic reports";
        auth_basic_user_file /etc/nginx/.htpasswd-limeyeti;
        autoindex off;
        try_files $uri $uri/ =404;
    }
}
