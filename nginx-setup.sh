#!/bin/bash

read -p "Marzban Dashboard and phpMyAdmin domain: " PRIMARY_DOMAIN
read -p "Sub-Site domain: " SUBSITE_DOMAIN

apt install curl gnupg2 ca-certificates lsb-release ubuntu-keyring -y

curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
| sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
    | sudo tee /etc/apt/sources.list.d/nginx.list

echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
    | sudo tee /etc/apt/preferences.d/99nginx

apt update && apt install nginx -y

mkdir -p /etc/nginx/snippets

cat <<EOF > /etc/nginx/snippets/self-signed.conf
ssl_certificate /etc/ssl/certs/nginx-selfsigned.crt;
ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;
ssl_dhparam /etc/ssl/certs/dhparam.pem;
EOF

cat <<EOF > /etc/nginx/snippets/ssl-params.conf
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;  # about 40000 sessions
ssl_session_tickets off;

resolver 8.8.8.8 8.8.4.4;
resolver_timeout 5s;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;
EOF

cat <<EOF > /etc/nginx/snippets/cloudflare.conf
# Cloudflare

# - IPv4
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;

# - IPv6
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;

real_ip_header CF-Connecting-IP;
EOF

rm -f /etc/nginx/conf.d/default.conf

cat <<EOF > /etc/nginx/conf.d/marzban-dash.conf
server {
    server_name dash.${PRIMARY_DOMAIN};

    listen 8443 ssl;
    http2 on;

    gzip off;

    location ~* /(sub|dashboard|api|statics|docs|redoc|openapi.json) {
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        return 404;
    }

    include /etc/nginx/snippets/self-signed.conf;
    include /etc/nginx/snippets/ssl-params.conf;
    include /etc/nginx/snippets/cloudflare.conf;
}
EOF

cat <<EOF > /etc/nginx/conf.d/sub-site.conf
server {
    server_name ${SUBSITE_DOMAIN};

    listen 8443 ssl;
    http2 on;

    gzip off;

    location /sub {
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        return 401;
    }

    include /etc/nginx/snippets/self-signed.conf;
    include /etc/nginx/snippets/ssl-params.conf;
    include /etc/nginx/snippets/cloudflare.conf;
}
EOF

cat <<EOF > /etc/nginx/conf.d/phpmyadmin.conf
server {
    server_name pma.${PRIMARY_DOMAIN};

    listen 8443 ssl;
    http2 on;

    gzip off;

    port_in_redirect off;

    location / {
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:5010;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    include /etc/nginx/snippets/self-signed.conf;
    include /etc/nginx/snippets/ssl-params.conf;
    include /etc/nginx/snippets/cloudflare.conf;
}
EOF

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/private/nginx-selfsigned.key \
    -out /etc/ssl/certs/nginx-selfsigned.crt \
    -subj "/CN=MyCert"

openssl dhparam -dsaparam -out /etc/ssl/certs/dhparam.pem 2048

nginx -t && systemctl restart nginx

cat <<EOF > /opt/marzban/docker-compose.yml
services:
  marzban:
    image: gozargah/marzban:latest
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban
    depends_on:
      mariadb:
        condition: service_healthy

  mariadb:
    image: mariadb:lts
    env_file: .env
    network_mode: host
    restart: always
    command:
      - --bind-address=127.0.0.1
      - --character_set_server=utf8mb4
      - --collation_server=utf8mb4_unicode_ci
      - --host-cache-size=0
      - --innodb-open-files=1024
      - --innodb-buffer-pool-size=268435456
      - --binlog_expire_logs_seconds=5184000 # 60 days
    volumes:
      - mariadb_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      start_interval: 3s
      interval: 10s
      timeout: 5s
      retries: 3

  phpmyadmin:
    image: phpmyadmin/phpmyadmin:latest
    restart: always
    network_mode: host
    environment:
      PMA_HOST: 127.0.0.1
      PMA_PORT: 3306
      APACHE_PORT: 5010
      PMA_ABSOLUTE_URI: https://pma.${PRIMARY_DOMAIN}/
      UPLOAD_LIMIT: 300M
    depends_on:
      mariadb:
        condition: service_healthy

volumes:
  mariadb_data:
    name: mariadb_data
    external: true

EOF

marzban restart
