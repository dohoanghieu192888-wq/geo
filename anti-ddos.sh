#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${VIPPROXY_CONFIG:-/etc/vipproxy/config.env}"
PORTS_SET=vipproxy_ports
WAF_SET=vipproxy_waf
SCRUB_CHAIN=VIPPROXY_SCRUB
RAW_CHAIN=VIPPROXY_RAW

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

valid_cidr() {
    local ip="${1%/*}" prefix="${1##*/}" octet
    local -a octets
    [[ "$1" == */* && "$prefix" =~ ^[0-9]{1,2}$ ]] && (( 10#$prefix >= 1 && 10#$prefix <= 32 )) || return 1
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

valid_csv() {
    local csv="$1" kind="$2" item limit=15
    local -a items
    [[ -z "$csv" ]] && return 0
    [[ "$kind" == "cidr" ]] && limit=32
    IFS=',' read -r -a items <<< "$csv"
    (( ${#items[@]} <= limit )) || return 1
    for item in "${items[@]}"; do
        if [[ "$kind" == "port" ]]; then
            valid_port "$item" || return 1
        else
            valid_cidr "$item" || return 1
        fi
    done
}

[[ $EUID -eq 0 ]] || fail "Run as root"
[[ -f "$CONFIG_FILE" ]] || fail "Missing config: $CONFIG_FILE"

. "$CONFIG_FILE"
: "${PUBLIC_HTTP_PORT:=80}"
: "${GAME_RULES:=}"
: "${SSH_PORT:=22}"
: "${SYNPROXY_PORT:=}"
: "${CONNTRACK_TCP_LOOSE:=0}"
: "${UDP_REPLY_PORTS:=53,123,67,68}"
: "${ALLOW_UDP_PORTS:=}"
: "${WAF_TRUSTED_CIDRS:=}"

valid_port "$PUBLIC_HTTP_PORT" || fail "Invalid PUBLIC_HTTP_PORT"
valid_port "$SSH_PORT" || fail "Invalid SSH_PORT"
valid_csv "$UDP_REPLY_PORTS" port || fail "Invalid UDP_REPLY_PORTS"
valid_csv "$ALLOW_UDP_PORTS" port || fail "Invalid ALLOW_UDP_PORTS"
valid_csv "$WAF_TRUSTED_CIDRS" cidr || fail "Invalid WAF_TRUSTED_CIDRS"
[[ "$CONNTRACK_TCP_LOOSE" == "0" || "$CONNTRACK_TCP_LOOSE" == "1" ]] || fail "Invalid CONNTRACK_TCP_LOOSE"
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
    [[ -z "${proxy_ports[$public_port]+x}" ]] || fail "Duplicate or reserved public port: $public_port"
    proxy_ports["$public_port"]=1
done
[[ -z "${proxy_ports[$SSH_PORT]+x}" ]] || fail "SSH_PORT must not be a web/game port"
if [[ -n "$SYNPROXY_PORT" ]]; then
    [[ -n "${proxy_ports[$SYNPROXY_PORT]+x}" ]] || fail "SYNPROXY_PORT must be the web port or a game public port"
    CONNTRACK_TCP_LOOSE=0
fi

prepare_sets() {
    local port cidr
    local -a waf_cidrs
    ipset create "$PORTS_SET" bitmap:port range 1-65535 -exist
    ipset flush "$PORTS_SET"
    for port in "${!proxy_ports[@]}" "$SSH_PORT"; do
        ipset add "$PORTS_SET" "$port" -exist
    done
    ipset create "$WAF_SET" hash:net -exist
    ipset flush "$WAF_SET"
    if [[ -n "$WAF_TRUSTED_CIDRS" ]]; then
        IFS=',' read -r -a waf_cidrs <<< "$WAF_TRUSTED_CIDRS"
        for cidr in "${waf_cidrs[@]}"; do
            ipset add "$WAF_SET" "$cidr" -exist
        done
    fi
}

apply_raw() {
    iptables -t raw -N "$RAW_CHAIN" 2>/dev/null || iptables -t raw -F "$RAW_CHAIN" 2>/dev/null || true
    iptables -t raw -A "$RAW_CHAIN" -i lo -j ACCEPT
    if [[ -n "$WAF_TRUSTED_CIDRS" ]]; then
        iptables -t raw -A "$RAW_CHAIN" -p tcp --dport "$PUBLIC_HTTP_PORT" -m set ! --match-set "$WAF_SET" src -j DROP
    fi
    iptables -t raw -A "$RAW_CHAIN" -f -j DROP
    iptables -t raw -A "$RAW_CHAIN" -p tcp --tcp-flags ALL NONE -j DROP
    iptables -t raw -A "$RAW_CHAIN" -p tcp --tcp-flags ALL ALL -j DROP
    iptables -t raw -A "$RAW_CHAIN" -p tcp --tcp-flags ALL FIN,PSH,URG -j DROP
    iptables -t raw -A "$RAW_CHAIN" -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
    iptables -t raw -A "$RAW_CHAIN" -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
    iptables -t raw -A "$RAW_CHAIN" -p tcp --tcp-flags FIN,RST FIN,RST -j DROP
    iptables -t raw -A "$RAW_CHAIN" -p tcp --tcp-flags ACK,FIN FIN -j DROP
    iptables -t raw -A "$RAW_CHAIN" -p tcp --sport 0:0 -j DROP
    if [[ -n "$SYNPROXY_PORT" ]]; then
        iptables -t raw -A "$RAW_CHAIN" -p tcp --dport "$SYNPROXY_PORT" -j CT --notrack
    fi
    iptables -t raw -A "$RAW_CHAIN" -p tcp --syn -m set ! --match-set "$PORTS_SET" dst -j DROP
    if [[ -n "$ALLOW_UDP_PORTS" ]]; then
        iptables -t raw -A "$RAW_CHAIN" -p udp -m multiport --dports "$ALLOW_UDP_PORTS" -j ACCEPT
    fi
    if [[ -n "$UDP_REPLY_PORTS" ]]; then
        iptables -t raw -A "$RAW_CHAIN" -p udp -m multiport --sports "$UDP_REPLY_PORTS" -m limit --limit 1000/sec --limit-burst 2000 -j ACCEPT
        iptables -t raw -A "$RAW_CHAIN" -p udp -m multiport --sports "$UDP_REPLY_PORTS" -j DROP
    fi
    iptables -t raw -A "$RAW_CHAIN" -p udp -j DROP
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
    iptables -A "$SCRUB_CHAIN" -p tcp --tcp-flags ALL FIN,PSH,URG -j DROP
    iptables -A "$SCRUB_CHAIN" -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
    iptables -A "$SCRUB_CHAIN" -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
    iptables -A "$SCRUB_CHAIN" -p tcp --tcp-flags FIN,RST FIN,RST -j DROP
    iptables -A "$SCRUB_CHAIN" -p tcp --tcp-flags ACK,FIN FIN -j DROP
    iptables -A "$SCRUB_CHAIN" -p tcp --sport 0:0 -j DROP
    iptables -A "$SCRUB_CHAIN" -f -j DROP 2>/dev/null || true
    iptables -A "$SCRUB_CHAIN" -p icmp --icmp-type echo-request -m limit --limit 10/sec --limit-burst 20 -j ACCEPT
    iptables -A "$SCRUB_CHAIN" -p icmp --icmp-type destination-unreachable -j ACCEPT
    iptables -A "$SCRUB_CHAIN" -p icmp --icmp-type time-exceeded -j ACCEPT
    iptables -A "$SCRUB_CHAIN" -p icmp --icmp-type parameter-problem -j ACCEPT
    iptables -A "$SCRUB_CHAIN" -p icmp -j DROP
    iptables -A "$SCRUB_CHAIN" -p tcp -m set ! --match-set "$PORTS_SET" dst -j DROP
    if [[ -n "$WAF_TRUSTED_CIDRS" ]]; then
        iptables -A "$SCRUB_CHAIN" -p tcp --dport "$PUBLIC_HTTP_PORT" -m set ! --match-set "$WAF_SET" src -j DROP
    fi
    if [[ -n "$ALLOW_UDP_PORTS" ]]; then
        iptables -A "$SCRUB_CHAIN" -p udp -m multiport --dports "$ALLOW_UDP_PORTS" -j ACCEPT
    fi
    case ",$UDP_REPLY_PORTS," in
        *",67,"*|*",68,"*)
            iptables -A "$SCRUB_CHAIN" -p udp -m multiport --sports 67,68 -j ACCEPT
            ;;
    esac
    iptables -A "$SCRUB_CHAIN" -p udp -j DROP
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

apply_conntrack() {
    printf '%s\n' "$CONNTRACK_TCP_LOOSE" > /proc/sys/net/netfilter/nf_conntrack_tcp_loose 2>/dev/null || true
}

synproxy_supported() {
    local probe=VIPPROXY_SYNPROXY_PROBE
    iptables -t filter -N "$probe" 2>/dev/null || iptables -t filter -F "$probe" 2>/dev/null || return 1
    if ! iptables -t filter -A "$probe" -p tcp --dport 1 -m conntrack --ctstate UNTRACKED -j SYNPROXY --sack-perm --timestamp --wscale 7 --mss 1460 2>/dev/null; then
        iptables -t filter -X "$probe" 2>/dev/null || true
        return 1
    fi
    iptables -t filter -F "$probe" 2>/dev/null || true
    iptables -t filter -X "$probe" 2>/dev/null || true
    return 0
}

waf_state=off
[[ -n "$WAF_TRUSTED_CIDRS" ]] && waf_state=on

modprobe xt_set 2>/dev/null || true
modprobe xt_multiport 2>/dev/null || true
modprobe xt_SYNPROXY 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

if [[ -n "$SYNPROXY_PORT" ]] && ! synproxy_supported; then
    printf 'warning: SYNPROXY is not supported by this iptables backend; disabling it\n' >&2
    SYNPROXY_PORT=""
fi

prepare_sets
apply_conntrack
apply_filter
apply_raw
apply_rps

printf 'anti-ddos is applied (synproxy=%s conntrack_loose=%s waf=%s)\n' "${SYNPROXY_PORT:-off}" "$CONNTRACK_TCP_LOOSE" "$waf_state"
