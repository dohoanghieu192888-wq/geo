# VIPProxy

Reverse proxy cho Ubuntu 24.04/26.04 x86_64 dùng HAProxy, UFW, ipset và iptables.

## Cài đặt nhanh (Giao diện nhập tay)

Chỉ cần chạy lệnh sau, hệ thống sẽ hiện từng dòng để bạn nhập IP và Port:

```bash
chmod +x setup.sh install.sh update-geo.sh anti-ddos.sh
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
chmod +x install.sh update-geo.sh anti-ddos.sh
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

Geo chỉ nằm trong `update-geo.sh`. Phần chống tấn công nằm ở `anti-ddos.sh` (kernel) và `install.sh` (HAProxy, sysctl, UFW).

SSH không bị geo-filter để tránh khóa quản trị. Có thể giới hạn SSH bằng:

```env
ADMIN_CIDR=1.2.3.4/32
```

Tắt geo-filter:

```env
GEO_ENABLE=false
```

## Chống bot và DDoS nâng cao (4 tầng bảo vệ)

Hệ thống được thiết kế theo mô hình 4 tầng phòng thủ. Lớp kernel nằm trong `anti-ddos.sh`, lớp HAProxy/sysctl/UFW nằm trong `install.sh`, geo nằm riêng trong `update-geo.sh`. Không có ban IP: mọi thứ chỉ drop theo gói và kết nối.

1. **Tầng 1 - Kernel Linux (sysctl)**:
   - `tcp_syncookies=1`, `tcp_max_syn_backlog=65535`, `somaxconn=65535`, `netdev_max_backlog=250000`, `netdev_budget=600`: giữ hàng đợi kết nối và softirq không bị tê liệt khi bị SYN flood hoặc packet flood.
   - `tcp_synack_retries=2`, `tcp_fin_timeout=15`, `tcp_tw_reuse=1`, timeout conntrack ngắn: giải phóng socket và entry state nhanh, tránh cạn kiệt tài nguyên.
   - `nf_conntrack_max=1048576` + `nf_conntrack_buckets=262144`: bảng state lớn, tra cứu ít va chạm. `CONNTRACK_TCP_LOOSE=0` (mặc định) chỉ nhận diện kết nối TCP bắt đầu bằng SYN, chặn ACK/RST flood tạo entry rác.
   - `LimitNOFILE=1048576`, `Restart=always`, BBR + `fq`, buffer 16 MB: HAProxy không chết vì "Too many open files", tự dựng lại và không rơi gói khi lưu lượng tăng.

2. **Tầng 2 - Kernel Anti-Scan (`anti-ddos.sh`)**:
   - Chain `VIPPROXY_RAW` chạy **trước conntrack**: drop fragment, TCP NULL/XMAS/SYN-FIN/SYN-RST/FIN-RST/FIN-không-ACK, source port 0; drop SYN tới cổng không có trong whitelist; drop UDP không phải reply DNS/NTP/DHCP hoặc cổng `ALLOW_UDP_PORTS`.
   - Chain `VIPPROXY_SCRUB`: drop gói lỗi, NEW không có SYN, giới hạn ICMP echo 10 gói/giây, whitelist cổng TCP, drop UDP còn lại.
   - `ipset vipproxy_ports`: whitelist cổng hợp lệ (web, game, SSH). Mọi gói TCP tới cổng khác bị drop, scanner không nhận được phản hồi nào.
   - Không giới hạn số kết nối hay tốc độ kết nối TCP theo IP. TCP được bảo vệ bằng lọc gói stateless, `SYNPROXY_PORT` và giới hạn tổng `maxconn` của HAProxy.
   - `SYNPROXY_PORT` (tuỳ chọn): kernel tự trả lời bắt tay SYN cho cổng đó, SYN flood giả nguồn không chiếm socket HAProxy.
   - `ipset vipproxy_geo`: Lọc IP Việt Nam ở cấp độ kernel với tốc độ tra cứu O(1), drop toàn bộ IP ngoại quốc trước khi gói tin tới HAProxy.

3. **Tầng 3 - HAProxy Layer 4 (Web + Game TCP)**:
   - HTTP dùng stick-table 500.000 IP để theo dõi `http_req_rate(10s)` và `http_err_rate(10s)`; game TCP không có stick-table, không giới hạn theo IP.
   - Không còn bảng `abuse`/`web_conn`, không kiểm tra `conn_cur` hay `conn_rate`: người chơi sau NAT/CGNAT không bị chặn oan.
   - `MAX_HTTP_CONN` và `MAX_GAME_CONN` chỉ là giới hạn tổng của HAProxy, không phải giới hạn theo IP.
   - `nbthread` bằng số CPU (tối đa 8), `tcp-smart-accept`/`tcp-smart-connect` và `timeout queue 15s`: xử lý nhiều kết nối hơn, ít syscall hơn, request vào hàng đợi quá lâu bị trả lỗi thay vì treo.

4. **Tầng 4 - HAProxy Layer 7 (Website HTTP & Anti-Reconnaissance)**:
   - **Xóa sạch Server Banner**: Xóa `Server`, `X-Powered-By`, `X-AspNet-Version`, `X-Varnish`, `Via`, `X-Cache`, `X-Backend-Server`, `X-Runtime`, `X-Debug-Token` để công cụ dò quét không thể nhận diện phần mềm hay proxy.
   - **Kiểm soát HTTP Method**: Chỉ cho phép các phương thức chuẩn (`GET`, `HEAD`, `POST`, `PUT`, `DELETE`, `OPTIONS`). Mọi method rác do toolkit quét đều bị `silent-drop` ngay lập tức.
   - **Bắt buộc Host Header**: Tự động drop các request không có Host header hoặc có nhiều Host header.
   - **Chống Bot Scanner**: Chặn các công cụ quét tự động (`c2-enum`, `nuclei`, `httpx`, `gobuster`, `dirbuster`, `ffuf`, `feroxbuster`, `wfuzz`, `nmap`, `sqlmap`, `nikto`, `wpscan`, `masscan`, `zgrab`, `censys`, `fwdns`, `zmap`...).
   - **Chống Brute-force / Path Flood**: Theo dõi `http_err_rate(10s)`, ngắt kết nối nếu IP vượt `HTTP_ERR_RATE_LIMIT` lỗi (mặc định 15 lỗi/10 giây).
   - **Chống Slowloris**: Timeout nhận request 5s, timeout client-fin 2s, request được buffer toàn bộ trước khi chuyển backend.
   - **Chặn dò path**: các đường dẫn recon phổ biến (`.env`, `.git`, `wp-login.php`, `phpmyadmin`, `cgi-bin`, `actuator`, `server-status`, `/etc/passwd`, `/vendor/phpunit`, `/_ignition`...) và path traversal `/../`, `%00` bị `silent-drop`.
   - **Chặn header/body bất thường**: nhiều `Content-Length`, Host dài quá 253 ký tự, User-Agent dài quá 512, Cookie dài quá 8 KB, Referer dài quá 2 KB, path dài quá 1024, body quá 20 MB đều bị drop.
   - **Host whitelist (tuỳ chọn)**: đặt `ALLOWED_HOSTS=example.com,www.example.com` thì request mang Host khác bị drop thẳng.

```env
HTTP_RATE_LIMIT=0
HTTP_ERR_RATE_LIMIT=15
ALLOWED_HOSTS=
MAX_HTTP_CONN=4000
MAX_GAME_CONN=20000
SYNPROXY_PORT=
CONNTRACK_TCP_LOOSE=0
UDP_REPLY_PORTS=53,123,67,68
ALLOW_UDP_PORTS=
WAF_TRUSTED_CIDRS=
WAF_REAL_IP_HEADER=X-Real-IP
```

`HTTP_RATE_LIMIT` là số request mỗi IP trong 10 giây. `HTTP_ERR_RATE_LIMIT` là số lỗi HTTP mỗi IP trong 10 giây (`0` = tắt). Giá trị **`0` = tắt giới hạn theo IP** — cần khi nhiều người dùng chung một IP public (quán net, CGNAT 4G). Các lớp khác vẫn bật: geo-filter, whitelist cổng ở kernel, syncookies, TCP backlog, chặn method/Host/path/UA.

Không có giới hạn số kết nối TCP đồng thời hoặc tốc độ kết nối TCP theo IP. `MAX_HTTP_CONN`/`MAX_GAME_CONN` là tổng năng lực của HAProxy, không chặn theo IP.

`CONNTRACK_TCP_LOOSE=0` là chế độ chặt: chỉ kết nối bắt đầu bằng SYN mới được conntrack nhận. Đặt `1` nếu VPS có routing bất đối xứng hoặc bạn reload firewall làm mất state của các kết nối đang chạy. Khi bật `SYNPROXY_PORT`, script tự ép giá trị này về `0`.

Proxy này chỉ chuyển tiếp TCP. `UDP_REPLY_PORTS` chỉ cho phép UDP reply từ DNS/NTP/DHCP (mặc định `53,123,67,68`) và giới hạn 1000 gói/giây để một flood giả source port không thể đổ vào conntrack; mọi UDP khác bị drop trước conntrack. Nếu có dịch vụ UDP riêng, thêm cổng vào `ALLOW_UDP_PORTS`. Không thêm cổng game UDP vào đây nếu chưa có forwarder UDP — HAProxy không tự chuyển UDP.

### Cấu hình anti-DDoS mạnh nhất trong giới hạn VPS

Đây là điểm khởi đầu cho môi trường **mỗi IP public là một người dùng** (không dùng chung NAT/quán net). Giảm hoặc đặt `0` nếu người chơi đi qua CGNAT:

```env
HTTP_RATE_LIMIT=100
HTTP_ERR_RATE_LIMIT=10
SYNPROXY_PORT=80
CONNTRACK_TCP_LOOSE=0
```

`SYNPROXY_PORT=80` chỉ nên bật sau khi test kết nối web bình thường. Với game TCP, có thể đổi thành port public của game nhưng phải test kỹ; nếu game có nhiều kết nối ngắn hoặc backend không đối xứng, để trống.

Khi đổi cấu hình, chạy lại:

```bash
sudo ./install.sh config.env
```

## Check-Risk-WAF

Repo công khai của Check-Risk-WAF chỉ có `README.md` và `assets/`, không có mã nguồn. Bản on-premise cài bằng installer riêng, tài liệu yêu cầu Ubuntu Server 24.04 LTS x86_64; bản SaaS chạy trên cloud của nhà cung cấp.

Không nên cài WAF trực tiếp lên VPS Ubuntu 26.04 vừa nâng cấp nếu nhà cung cấp chưa xác nhận hỗ trợ 26.04. Cách an toàn:

```text
Internet -> Check-Risk-WAF (SaaS hoặc VM Ubuntu 24.04 riêng) -> VPS 26.04:80 (HAProxy) -> backend
```

Trên VPS, khóa origin để port 80 chỉ nhận từ WAF:

```env
WAF_TRUSTED_CIDRS=203.0.113.10/32
WAF_REAL_IP_HEADER=X-Real-IP
```

- `WAF_TRUSTED_CIDRS`: IP/CIDR IPv4 của WAF, cách nhau bằng dấu phẩy. Khi có giá trị, `anti-ddos.sh` tạo ipset `vipproxy_waf` và drop mọi kết nối port 80 không đến từ WAF; UFW cũng chỉ mở port 80 cho các CIDR này.
- `WAF_REAL_IP_HEADER`: header WAF dùng để gửi IP người dùng thật. HAProxy chỉ tin header này khi kết nối đến từ `WAF_TRUSTED_CIDRS`, rồi dùng IP đó cho log và `HTTP_RATE_LIMIT`.
- Cấu hình WAF ghi đè header bằng IP thật, không forward giá trị do client gửi.
- Nếu dùng SaaS, lấy dải IP egress do nhà cung cấp công bố. Nếu IP thay đổi, cập nhật `WAF_TRUSTED_CIDRS` và chạy lại `sudo ./install.sh config.env`.
- WAF không bảo vệ game TCP trừ khi nó proxy được TCP; game vẫn đi trực tiếp vào VPS.

Chi tiết cài WAF on-prem và kiểm tra: [CHECK-RISK-WAF.md](CHECK-RISK-WAF.md).

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
sudo ipset list vipproxy_waf
sudo iptables -t raw -S VIPPROXY_RAW
sudo iptables -t raw -S VIPPROXY_RAW | grep vipproxy_waf
sudo iptables -S VIPPROXY_SCRUB
sudo systemctl status vipproxy-anti-ddos
sudo iptables -S INPUT | grep vipproxy_geo
sudo sysctl net.netfilter.nf_conntrack_tcp_loose
sudo sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
sudo ufw status verbose
```

## Giới hạn thực tế

Bộ này chống bot ở lớp IP, request HTTP và gói TCP. Nó không thể chặn DDoS volumetric lớn nếu băng thông VPS đã bị làm đầy trước khi gói tin tới máy.

### Chịu được 100 Gbps không?

Không. Đây là giới hạn vật lý của đường truyền, không phải giới hạn của script.

- VPS uplink 1 Gbps: tấn công 100 Gbps làm nghẽn ngay tại router/switch của nhà cung cấp. Gói tin không bao giờ tới kernel, nên mọi cấu hình trong repo này không có tác dụng.
- VPS uplink 10 Gbps: 100 Gbps vẫn vượt 10 lần, kết quả tương tự.
- Muốn chịu 100 Gbps phải chặn ở upstream: Cloudflare Spectrum (TCP game), dịch vụ scrubbing/anycast, anti-DDoS của nhà cung cấp (OVH VAC/Game, VNPT, Viettel, Vietnix...), hoặc nhiều proxy anycast phân tán.
- `watchdog.sh` có thể gọi `WATCH_MITIGATION_CMD` để bật mitigation upstream hoặc đổi DNS sang IP dự phòng, nhưng nó không tạo thêm băng thông.

Phần repo này làm được là giữ CPU, conntrack và socket không sập khi lưu lượng **vẫn nằm trong băng thông VPS**: drop SYN/cổng lạ/UDP rác ở bảng `raw` trước conntrack, SYNPROXY tuỳ chọn, `CONNTRACK_TCP_LOOSE=0`, không giới hạn TCP theo IP, khóa origin bằng `WAF_TRUSTED_CIDRS`, RPS chia softirq đều cho các core, conntrack 1 triệu entry với 262144 bucket, HAProxy đa luồng và stick-table HTTP.

Nói ngắn gọn: **100 Gbps phải mua ở upstream; trong VPS chỉ tối ưu được đến mức đường truyền cho phép.**

### SYNPROXY (tuỳ chọn, mặc định tắt)

```env
SYNPROXY_PORT=80
```

Kernel tự trả lời bắt tay SYN cho cổng đó nên SYN flood giả nguồn không chiếm được socket của HAProxy. Chỉ bật sau khi đã thử trên máy test: nó đặt `NOTRACK` cho cổng này và bắt buộc `net.netfilter.nf_conntrack_tcp_loose=0`. Script tự ép giá trị này khi `SYNPROXY_PORT` được đặt; sai cấu hình có thể làm rớt kết nối thật. `SYNPROXY_PORT` phải là port web hoặc một port game public.

Trên Ubuntu 24.04/26.04, `iptables` mặc định dùng backend nft và có thể không hỗ trợ target `SYNPROXY` của xtables. `anti-ddos.sh` tự kiểm tra; nếu không hỗ trợ, script in cảnh báo và tắt SYNPROXY để tránh làm rớt kết nối. Khi đó `tcp_syncookies=1`, backlog lớn và lọc gói ở bảng `raw` vẫn hoạt động.

### Watchdog và cảnh báo

`watchdog.sh` chạy nền (`vipproxy-watchdog.service`), đọc `/proc/net/dev` và bộ đếm conntrack mỗi `WATCH_INTERVAL` giây:

```env
WATCH_INBOUND_MBPS=300
WATCH_INBOUND_PPS=300000
WATCH_CONNTRACK_PCT=85
WATCH_COOLDOWN=3
WATCH_WEBHOOK=
WATCH_MITIGATION_CMD=
```

Khi vượt ngưỡng băng thông, PPS hoặc conntrack đầy 85%, watchdog ghi log, gửi JSON `{"text":"..."}` tới `WATCH_WEBHOOK` (Slack, Discord hoặc endpoint tự viết), chạy `WATCH_MITIGATION_CMD` nếu có, rồi tự kiểm tra: HAProxy chết thì restart, chain `VIPPROXY_SCRUB` mất thì áp lại. Khi `WATCH_COOLDOWN` lần liên tiếp dưới ngưỡng thì báo `normal`. Đặt `WATCH_CONNTRACK_PCT=0` để tắt riêng ngưỡng conntrack.

`WATCH_MITIGATION_CMD` là chỗ nối với upstream: đặt lệnh gọi API nhà cung cấp (bật mitigation, đổi DNS sang IP dự phòng...) — watchdog chỉ gọi khi phát hiện tấn công, không gọi lặp lại mỗi chu kỳ.

```bash
sudo journalctl -u vipproxy-watchdog -f
sudo systemctl status vipproxy-watchdog
```

Bộ hiện tại hỗ trợ HTTP và TCP. Game chỉ chạy UDP chưa được hỗ trợ. HTTPS chưa bật.

### XDP-Firewall có dùng được không?

`xdp-firewall-master/` là dự án C/eBPF độc lập (MIT), không được installer tích hợp. Trên Ubuntu 26.04, giới hạn kernel cũ không còn là trở ngại lớn, nhưng vẫn có các điểm cần lưu ý:

- Bản trong repo chưa build được ngay: submodule `modules/xdp-tools` rỗng, cần `git submodule update --init` và mạng.
- Cần clang/llvm, `libconfig-dev`, `libelf-dev`, `libpcap-dev`, `m4`, `gcc-multilib`, `bpftool`/`linux-tools`.
- Kernel 26.04 đủ mới cho `bpf_loop` và `USE_NEW_LOOP`.
- XDP native (DRV) phụ thuộc NIC/driver của VPS. Nếu không hỗ trợ, chương trình rơi về SKB mode, chậm hơn nhưng vẫn chạy trước iptables.
- `config.h` mặc định bật `ENABLE_RL_FLOW` (giới hạn luồng TCP/UDP), trái với yêu cầu không giới hạn TCP; phải tắt.
- Chỉ nên dùng như lớp chặn IP/port bổ sung, không thay thế `anti-ddos.sh`, và phải test kỹ vì XDP drop trước conntrack có thể chặn nhầm.

Kết luận: có thể thử trên Ubuntu 26.04, nhưng không đưa vào mặc định. Build đầy đủ, tắt `ENABLE_RL_FLOW`, chỉ dùng block map/port allowlist, và giữ `anti-ddos.sh` làm lớp chính.
