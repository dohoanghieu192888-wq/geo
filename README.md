# VIPProxy

Reverse proxy cho Ubuntu 20.04 x86_64 dùng HAProxy, UFW, ipset và iptables.

## Cài đặt nhanh (Giao diện nhập tay)

Chỉ cần chạy lệnh sau, hệ thống sẽ hiện từng dòng để bạn nhập IP và Port:

```bash
chmod +x setup.sh install.sh update-geo.sh
sudo ./setup.sh
```

Script hỏi lần lượt IP web, port web; mỗi server game hỏi IP thật, port thật, rồi port public trên VPS. Nhập thêm server game bằng `y`, kết thúc bằng `n`. Không cần tự ghép chuỗi `GAME_RULES`. Nếu nhập IP vào ô port, script sẽ báo lỗi và hỏi lại trước khi cài gói. Cấu hình cũ được sao lưu thành `config.env.bak` khi xác nhận cài lại.

Nếu VPS đang dùng phiên bản cũ và báo `Invalid game public port`, cập nhật rồi chạy lại:

```bash
cd /opt/geo_anti
git pull --ff-only
sudo bash setup.sh
```

Ví dụ: web thật `160.22.107.22` port `80`, game thật `160.22.107.22` port `25565`, port game public trên VPS `25565`. **Không nhập IP vào ô port.**

IP backend phải là IP của **máy web/game thật**, không phải IP của chính VPS proxy nếu cùng port, vì sẽ tạo vòng lặp chuyển tiếp.

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

## Chống bot và DDoS nâng cao (4 tầng bảo vệ)

Hệ thống được thiết kế theo mô hình 4 tầng phòng thủ:

1. **Tầng 1 - Kernel Linux (sysctl)**:
   - `tcp_syncookies=1`, `tcp_max_syn_backlog=65535`, `somaxconn=65535`, `netdev_max_backlog=65535`: Chống tê liệt hàng đợi kết nối khi bị SYN flood.
   - `tcp_synack_retries=2`, `tcp_fin_timeout=15`, `tcp_tw_reuse=1`: Giải phóng socket nhanh, tái sử dụng cổng, ngăn chặn cạn kiệt tài nguyên mạng.
   - `LimitNOFILE=1048576` cho HAProxy: Ngăn chặn lỗi "Too many open files" khi lượng kết nối tăng vọt.

2. **Tầng 2 - Kernel Packet Scrubbing & Scan Trap (iptables & ipset)**:
   - Chain `VIPPROXY_SCRUB`: Tự động drop ngay lập tức các gói tin lỗi, quét cổng (TCP NULL, XMAS, SYN-FIN, SYN-RST, fragmented, NEW without SYN).
   - **Port Scan Trap (`SCANNER_TRAP`)**: Tự động phát hiện botnet/công cụ dò cổng (`c2-enum-toolkit`, `nmap`, `masscan`). Nếu một IP quét vào các cổng chưa mở, IP đó sẽ bị đưa vào danh sách đen và **khóa toàn bộ kết nối trong 10 phút**.
   - `ipset vipproxy_geo`: Lọc IP Việt Nam ở cấp độ kernel với tốc độ tra cứu O(1), drop toàn bộ IP ngoại quốc trước khi gói tin tới HAProxy.

3. **Tầng 3 - HAProxy Layer 4 (Server Game TCP)**:
   - Stick-table 500.000 IP: Theo dõi tốc độ mở kết nối (`conn_rate(10s)`) và số kết nối đồng thời (`conn_cur`).
   - Reject ngay các IP vượt ngưỡng kết nối để chống botnet spam socket game.

4. **Tầng 4 - HAProxy Layer 7 (Website HTTP & Anti-Reconnaissance)**:
   - **Xóa sạch Server Banner**: Xóa hoàn toàn các header `Server`, `X-Powered-By`, `X-AspNet-Version` để công cụ dò quét không thể nhận diện phần mềm hay proxy.
   - **Kiểm soát HTTP Method**: Chỉ cho phép các phương thức chuẩn (`GET`, `HEAD`, `POST`, `PUT`, `DELETE`, `OPTIONS`). Mọi method rác do toolkit quét đều bị `silent-drop` ngay lập tức.
   - **Bắt buộc Host Header**: Tự động drop các request không có Host header (đặc trưng của botnet quét tự động theo IP).
   - **Chống Bot Scanner**: Chặn các công cụ quét tự động (`c2-enum`, `nuclei`, `httpx`, `gobuster`, `dirbuster`, `nmap`, `sqlmap`, `nikto`, `wpscan`, `masscan`, `zgrab`, `censys`, `fwdns`).
   - **Chống Brute-force / Path Flood**: Theo dõi `http_err_rate(10s)`, khóa và ngắt kết nối ngay nếu IP tạo ra trên 15 lỗi (dò tìm file, path không tồn tại).
   - **Chống Slowloris**: Timeout nhận request rút ngắn còn 5s, timeout client-fin 2s.

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
