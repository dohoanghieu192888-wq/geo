#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=/etc/vipproxy/config.env
GEO_DIR=/etc/vipproxy/geo
CHROOT_GEO_DIR=/var/lib/haproxy/etc/vipproxy/geo
GEO_SET=vipproxy_geo
RELOAD_HAPROXY="${RELOAD_HAPROXY:-true}"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

[[ -f "$CONFIG_FILE" ]] || fail "Missing config: $CONFIG_FILE"
. "$CONFIG_FILE"
: "${PUBLIC_HTTP_PORT:=80}"
: "${GAME_RULES:=}"
: "${GEO_ENABLE:=true}"
: "${GEO_COUNTRY:=vn}"
[[ "$GEO_COUNTRY" =~ ^[a-z]{2}$ ]] || fail "Invalid GEO_COUNTRY"
valid_port "$PUBLIC_HTTP_PORT" || fail "Invalid PUBLIC_HTTP_PORT"

declare -A used_ports=()
used_ports["$PUBLIC_HTTP_PORT"]=1
IFS=',' read -r -a rules <<< "$GAME_RULES"
for rule in "${rules[@]}"; do
    [[ -z "$rule" ]] && continue
    IFS=':' read -r public_port _ _ extra <<< "$rule"
    [[ -z "${extra:-}" ]] || fail "Invalid GAME_RULES entry: $rule"
    valid_port "${public_port:-}" || fail "Invalid game public port: $rule"
    used_ports["$public_port"]=1
done

apply_kernel_scrub() {
    iptables -N VIPPROXY_SCRUB 2>/dev/null || iptables -F VIPPROXY_SCRUB
    iptables -A VIPPROXY_SCRUB -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A VIPPROXY_SCRUB -m conntrack --ctstate INVALID -j DROP
    iptables -A VIPPROXY_SCRUB -p tcp ! --syn -m conntrack --ctstate NEW -j DROP
    iptables -A VIPPROXY_SCRUB -p tcp --tcp-flags ALL NONE -j DROP
    iptables -A VIPPROXY_SCRUB -p tcp --tcp-flags ALL ALL -j DROP
    iptables -A VIPPROXY_SCRUB -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
    iptables -A VIPPROXY_SCRUB -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
    iptables -A VIPPROXY_SCRUB -f -j DROP 2>/dev/null || true
    iptables -A VIPPROXY_SCRUB -p udp -j DROP 2>/dev/null || true
    if ! iptables -C INPUT -j VIPPROXY_SCRUB 2>/dev/null; then
        iptables -I INPUT 1 -j VIPPROXY_SCRUB
    fi

    iptables -t raw -N VIPPROXY_RAW 2>/dev/null || iptables -t raw -F VIPPROXY_RAW 2>/dev/null || true
    local port
    for port in "${!used_ports[@]}"; do
        iptables -t raw -A VIPPROXY_RAW -p udp --dport "$port" -j DROP 2>/dev/null || true
    done
    if ! iptables -t raw -C PREROUTING -j VIPPROXY_RAW 2>/dev/null; then
        iptables -t raw -I PREROUTING 1 -j VIPPROXY_RAW 2>/dev/null || true
    fi
}

remove_kernel_scrub() {
    while iptables -D INPUT -j VIPPROXY_SCRUB 2>/dev/null; do :; done
    iptables -F VIPPROXY_SCRUB 2>/dev/null || true
    iptables -X VIPPROXY_SCRUB 2>/dev/null || true

    while iptables -t raw -D PREROUTING -j VIPPROXY_RAW 2>/dev/null; do :; done
    iptables -t raw -F VIPPROXY_RAW 2>/dev/null || true
    iptables -t raw -X VIPPROXY_RAW 2>/dev/null || true
}

remove_iptables_rules() {
    local port
    remove_kernel_scrub
    for port in "${!used_ports[@]}"; do
        while iptables -D INPUT -p tcp --dport "$port" -m set ! --match-set "$GEO_SET" src -j DROP 2>/dev/null; do :; done
    done
}

if [[ "$GEO_ENABLE" != "true" ]]; then
    remove_iptables_rules
    ipset destroy "$GEO_SET" 2>/dev/null || true
    exit 0
fi

install -d -m 0755 "$GEO_DIR"
install -d -m 0755 "$CHROOT_GEO_DIR"
TMP_GEO="$(mktemp)"
trap 'rm -f "$TMP_GEO"' EXIT
download_geo() {
    local url
    local urls=(
        "https://www.ipdeny.com/ipblocks/data/countries/${GEO_COUNTRY}.zone"
        "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/${GEO_COUNTRY}/ipv4-aggregated.txt"
        "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/geolite2_country/country_${GEO_COUNTRY}.netset"
    )
    for url in "${urls[@]}"; do
        if curl --fail --silent --show-error --location --max-time 15 "$url" -o "$TMP_GEO" 2>/dev/null; then
            if grep -Eq '^[0-9]+(\.[0-9]+){3}/[0-9]+$' "$TMP_GEO"; then
                return 0
            fi
        fi
    done
    return 1
}

if ! download_geo; then
    if [[ -f "$ROOT_DIR/geo/$GEO_COUNTRY.zone" ]]; then
        cp -f "$ROOT_DIR/geo/$GEO_COUNTRY.zone" "$TMP_GEO"
    elif [[ -f "/opt/geo_anti/geo/$GEO_COUNTRY.zone" ]]; then
        cp -f "/opt/geo_anti/geo/$GEO_COUNTRY.zone" "$TMP_GEO"
    elif [[ -f "$GEO_DIR/$GEO_COUNTRY.zone" ]]; then
        cp -f "$GEO_DIR/$GEO_COUNTRY.zone" "$TMP_GEO"
    else
        fail "Cannot download or locate geo list for $GEO_COUNTRY"
    fi
fi

install -o root -g root -m 0644 "$TMP_GEO" "$GEO_DIR/$GEO_COUNTRY.zone"
install -o root -g root -m 0644 "$TMP_GEO" "$CHROOT_GEO_DIR/$GEO_COUNTRY.zone"

ipset create "$GEO_SET" hash:net family inet maxelem 200000 -exist
ipset create "${GEO_SET}_new" hash:net family inet maxelem 200000 -exist
ipset flush "${GEO_SET}_new"
while IFS= read -r cidr; do
    [[ -z "$cidr" ]] && continue
    ipset add "${GEO_SET}_new" "$cidr" -exist
done < "$GEO_DIR/$GEO_COUNTRY.zone"
ipset swap "${GEO_SET}_new" "$GEO_SET"
ipset destroy "${GEO_SET}_new"

for port in "${!used_ports[@]}"; do
    if ! iptables -C INPUT -p tcp --dport "$port" -m set ! --match-set "$GEO_SET" src -j DROP 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "$port" -m set ! --match-set "$GEO_SET" src -j DROP
    fi
done
apply_kernel_scrub

if [[ "$RELOAD_HAPROXY" == "true" ]]; then
    systemctl reload haproxy
fi
