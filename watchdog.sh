#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${VIPPROXY_CONFIG:-/etc/vipproxy/config.env}"
NET_DEV="${NET_DEV:-/proc/net/dev}"
ANTI_DDOS_BIN=/usr/local/sbin/vipproxy-anti-ddos

: "${WATCH_INTERVAL:=10}"
: "${WATCH_INBOUND_MBPS:=300}"
: "${WATCH_INBOUND_PPS:=300000}"
: "${WATCH_COOLDOWN:=3}"
: "${WATCH_WEBHOOK:=}"
: "${WATCH_MITIGATION_CMD:=}"
: "${WATCH_IFACE:=}"
: "${WATCH_MAX_CYCLES:=0}"

if [[ -f "$CONFIG_FILE" ]]; then
    . "$CONFIG_FILE"
fi

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[[ -r "$NET_DEV" ]] || fail "watchdog: cannot read $NET_DEV"
[[ "$WATCH_INTERVAL" =~ ^[0-9]+$ ]] && (( WATCH_INTERVAL >= 1 )) || fail "watchdog: invalid WATCH_INTERVAL"
[[ "$WATCH_INBOUND_MBPS" =~ ^[0-9]+$ ]] || fail "watchdog: invalid WATCH_INBOUND_MBPS"
[[ "$WATCH_INBOUND_PPS" =~ ^[0-9]+$ ]] || fail "watchdog: invalid WATCH_INBOUND_PPS"
[[ "$WATCH_COOLDOWN" =~ ^[0-9]+$ ]] || fail "watchdog: invalid WATCH_COOLDOWN"

if [[ -z "$WATCH_IFACE" ]] && command -v ip >/dev/null 2>&1; then
    WATCH_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
fi
: "${WATCH_IFACE:=eth0}"

read_counters() {
    local line name rest
    while IFS= read -r line; do
        [[ "$line" == *:* ]] || continue
        name="${line%%:*}"
        name="${name//[[:space:]]/}"
        [[ "$name" == "$1" ]] || continue
        rest="${line#*:}"
        set -- $rest
        printf '%s %s\n' "$1" "$2"
        return 0
    done < "$NET_DEV"
    return 1
}

notify() {
    [[ -n "$WATCH_WEBHOOK" ]] || return 0
    curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
        --data "$(printf '{"text":"%s"}' "$1")" "$WATCH_WEBHOOK" >/dev/null 2>&1 || true
}

ensure_services() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet haproxy || systemctl restart haproxy || true
        systemctl is-active --quiet vipproxy-geo.timer || systemctl start vipproxy-geo.timer || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -j VIPPROXY_SCRUB 2>/dev/null || "$ANTI_DDOS_BIN" 2>/dev/null || true
    fi
}

printf '%s\n' "watchdog: iface=${WATCH_IFACE} limit=${WATCH_INBOUND_MBPS}Mbps/${WATCH_INBOUND_PPS}pps interval=${WATCH_INTERVAL}s"

cycles=0
calm=0
attack=false
prev_bytes=""
prev_packets=""
mbps=0
pps=0

while :; do
    counters=$(read_counters "$WATCH_IFACE" 2>/dev/null || true)
    if [[ -n "$counters" ]]; then
        read -r bytes packets <<< "$counters"
        if [[ -n "$prev_bytes" ]] && (( bytes >= prev_bytes )) && (( packets >= prev_packets )); then
            mbps=$(( (bytes - prev_bytes) * 8 / WATCH_INTERVAL / 1000000 ))
            pps=$(( (packets - prev_packets) / WATCH_INTERVAL ))
            if (( mbps >= WATCH_INBOUND_MBPS || pps >= WATCH_INBOUND_PPS )); then
                calm=0
                if [[ "$attack" != true ]]; then
                    attack=true
                    printf '%s\n' "attack: ${mbps}Mbps ${pps}pps on ${WATCH_IFACE}"
                    notify "attack: ${mbps}Mbps ${pps}pps on ${WATCH_IFACE}"
                    if [[ -n "$WATCH_MITIGATION_CMD" ]]; then
                        bash -c "$WATCH_MITIGATION_CMD" >/dev/null 2>&1 || true
                    fi
                    ensure_services
                elif (( cycles % 30 == 0 )); then
                    printf '%s\n' "attack ongoing: ${mbps}Mbps ${pps}pps on ${WATCH_IFACE}"
                fi
            elif [[ "$attack" == true ]]; then
                calm=$((calm + 1))
                if (( calm >= WATCH_COOLDOWN )); then
                    attack=false
                    printf '%s\n' "normal: ${mbps}Mbps ${pps}pps on ${WATCH_IFACE}"
                    notify "normal: ${mbps}Mbps ${pps}pps on ${WATCH_IFACE}"
                fi
            fi
        fi
        prev_bytes=$bytes
        prev_packets=$packets
    fi
    cycles=$((cycles + 1))
    if (( WATCH_MAX_CYCLES > 0 && cycles >= WATCH_MAX_CYCLES )); then
        break
    fi
    sleep "$WATCH_INTERVAL"
done
