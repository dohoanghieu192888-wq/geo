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

valid_limit0() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 <= 1000000 ))
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
: "${HTTP_RATE_LIMIT:=0}"
: "${GAME_CONN_RATE_LIMIT:=0}"
: "${HTTP_MAX_CONN_PER_IP:=0}"
: "${GAME_MAX_CONN_PER_IP:=0}"
: "${ALLOWED_HOSTS:=}"

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
valid_limit0 "$HTTP_MAX_CONN_PER_IP" || fail "Invalid HTTP_MAX_CONN_PER_IP"
valid_limit0 "$GAME_MAX_CONN_PER_IP" || fail "Invalid GAME_MAX_CONN_PER_IP"
valid_limit0 "$HTTP_RATE_LIMIT" || fail "Invalid HTTP_RATE_LIMIT"
valid_limit0 "$GAME_CONN_RATE_LIMIT" || fail "Invalid GAME_CONN_RATE_LIMIT"
if [[ -n "$ALLOWED_HOSTS" && ! "$ALLOWED_HOSTS" =~ ^[A-Za-z0-9.*_:,-]+$ ]]; then
    fail "Invalid ALLOWED_HOSTS"
fi
THREADS="$(nproc 2>/dev/null || printf '1')"
if (( THREADS > 8 )); then
    THREADS=8
fi
if (( THREADS < 1 )); then
    THREADS=1
fi

if [[ "$ADMIN_CIDR" != "any" && ! "$ADMIN_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
    fail "Invalid ADMIN_CIDR"
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy ufw curl ca-certificates ipset iptables

install -d -m 0755 /etc/vipproxy
install -d -m 0755 /run/haproxy
install -d -m 0755 /etc/vipproxy/geo
install -d -m 0755 /var/lib/haproxy/etc/vipproxy/geo
if [[ -f "$ROOT_DIR/geo/$GEO_COUNTRY.zone" ]]; then
    install -o root -g root -m 0644 "$ROOT_DIR/geo/$GEO_COUNTRY.zone" "/etc/vipproxy/geo/$GEO_COUNTRY.zone"
    install -o root -g root -m 0644 "$ROOT_DIR/geo/$GEO_COUNTRY.zone" "/var/lib/haproxy/etc/vipproxy/geo/$GEO_COUNTRY.zone"
fi
install -o root -g root -m 0600 "$CONFIG_FILE" /etc/vipproxy/config.env
install -o root -g root -m 0755 "$ROOT_DIR/update-geo.sh" /usr/local/sbin/vipproxy-geo-update
install -o root -g root -m 0644 "$ROOT_DIR/vipproxy-geo.service" /etc/systemd/system/vipproxy-geo.service
install -o root -g root -m 0755 "$ROOT_DIR/anti-ddos.sh" /usr/local/sbin/vipproxy-anti-ddos
install -o root -g root -m 0644 "$ROOT_DIR/vipproxy-geo.timer" /etc/systemd/system/vipproxy-geo.timer
install -o root -g root -m 0644 "$ROOT_DIR/vipproxy-anti-ddos.service" /etc/systemd/system/vipproxy-anti-ddos.service
systemctl daemon-reload
RELOAD_HAPROXY=false /usr/local/sbin/vipproxy-geo-update
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
    printf '    nbthread %s\n' "$THREADS"
    printf '%s\n' '    tune.bufsize 32768'
    printf '%s\n' '    tune.maxrewrite 1024'
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
    printf '%s\n' '    timeout queue 15s'
    printf '%s\n' '    option tcp-smart-accept'
    printf '%s\n' '    option tcp-smart-connect'
    printf '%s\n' 'backend abuse'
    printf '%s\n' '    stick-table type ip size 500k expire 1m store conn_rate(10s),conn_cur'
    printf '%s\n' '    server none 127.0.0.1:1 disabled'
    printf '%s\n' 'frontend web_in'
    printf '    bind *:%s\n' "$PUBLIC_HTTP_PORT"
    printf '%s\n' '    mode http'
    printf '%s\n' '    option httplog'
    printf '    maxconn %s\n' "$MAX_HTTP_CONN"
    printf '%s\n' '    timeout http-request 5s'
    printf '%s\n' '    timeout client 20s'
    printf '%s\n' '    timeout client-fin 2s'
    printf '%s\n' '    option http-buffer-request'
    if (( HTTP_MAX_CONN_PER_IP > 0 )); then
        printf '%s\n' '    tcp-request connection track-sc2 src table abuse'
        printf '    tcp-request connection reject if { sc_conn_cur(2) gt %s }\n' "$HTTP_MAX_CONN_PER_IP"
    fi
    printf '%s\n' '    acl valid_method method GET HEAD POST PUT DELETE OPTIONS'
    printf '%s\n' '    http-request silent-drop unless valid_method'
    printf '%s\n' '    acl has_host hdr_cnt(host) gt 0'
    printf '%s\n' '    http-request silent-drop unless has_host'
    printf '%s\n' '    http-request silent-drop if { req.hdr_cnt(host) gt 1 }'
    printf '%s\n' '    http-request silent-drop if { req.hdr(user-agent) -m len gt 512 }'
    printf '%s\n' '    http-request silent-drop if { path -m len gt 1024 }'
    printf '%s\n' '    acl bad_path path_beg -i /.env /.git /.svn /.hg /.aws /.ssh /.kube /wp-login.php /wp-admin /xmlrpc.php /phpmyadmin /pma /myadmin /cgi-bin /actuator /solr /jenkins /manager/html /server-status /server-info /etc/passwd /proc/self /boaform /GponForm /setup.cgi /SDK/webLanguage'
    printf '%s\n' '    http-request silent-drop if bad_path'
    printf '%s\n' '    acl bad_scan_bots hdr_sub(User-Agent) -i sqlmap nikto wpscan masscan zgrab censys fwdns httpx gobuster dirbuster nmap c2-enum nuclei'
    printf '%s\n' '    http-request silent-drop if bad_scan_bots'
    printf '%s\n' '    http-request silent-drop if { req.body_size gt 20971520 }'
    if [[ -n "$ALLOWED_HOSTS" ]]; then
        printf '    acl allowed_host req.hdr(host),field(1,:) -i %s\n' "${ALLOWED_HOSTS//,/ }"
        printf '%s\n' '    http-request silent-drop unless allowed_host'
    fi
    if [[ "$GEO_ENABLE" == "true" ]]; then
        printf '    acl geo_allowed src -f %s\n' "$GEO_FILE"
        printf '%s\n' '    http-request deny deny_status 403 unless geo_allowed'
    fi
    printf '%s\n' '    stick-table type ip size 500k expire 10m store http_req_rate(10s),http_err_rate(10s),conn_cur'
    printf '%s\n' '    http-request track-sc0 src'
    printf '%s\n' '    http-request silent-drop if { sc_http_err_rate(0) gt 15 }'
    if (( HTTP_MAX_CONN_PER_IP > 0 )); then
        printf '    http-request silent-drop if { sc_conn_cur(0) gt %s }\n' "$HTTP_MAX_CONN_PER_IP"
    fi
    if (( HTTP_RATE_LIMIT > 0 )); then
        printf '    http-request deny deny_status 429 if { sc_http_req_rate(0) gt %s }\n' "$HTTP_RATE_LIMIT"
    fi
    printf '%s\n' '    http-response del-header Server'
    printf '%s\n' '    http-response del-header X-Powered-By'
    printf '%s\n' '    http-response del-header X-AspNet-Version'
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
        printf '%s\n' '    stick-table type ip size 500k expire 10m store conn_rate(10s),conn_cur'
        printf '%s\n' '    tcp-request connection track-sc0 src'
        if (( GAME_MAX_CONN_PER_IP > 0 )); then
            printf '%s\n' '    tcp-request connection track-sc2 src table abuse'
            printf '    tcp-request connection reject if { sc_conn_cur(2) gt %s }\n' "$GAME_MAX_CONN_PER_IP"
            printf '    tcp-request connection reject if { sc_conn_cur(0) gt %s }\n' "$GAME_MAX_CONN_PER_IP"
        fi
        if (( GAME_CONN_RATE_LIMIT > 0 )); then
            printf '    tcp-request connection reject if { sc_conn_rate(0) gt %s }\n' "$GAME_CONN_RATE_LIMIT"
        fi
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
        ufw limit "$SSH_PORT/tcp"
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
/usr/local/sbin/vipproxy-anti-ddos
modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true
{
    printf '%s\n' 'fs.file-max=2097152'
    printf '%s\n' 'net.core.somaxconn=65535'
    printf '%s\n' 'net.core.netdev_max_backlog=65535'
    printf '%s\n' 'net.core.rmem_max=16777216'
    printf '%s\n' 'net.core.wmem_max=16777216'
    printf '%s\n' 'net.core.optmem_max=65536'
    printf '%s\n' 'net.core.default_qdisc=fq'
    printf '%s\n' 'net.ipv4.tcp_congestion_control=bbr'
    printf '%s\n' 'net.ipv4.tcp_rmem=4096 87380 16777216'
    printf '%s\n' 'net.ipv4.tcp_wmem=4096 65536 16777216'
    printf '%s\n' 'net.ipv4.tcp_mem=786432 1048576 26777216'
    printf '%s\n' 'net.ipv4.tcp_max_syn_backlog=65535'
    printf '%s\n' 'net.ipv4.tcp_syncookies=1'
    printf '%s\n' 'net.ipv4.tcp_synack_retries=2'
    printf '%s\n' 'net.ipv4.tcp_syn_retries=2'
    printf '%s\n' 'net.ipv4.tcp_fin_timeout=15'
    printf '%s\n' 'net.ipv4.tcp_tw_reuse=1'
    printf '%s\n' 'net.ipv4.tcp_max_tw_buckets=1440000'
    printf '%s\n' 'net.ipv4.tcp_rfc1337=1'
    printf '%s\n' 'net.ipv4.tcp_slow_start_after_idle=0'
    printf '%s\n' 'net.ipv4.tcp_notsent_lowat=16384'
    printf '%s\n' 'net.ipv4.tcp_mtu_probing=1'
    printf '%s\n' 'net.ipv4.tcp_max_orphans=262144'
    printf '%s\n' 'net.ipv4.tcp_challenge_ack_limit=2147483647'
    printf '%s\n' 'net.ipv4.ip_local_port_range=10240 65000'
    printf '%s\n' 'net.ipv4.icmp_echo_ignore_broadcasts=1'
    printf '%s\n' 'net.ipv4.icmp_ignore_bogus_error_responses=1'
    printf '%s\n' 'net.ipv4.conf.all.rp_filter=1'
    printf '%s\n' 'net.ipv4.conf.default.rp_filter=1'
    printf '%s\n' 'net.ipv4.conf.all.accept_source_route=0'
    printf '%s\n' 'net.ipv4.conf.default.accept_source_route=0'
    printf '%s\n' 'net.ipv4.conf.all.accept_redirects=0'
    printf '%s\n' 'net.ipv4.conf.default.accept_redirects=0'
    printf '%s\n' 'net.ipv4.conf.all.send_redirects=0'
    printf '%s\n' 'net.ipv4.conf.default.send_redirects=0'
    printf '%s\n' 'net.netfilter.nf_conntrack_max=1048576'
    printf '%s\n' 'net.netfilter.nf_conntrack_buckets=262144'
    printf '%s\n' 'net.core.rps_sock_flow_entries=32768'
    printf '%s\n' 'net.netfilter.nf_conntrack_tcp_timeout_syn_recv=20'
    printf '%s\n' 'net.netfilter.nf_conntrack_tcp_timeout_established=600'
    printf '%s\n' 'net.netfilter.nf_conntrack_tcp_timeout_time_wait=30'
} > /etc/sysctl.d/99-vipproxy.conf
sysctl --system >/dev/null 2>&1 || true

install -d -m 0755 /etc/systemd/system/haproxy.service.d
{
    printf '%s\n' '[Service]'
    printf '%s\n' 'LimitNOFILE=1048576'
    printf '%s\n' 'Restart=always'
    printf '%s\n' 'RestartSec=2'
} > /etc/systemd/system/haproxy.service.d/limits.conf
systemctl daemon-reload

systemctl enable haproxy
systemctl restart haproxy
systemctl enable vipproxy-anti-ddos.service
systemctl enable --now vipproxy-geo.timer
systemctl --no-pager --full status haproxy
printf '%s\n' 'vipproxy is ready'
