# VIPProxy

Reverse proxy cho Ubuntu 20.04 x86_64 dùng HAProxy, UFW, ipset và iptables.

## Cài đặt nhanh (Giao diện nhập tay)

Chỉ cần chạy lệnh sau, hệ thống sẽ hiện từng dòng để bạn nhập IP và Port:

```bash
chmod +x setup.sh install.sh update-geo.sh
sudo ./setup.sh
```

## Cài đặt thủ công (Qua file cấu hình)

```bash
cp config.env.example config.env
nano config.env
chmod +x install.sh update-geo.sh
sudo ./install.sh config.env
```

`WEB_BACKEND` có dạng `IP:PORT` (ví dụ `10.0.0.10:80` hoặc IP Windows tùy chọn). Bạn vẫn có thể dùng cặp `WEB_BACKEND_IP` và `WEB_BACKEND_PORT` cũ.

`GAME_RULES` có dạng:

```text
public_port:backend_ip:backend_port,public_port:backend_ip:backend_port
```

Ví dụ:

```text
25565:10.0.0.20:25565,27015:10.0.0.21:27015
```

Website public tại port 80. Mỗi rule game mở một TCP port trên VPS và chuyển tiếp đến backend tương ứng.

## Geo-filter Việt Nam

```env
GEO_ENABLE=true
GEO_COUNTRY=vn
```

Khi bật, HTTP và TCP game chỉ nhận IP thuộc CIDR Việt Nam. iptables drop IP ngoài Việt Nam trước HAProxy, còn HAProxy có lớp ACL dự phòng. Danh sách được tải từ IPdeny lúc cài đặt và cập nhật tự động sau boot, sau đó mỗi 12 giờ.

SSH không bị geo-filter để tránh khóa quản trị. Có thể giới hạn SSH bằng:

```env
ADMIN_CIDR=1.2.3.4/32
```

Tắt geo-filter:

```env
GEO_ENABLE=false
```

## Chống bot và DDoS cơ bản

```env
HTTP_RATE_LIMIT=120
GAME_CONN_RATE_LIMIT=30
HTTP_MAX_CONN_PER_IP=80
GAME_MAX_CONN_PER_IP=20
MAX_HTTP_CONN=4000
MAX_GAME_CONN=20000
```

`HTTP_RATE_LIMIT` là số request mỗi IP trong 10 giây. `GAME_CONN_RATE_LIMIT` là số kết nối TCP mỗi IP trong 10 giây. Các giới hạn này kết hợp với geo-filter, ipset, UFW, syncookies, TCP backlog và giới hạn kết nối HAProxy.

`HTTP_MAX_CONN_PER_IP` giới hạn kết nối HTTP đồng thời của một IP. `GAME_MAX_CONN_PER_IP` giới hạn kết nối game đồng thời của một IP.

Khi đổi cấu hình, chạy lại:

```bash
sudo ./install.sh config.env
```

## DNS

Tạo bản ghi A của domain trỏ đến IP public của VPS proxy:

```text
example.com A IP_VPS_PROXY
```

Không trỏ domain đến IP backend.

## Khóa IP backend

Trên máy web và máy game, chỉ cho phép kết nối từ IP public của VPS proxy ở các port backend. Không mở trực tiếp backend cho Internet nếu muốn ẩn IP thật.

## Kiểm tra

```bash
curl -I http://IP_VPS_PROXY
sudo ss -lntp | grep haproxy
sudo systemctl status haproxy
sudo systemctl status vipproxy-geo.timer
sudo ipset list vipproxy_geo | head
sudo iptables -S INPUT | grep vipproxy_geo
sudo ufw status verbose
```

## Giới hạn thực tế

Bộ này chống bot ở lớp IP, request và kết nối TCP. Nó không thể chặn DDoS volumetric lớn nếu băng thông VPS đã bị làm đầy trước khi gói tin tới máy. Với botnet phân tán hoặc tấn công L3/L4 lớn cần anti-DDoS upstream từ nhà cung cấp VPS, CDN hoặc dịch vụ scrubbing.

Bộ hiện tại hỗ trợ HTTP và TCP. Game chỉ chạy UDP chưa được hỗ trợ. HTTPS chưa bật.
