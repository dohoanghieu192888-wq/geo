#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$ROOT_DIR/config.env"
umask 077

valid_ipv4() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 ))
}

valid_cidr() {
    local ip prefix
    [[ "$1" == "any" ]] && return 0
    [[ "$1" == */* ]] || return 1
    ip="${1%/*}"
    prefix="${1##*/}"
    valid_ipv4 "$ip" && [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && (( 10#$prefix >= 1 && 10#$prefix <= 32 ))
}

ask_value() {
    local label="$1" default="${2:-}"
    if [[ -n "$default" ]]; then
        read -r -p "$label [$default]: " REPLY
        REPLY="${REPLY:-$default}"
    else
        read -r -p "$label: " REPLY
    fi
}

ask_ipv4() {
    while true; do
        ask_value "$1"
        valid_ipv4 "$REPLY" && return 0
        echo "IP khong hop le. Vi du: 192.168.1.100"
    done
}

ask_port() {
    local label="$1" default="${2:-}"
    while true; do
        ask_value "$label" "$default"
        valid_port "$REPLY" && return 0
        echo "Port phai la so tu 1 den 65535."
    done
}

ask_yes_no() {
    local label="$1" default="$2"
    while true; do
        ask_value "$label (y/n)" "$default"
        case "$REPLY" in
            y|Y|n|N) return 0 ;;
            *) echo "Vui long nhap y hoac n." ;;
        esac
    done
}

ask_waf() {
    local item ok
    local -a items
    while true; do
        ask_value "IP WAF Check-Risk (rong = tat)" ""
        [[ -z "$REPLY" ]] && { waf_cidrs=""; return 0; }
        waf_cidrs=""
        ok=true
        IFS=',' read -r -a items <<< "$REPLY"
        for item in "${items[@]}"; do
            [[ "$item" == */* ]] || item="$item/32"
            if valid_cidr "$item"; then
                waf_cidrs="${waf_cidrs:+$waf_cidrs,}$item"
            else
                ok=false
                break
            fi
        done
        [[ "$ok" == true ]] && return 0
        echo "IP/CIDR khong hop le."
    done
}

[[ $EUID -eq 0 ]] || { echo "Vui long chay: sudo ./setup.sh" >&2; exit 1; }

echo "========== VIPPROXY: CAU HINH IP VA PORT =========="
echo "Website luon public tai port 80 cua VPS."
ask_ipv4 "IP server web that"
web_ip="$REPLY"
ask_port "Port server web that" 80
web_port="$REPLY"

GAME_RULES=""
declare -A used_ports=([80]=1)
while true; do
    ask_yes_no "Them server game TCP?" n
    [[ "$REPLY" =~ ^[nN]$ ]] && break
    ask_ipv4 "IP server game that"
    game_ip="$REPLY"
    ask_port "Port server game that"
    game_backend_port="$REPLY"
    while true; do
        ask_port "Port game public tren VPS"
        game_public_port="$REPLY"
        if [[ -n "${used_ports[$game_public_port]+x}" ]]; then
            echo "Port $game_public_port da duoc dung. Hay chon port khac."
        else
            used_ports["$game_public_port"]=1
            break
        fi
    done
    rule="$game_public_port:$game_ip:$game_backend_port"
    GAME_RULES="${GAME_RULES:+$GAME_RULES,}$rule"
    echo "Da them: VPS:$game_public_port -> $game_ip:$game_backend_port"
done

while true; do
    ask_port "Port SSH dang su dung tren VPS" 22
    ssh_port="$REPLY"
    if [[ -z "${used_ports[$ssh_port]+x}" ]]; then
        break
    fi
    echo "Port SSH khong duoc trung port web/game."
done

while true; do
    ask_value "IP quan tri SSH (any hoac IP/32)" any
    admin_cidr="$REPLY"
    valid_cidr "$admin_cidr" && break
    echo "CIDR khong hop le. Vi du: 113.160.10.20/32"
done

ask_yes_no "Chi cho IP Viet Nam truy cap web/game?" y
if [[ "$REPLY" =~ ^[yY]$ ]]; then geo_enable=true; else geo_enable=false; fi
ask_waf

echo ""
echo "Web: VPS:80 -> $web_ip:$web_port"
echo "Game: ${GAME_RULES:-khong co}"
echo "SSH: $ssh_port, Admin: $admin_cidr, Chi VN: $geo_enable"
echo "WAF: ${waf_cidrs:-tat}"
ask_yes_no "Xac nhan luu cau hinh va cai dat?" n
[[ "$REPLY" =~ ^[yY]$ ]] || { echo "Da huy, khong thay doi cau hinh."; exit 0; }

if [[ -f "$CONFIG_FILE" ]]; then
    cp -p "$CONFIG_FILE" "$CONFIG_FILE.bak"
fi
cat > "$CONFIG_FILE" <<EOF
PUBLIC_HTTP_PORT=80
WEB_BACKEND=$web_ip:$web_port
GAME_RULES=$GAME_RULES
SSH_PORT=$ssh_port
ADMIN_CIDR=$admin_cidr
UFW_ENABLE=true
MAX_HTTP_CONN=4000
MAX_GAME_CONN=20000
GEO_ENABLE=$geo_enable
GEO_COUNTRY=vn
CONNTRACK_TCP_LOOSE=0
UDP_REPLY_PORTS=53,123,67,68
ALLOW_UDP_PORTS=
WAF_TRUSTED_CIDRS=$waf_cidrs
WAF_REAL_IP_HEADER=X-Real-IP
EOF

printf 'Da luu %s. Dang cai dat...\n' "$CONFIG_FILE"
bash "$ROOT_DIR/install.sh" "$CONFIG_FILE"
