#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${VIPPROXY_CONFIG:-/etc/vipproxy/config.env}"
PORTS_SET=vipproxy_ports
SCRUB_CHAIN=VIPPROXY_SCRUB
RAW_CHAIN=VIPPROXY_RAW

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

[[ $EUID -eq 0 ]] || fail "Run as root"
[[ -f "$CONFIG_FILE" ]] || fail "Missing config: $CONFIG_FILE"

. "$CONFIG_FILE"
: "${PUBLIC_HTTP_PORT:=80}"
: "${GAME_RULES:=}"
: "${SSH_PORT:=22}"
: "${HTTP_MAX_CONN_PER_IP:=0}"
: "${GAME_MAX_CONN_PER_IP:=0}"
: "${SYN_RATE_LIMIT:=0}"
: "${SYN_BURST_LIMIT:=60}"
: "${SYNPROXY_PORT:=}"

valid_port "$PUBLIC_HTTP_PORT" || fail "Invalid PUBLIC_HTTP_PORT"
valid_port "$SSH_PORT" || fail "Invalid SSH_PORT"
[[ "$SYN_RATE_LIMIT" =~ ^[0-9]+$ ]] || fail "Invalid SYN_RATE_LIMIT"
[[ "$SYN_BURST_LIMIT" =~ ^[0-9]+$ ]] || fail "Invalid SYN_BURST_LIMIT"
if [[ -n "$SYNPROXY_PORT" ]]; then
    valid_port "$SYNPROXY_PORT" || fail "Invalid SYNPROXY_PORT"
fi

declare -A proxy_ports=()
proxy_ports["$PUBLIC_HTTP_PORT"]=1
IFS=',' read -r -a rules <<< "$GAME_RULES"
for rule in "${rules[@]}"; do
    [[ -z "$rule" ]] && continue
    IFS=':' read -r public_port _ _ extra <<< "$rule"
    [[ -z "${extra:-}" ]] || fail "Invalid GAME_RULES entry: $rule"
    valid_port "${public_port:-}" || fail "Invalid game public port: $rule"
    proxy_ports["$public_port"]=1
done

port_list=()
for port in "${!proxy_ports[@]}"; do
    port_list+=("$port")
done
port_csv=$(IFS=,; echo "${port_list[*]}")
conn_cap=$((HTTP_MAX_CONN_PER_IP + GAME_MAX_CONN_PER_IP))

prepare_sets() {
    local port
    ipset create "$PORTS_SET" bitmap:port range 1-65535 -exist
    ipset flush "$PORTS_SET"
    for port in "${port_list[@]}" "$SSH_PORT"; do
        ipset add "$PORTS_SET" "$port" -exist
    done
}

apply_raw() {
    iptables -t raw -N "$RAW_CHAIN" 2>/dev/null || iptables -t raw -F "$RAW_CHAIN" 2>/dev/null || true
    iptables -t raw -A "$RAW_CHAIN" -i lo -j ACCEPT
    if [[ -n "$SYNPROXY_PORT" ]]; then
        iptables -t raw -A "$RAW_CHAIN" -p tcp --dport "$SYNPROXY_PORT" -j CT --notrack
    fi
    iptables -t raw -A "$RAW_CHAIN" -p tcp --syn -m set ! --match-set "$PORTS_SET" dst -j DROP
    if (( SYN_RATE_LIMIT > 0 )); then
        iptables -t raw -A "$RAW_CHAIN" -p tcp --syn -m hashlimit --hashlimit-name vipproxy_syn --hashlimit-mode srcip --hashlimit-above "${SYN_RATE_LIMIT}/sec" --hashlimit-burst "$SYN_BURST_LIMIT" -j DROP
    fi
    iptables -t raw -A "$RAW_CHAIN" -p udp -m multiport --dports "$port_csv" -j DROP
    if ! iptables -t raw -C PREROUTING -j "$RAW_CHAIN" 2>/dev/null; then
        iptables -t raw -I PREROUTING 1 -j "$RAW_CHAIN"
    fi
}

apply_filter() {
    iptables -N "$SCRUB_CHAIN" 2>/dev/null || iptables -F "$SCRUB_CHAIN"
    iptables -A "$SCRUB_CHAIN" -i lo -j ACCEPT
    iptables -A "$SCRUB_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A "$SCRUB_CHAIN" -m conntrack --ctstate INVALID -j DROP
    if [[ -n "$SYNPROXY_PORT" ]]; then
        iptables -A "$SCRUB_CHAIN" -p tcp --dport "$SYNPROXY_PORT" -m conntrack --ctstate INVALID,UNTRACKED -j SYNPROXY --sack-perm --timestamp --wscale 7 --mss 1460 2>/dev/null || true
        iptables -A "$SCRUB_CHAIN" -p tcp --dport "$SYNPROXY_PORT" -m conntrack --ctstate INVALID -j DROP
    fi
    iptables -A "$SCRUB_CHAIN" -p tcp ! --syn -m conntrack --ctstate NEW -j DROP
    iptables -A "$SCRUB_CHAIN" -p tcp --tcp-flags ALL NONE -j DROP
    iptables -A "$SCRUB_CHAIN" -p tcp --tcp-flags ALL ALL -j DROP
    iptables -A "$SCRUB_CHAIN" -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
    iptables -A "$SCRUB_CHAIN" -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
    iptables -A "$SCRUB_CHAIN" -f -j DROP 2>/dev/null || true
    iptables -A "$SCRUB_CHAIN" -p icmp --icmp-type echo-request -m limit --limit 10/sec --limit-burst 20 -j ACCEPT
    iptables -A "$SCRUB_CHAIN" -p icmp --icmp-type destination-unreachable -j ACCEPT
    iptables -A "$SCRUB_CHAIN" -p icmp --icmp-type time-exceeded -j ACCEPT
    iptables -A "$SCRUB_CHAIN" -p icmp --icmp-type parameter-problem -j ACCEPT
    iptables -A "$SCRUB_CHAIN" -p icmp -j DROP
    iptables -A "$SCRUB_CHAIN" -p tcp -m set ! --match-set "$PORTS_SET" dst -j DROP
    iptables -A "$SCRUB_CHAIN" -p udp -j DROP
    if (( conn_cap > 0 )); then
        iptables -A "$SCRUB_CHAIN" -p tcp -m multiport --dports "$port_csv" -m connlimit --connlimit-above "$conn_cap" --connlimit-mask 32 -j DROP
    fi
    iptables -C INPUT -j "$SCRUB_CHAIN" 2>/dev/null || iptables -I INPUT 1 -j "$SCRUB_CHAIN"
}

apply_rps() {
    local n mask file
    n=$(nproc 2>/dev/null || printf '1')
    if (( n > 8 )); then
        n=8
    fi
    mask=$(printf '%x' $(( (1 << n) - 1 )))
    while IFS= read -r file; do
        printf '%s' "$mask" > "$file" 2>/dev/null || true
    done < <(find /sys/class/net -path '*/queues/rx-*/rps_cpus' 2>/dev/null)
    while IFS= read -r file; do
        printf '4096' > "$file" 2>/dev/null || true
    done < <(find /sys/class/net -path '*/queues/rx-*/rps_flow_cnt' 2>/dev/null)
    if [[ -w /proc/sys/net/core/rps_sock_flow_entries ]]; then
        printf '32768' > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
    fi
}

modprobe xt_set 2>/dev/null || true
modprobe xt_hashlimit 2>/dev/null || true
modprobe xt_connlimit 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

prepare_sets
apply_raw
apply_filter
apply_rps

printf '%s\n' 'anti-ddos is applied'
