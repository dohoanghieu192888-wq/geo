#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$ROOT_DIR/config.env}"
TMP_CFG=""

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

valid_limit() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 ))
}

valid_ipv4() {
    local ip="$1"
    local part
    local count=0
    IFS='.' read -r -a parts <<< "$ip"
    [[ ${#parts[@]} -eq 4 ]] || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 0 <= 10#$part && 10#$part <= 255 )) || return 1
        ((count+=1))
    done
    [[ $count -eq 4 ]]
}

[[ $EUID -eq 0 ]] || fail "Run as root"
[[ -f /etc/os-release ]] || fail "Ubuntu 20.04 is required"
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "20.04" ]] || fail "Ubuntu 20.04 is required"
[[ "$(uname -m)" == "x86_64" ]] || fail "x86_64 is required"
[[ -f "$CONFIG_FILE" ]] || fail "Missing config: $CONFIG_FILE"

set -a
. "$CONFIG_FILE"
set +a

: "${PUBLIC_HTTP_PORT:=80}"
: "${WEB_BACKEND:=}"
: "${WEB_BACKEND_IP:=}"
: "${WEB_BACKEND_PORT:=}"
: "${GAME_RULES:=}"
: "${SSH_PORT:=22}"
: "${ADMIN_CIDR:=any}"
: "${UFW_ENABLE:=true}"
: "${MAX_HTTP_CONN:=4000}"
: "${MAX_GAME_CONN:=20000}"
: "${GEO_ENABLE:=true}"
: "${GEO_COUNTRY:=vn}"
: "${HTTP_RATE_LIMIT:=120}"
: "${GAME_CONN_RATE_LIMIT:=30}"
: "${HTTP_MAX_CONN_PER_IP:=80}"
: "${GAME_MAX_CONN_PER_IP:=20}"

valid_port "$PUBLIC_HTTP_PORT" || fail "Invalid PUBLIC_HTTP_PORT"
[[ "$PUBLIC_HTTP_PORT" == "80" ]] || fail "PUBLIC_HTTP_PORT must be 80"
if [[ -n "$WEB_BACKEND" ]]; then
    IFS=':' read -r WEB_BACKEND_IP WEB_BACKEND_PORT extra_web <<< "$WEB_BACKEND"
    [[ -z "${extra_web:-}" ]] || fail "Invalid WEB_BACKEND format. Use IP:PORT"
fi
: "${WEB_BACKEND_PORT:=80}"
valid_ipv4 "${WEB_BACKEND_IP:-}" || fail "Invalid WEB_BACKEND_IP"
valid_port "$WEB_BACKEND_PORT" || fail "Invalid WEB_BACKEND_PORT"
valid_port "$SSH_PORT" || fail "Invalid SSH_PORT"
valid_limit "$MAX_HTTP_CONN" || fail "Invalid MAX_HTTP_CONN"
[[ "$GEO_ENABLE" == "true" || "$GEO_ENABLE" == "false" ]] || fail "Invalid GEO_ENABLE"
[[ "$GEO_COUNTRY" =~ ^[a-z]{2}$ ]] || fail "Invalid GEO_COUNTRY"
valid_limit "$MAX_GAME_CONN" || fail "Invalid MAX_GAME_CONN"
valid_limit "$HTTP_MAX_CONN_PER_IP" || fail "Invalid HTTP_MAX_CONN_PER_IP"
valid_limit "$GAME_MAX_CONN_PER_IP" || fail "Invalid GAME_MAX_CONN_PER_IP"
valid_limit "$HTTP_RATE_LIMIT" || fail "Invalid HTTP_RATE_LIMIT"
valid_limit "$GAME_CONN_RATE_LIMIT" || fail "Invalid GAME_CONN_RATE_LIMIT"

if [[ "$ADMIN_CIDR" != "any" && ! "$ADMIN_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
    fail "Invalid ADMIN_CIDR"
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy ufw curl ca-certificates ipset iptables

install -d -m 0755 /etc/vipproxy
install -d -m 0755 /run/haproxy
install -d -m 0755 /etc/vipproxy/geo
install -o root -g root -m 0600 "$CONFIG_FILE" /etc/vipproxy/config.env
install -o root -g root -m 0755 "$ROOT_DIR/update-geo.sh" /usr/local/sbin/vipproxy-geo-update
install -o root -g root -m 0644 "$ROOT_DIR/vipproxy-geo.service" /etc/systemd/system/vipproxy-geo.service
install -o root -g root -m 0644 "$ROOT_DIR/vipproxy-geo.timer" /etc/systemd/system/vipproxy-geo.timer
systemctl daemon-reload
if [[ "$GEO_ENABLE" == "true" ]]; then
    RELOAD_HAPROXY=false /usr/local/sbin/vipproxy-geo-update
fi
GEO_FILE="/etc/vipproxy/geo/$GEO_COUNTRY.zone"

if [[ -f /etc/haproxy/haproxy.cfg ]]; then
    cp -a /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.$(date +%Y%m%d%H%M%S).bak"
fi

TMP_CFG="$(mktemp)"
trap 'rm -f "$TMP_CFG"' EXIT

{
    printf '%s\n' 'global'
    printf '%s\n' '    log /dev/log local0'
    printf '%s\n' '    log /dev/log local1 notice'
    printf '%s\n' '    chroot /var/lib/haproxy'
    printf '%s\n' '    user haproxy'
    printf '%s\n' '    group haproxy'
    printf '%s\n' '    daemon'
    printf '    maxconn %s\n' "$((MAX_HTTP_CONN + MAX_GAME_CONN))"
    printf '%s\n' 'defaults'
    printf '%s\n' '    log global'
    printf '%s\n' '    option dontlognull'
    printf '%s\n' '    timeout connect 5s'
    printf '%s\n' '    timeout client 1h'
    printf '%s\n' '    timeout server 1h'
    printf '%s\n' '    timeout tunnel 1h'
    printf '%s\n' '    timeout http-request 10s'
    printf '%s\n' '    timeout http-keep-alive 5s'
    printf '%s\n' 'frontend web_in'
    printf '    bind *:%s\n' "$PUBLIC_HTTP_PORT"
    printf '%s\n' '    mode http'
    printf '%s\n' '    option httplog'
    printf '    maxconn %s\n' "$MAX_HTTP_CONN"
    printf '%s\n' '    timeout http-request 10s'
    printf '%s\n' '    timeout client 30s'
    printf '%s\n' '    timeout client-fin 5s'
    if [[ "$GEO_ENABLE" == "true" ]]; then
        printf '    acl geo_allowed src -f %s\n' "$GEO_FILE"
        printf '%s\n' '    http-request deny deny_status 403 unless geo_allowed'
    fi
    printf '%s\n' '    stick-table type ip size 200k expire 10m store http_req_rate(10s),conn_cur'
    printf '%s\n' '    http-request track-sc0 src'
    printf '    http-request deny deny_status 429 if { sc_conn_cur(0) gt %s }\n' "$HTTP_MAX_CONN_PER_IP"
    printf '    http-request deny deny_status 429 if { sc_http_req_rate(0) gt %s }\n' "$HTTP_RATE_LIMIT"
    printf '%s\n' '    http-request del-header Proxy'
    printf '%s\n' '    http-request set-header X-Real-IP %[src]'
    printf '%s\n' '    http-request set-header X-Forwarded-For %[src]'
    printf '%s\n' '    http-request set-header X-Forwarded-Proto http'
    printf '%s\n' '    default_backend web_backend'
    printf '%s\n' 'backend web_backend'
    printf '%s\n' '    mode http'
    printf '%s\n' '    option httpchk'
    printf '    server web1 %s:%s check\n' "$WEB_BACKEND_IP" "$WEB_BACKEND_PORT"

    declare -A used_ports=(["$PUBLIC_HTTP_PORT"]=1)
    IFS=',' read -r -a rules <<< "$GAME_RULES"
    for rule in "${rules[@]}"; do
        [[ -z "$rule" ]] && continue
        IFS=':' read -r public_port backend_ip backend_port extra <<< "$rule"
        [[ -z "${extra:-}" ]] || fail "Invalid GAME_RULES entry: $rule"
        valid_port "${public_port:-}" || fail "Invalid public game port: $rule"
        valid_ipv4 "${backend_ip:-}" || fail "Invalid game backend IP: $rule"
        valid_port "${backend_port:-}" || fail "Invalid game backend port: $rule"
        [[ -z "${used_ports[$public_port]+x}" ]] || fail "Duplicate or reserved public port: $public_port"
        used_ports["$public_port"]=1
        printf 'frontend game_%s\n' "$public_port"
        printf '    bind *:%s\n' "$public_port"
        printf '%s\n' '    mode tcp'
        printf '%s\n' '    option tcplog'
        if [[ "$GEO_ENABLE" == "true" ]]; then
            printf '    acl geo_allowed src -f %s\n' "$GEO_FILE"
            printf '%s\n' '    tcp-request connection reject unless geo_allowed'
        fi
        printf '%s\n' '    stick-table type ip size 200k expire 10m store conn_rate(10s),conn_cur'
        printf '%s\n' '    tcp-request connection track-sc0 src'
        printf '    tcp-request connection reject if { sc_conn_cur(0) gt %s }\n' "$GAME_MAX_CONN_PER_IP"
        printf '    tcp-request connection reject if { sc_conn_rate(0) gt %s }\n' "$GAME_CONN_RATE_LIMIT"
        printf '    maxconn %s\n' "$MAX_GAME_CONN"
        printf '    default_backend game_backend_%s\n' "$public_port"
        printf 'backend game_backend_%s\n' "$public_port"
        printf '%s\n' '    mode tcp'
        printf '%s\n' '    option tcp-check'
        printf '    server game1 %s:%s check\n' "$backend_ip" "$backend_port"
    done
} > "$TMP_CFG"

haproxy -c -f "$TMP_CFG"
install -o root -g root -m 0644 "$TMP_CFG" /etc/haproxy/haproxy.cfg

if [[ "$UFW_ENABLE" == "true" ]]; then
    ufw --force default deny incoming
    ufw --force default allow outgoing
    if [[ "$ADMIN_CIDR" == "any" ]]; then
        ufw allow "$SSH_PORT/tcp"
    else
        ufw allow from "$ADMIN_CIDR" to any port "$SSH_PORT" proto tcp
    fi
    ufw allow "$PUBLIC_HTTP_PORT/tcp"
    IFS=',' read -r -a rules <<< "$GAME_RULES"
    for rule in "${rules[@]}"; do
        [[ -z "$rule" ]] && continue
        IFS=':' read -r public_port _ _ <<< "$rule"
        ufw allow "$public_port/tcp"
    done
    ufw --force enable
fi
{
    printf '%s\n' 'net.ipv4.tcp_syncookies=1'
    printf '%s\n' 'net.ipv4.tcp_max_syn_backlog=8192'
    printf '%s\n' 'net.core.somaxconn=8192'
    printf '%s\n' 'net.ipv4.icmp_echo_ignore_broadcasts=1'
    printf '%s\n' 'net.ipv4.conf.all.rp_filter=1'
    printf '%s\n' 'net.ipv4.conf.default.rp_filter=1'
} > /etc/sysctl.d/99-vipproxy.conf
sysctl --system >/dev/null

systemctl enable haproxy
systemctl restart haproxy
if [[ "$GEO_ENABLE" == "true" ]]; then
    systemctl enable --now vipproxy-geo.timer
else
    systemctl disable --now vipproxy-geo.timer 2>/dev/null || true
fi
systemctl --no-pager --full status haproxy
printf '%s\n' 'vipproxy is ready'
