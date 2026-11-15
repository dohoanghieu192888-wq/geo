#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$ROOT_DIR/config.env"

clear
echo "============================================================"
echo "          VIPPROXY - HE THONG SETUP TU DONG               "
echo "============================================================"
echo ""

prompt_default() {
    local prompt="$1"
    local default="$2"
    local answer
    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
}

echo "--- 1. CAU HINH WEBSITE (PORT 80 PUBLIC) ---"
echo "Nhap IP:PORT cua may chu Web that (vi du: 10.0.0.10:80 hoac 192.168.1.100:8080)"
read -r -p "Web Backend (IP:PORT): " web_backend_input
while [[ -z "$web_backend_input" || ! "$web_backend_input" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+$ ]]; do
    echo "Dinh dang khong hop le! Vui long nhap dang IP:PORT (vi du: 1.2.3.4:80)"
    read -r -p "Web Backend (IP:PORT): " web_backend_input
done

echo ""
echo "--- 2. CAU HINH SERVER GAME (TCP PROXY) ---"
echo "Moi quy tac co dang: PORT_PUBLIC:IP_BACKEND:PORT_BACKEND"
echo "Neu nhieu server game, phan cach bang dau phay (,)"
echo "Vi du: 25565:10.0.0.20:25565,27015:10.0.0.21:27015"
echo "Neu khong dung game, co the de trong."
read -r -p "Game Rules: " game_rules_input

echo ""
echo "--- 3. CAU HINH QUAN TRI SSH ---"
ssh_port=$(prompt_default "Port SSH cua VPS" "22")
echo "Chi cho phep IP quan tri SSH (de 'any' neu cho phep moi IP, hoac nhap dang IP/32)"
admin_cidr=$(prompt_default "Admin CIDR" "any")

echo ""
echo "--- 4. CAU HINH ANTI-DDOS & GEO-FILTER ---"
echo "Chi cho phep IP Viet Nam truy cap (Block toan bo quoc gia khac):"
geo_choice=$(prompt_default "Bat Geo-Filter Viet Nam? (y/n)" "y")
if [[ "$geo_choice" =~ ^[yY]$ ]]; then
    geo_enable="true"
else
    geo_enable="false"
fi

http_rate=$(prompt_default "Gioi han request Web/IP trong 10s" "120")
game_rate=$(prompt_default "Gioi han mo ket noi Game/IP trong 10s" "30")
http_max_conn=$(prompt_default "So ket noi Web dong thoi toi da tren 1 IP" "80")
game_max_conn=$(prompt_default "So ket noi Game dong thoi toi da tren 1 IP" "20")

echo ""
echo "============================================================"
echo "                 THONG SO DA CHON                          "
echo "============================================================"
echo "Web Public Port    : 80"
echo "Web Backend        : $web_backend_input"
echo "Game Rules         : ${game_rules_input:-[Khong dung]}"
echo "SSH Port           : $ssh_port"
echo "Admin CIDR         : $admin_cidr"
echo "Geo-filter VN      : $geo_enable"
echo "HTTP Rate Limit    : $http_rate req/10s"
echo "Game Conn Limit    : $game_rate conn/10s"
echo "HTTP Max Conn/IP   : $http_max_conn"
echo "Game Max Conn/IP   : $game_max_conn"
echo "============================================================"

read -r -p "Xac nhan cai dat ngay bay gio? (y/n) [y]: " confirm
confirm="${confirm:-y}"
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Da huy cai dat."
    exit 0
fi

cat > "$CONFIG_FILE" <<EOF
PUBLIC_HTTP_PORT=80
WEB_BACKEND=$web_backend_input
GAME_RULES=$game_rules_input
SSH_PORT=$ssh_port
ADMIN_CIDR=$admin_cidr
UFW_ENABLE=true
MAX_HTTP_CONN=4000
MAX_GAME_CONN=20000
GEO_ENABLE=$geo_enable
GEO_COUNTRY=vn
HTTP_RATE_LIMIT=$http_rate
GAME_CONN_RATE_LIMIT=$game_rate
HTTP_MAX_CONN_PER_IP=$http_max_conn
GAME_MAX_CONN_PER_IP=$game_max_conn
EOF

echo ""
echo "Da luu cau hinh vao $CONFIG_FILE"
echo "Dang tien hanh cai dat he thong qua install.sh..."
chmod +x "$ROOT_DIR/install.sh" "$ROOT_DIR/update-geo.sh"
"$ROOT_DIR/install.sh" "$CONFIG_FILE"
