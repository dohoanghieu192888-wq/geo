# Check-Risk-WAF

## Trạng thái tích hợp

Check-Risk-WAF là sản phẩm thương mại, repo công khai chỉ có `README.md` và `assets/`, không có mã nguồn để nhúng vào repo này.

- **SaaS**: dùng cloud của Check Risk, không cần cài trên VPS.
- **On-premise**: cài bằng installer riêng, tài liệu yêu cầu Ubuntu Server 24.04 LTS x86_64.
- **VPS hiện tại**: Ubuntu 26.04. Không cài WAF trực tiếp lên VPS này nếu nhà cung cấp chưa xác nhận hỗ trợ 26.04; dùng SaaS hoặc một VM Ubuntu 24.04 riêng.

Repo này tích hợp ở lớp origin: khóa port 80 chỉ nhận kết nối từ WAF và lấy IP người dùng thật từ header do WAF gửi.

## Mô hình

```text
Internet
   |
   v
Check-Risk-WAF (SaaS hoặc VM Ubuntu 24.04)
   |
   v
VPS Ubuntu 26.04 :80 (HAProxy)
   |
   v
Web backend
```

Game TCP đi trực tiếp vào VPS. WAF chỉ bảo vệ HTTP trừ khi nó được cấu hình proxy TCP cho game.

## Cài WAF on-premise

Chỉ làm trên host Ubuntu 24.04 riêng, không làm trên VPS origin 26.04.

1. Cài Ubuntu Server 24.04 LTS x86_64.
2. Mở port quản trị và port HTTP/HTTPS theo tài liệu Check Risk.
3. Tải installer từ trang chính thức:

```bash
curl -fLO https://check-risk.ru/cr-waf_install.tar.gz
```

4. Kiểm tra checksum/chữ ký nếu nhà cung cấp công bố.
5. Giải nén và chạy installer theo hướng dẫn chính thức:

```bash
tar -xzf cr-waf_install.tar.gz
cd cr-waf_install
sudo ./installer --lang=ru
```

6. Trong giao diện WAF, tạo upstream trỏ tới `IP_VPS_ORIGIN:80`.
7. Bật gửi IP người dùng thật bằng header `X-Real-IP: <client_ip>`. Repo này không bật PROXY protocol; nếu WAF chỉ hỗ trợ PROXY protocol thì phải thêm `accept-proxy` vào HAProxy trước.
8. Cấu hình WAF ghi đè `X-Real-IP`, không forward giá trị do client gửi.
9. Nếu dùng HTTPS ở WAF, chứng chỉ và DNS trỏ về WAF, không trỏ về VPS origin.

## Cấu hình origin

Trên VPS, sửa `config.env`:

```env
WAF_TRUSTED_CIDRS=203.0.113.10/32
WAF_REAL_IP_HEADER=X-Real-IP
```

Nhiều IP thì ngăn bằng dấu phẩy:

```env
WAF_TRUSTED_CIDRS=203.0.113.10/32,198.51.100.0/24
```

Chạy lại:

```bash
sudo ./install.sh config.env
```

Khi `WAF_TRUSTED_CIDRS` có giá trị:

- `anti-ddos.sh` tạo ipset `vipproxy_waf`.
- Chain `VIPPROXY_RAW` và `VIPPROXY_SCRUB` drop mọi kết nối TCP port 80 không đến từ các CIDR này.
- UFW chỉ mở port 80 cho các CIDR này.
- HAProxy chỉ tin `WAF_REAL_IP_HEADER` khi kết nối đến từ WAF, sau đó dùng IP thật cho log và `HTTP_RATE_LIMIT`.
- Game TCP, SSH và geo-filter không bị ảnh hưởng.

## Kiểm tra

Từ máy không phải WAF:

```bash
curl -m 5 -I http://IP_VPS_ORIGIN
```

Kết quả mong đợi: timeout hoặc không kết nối được.

Từ WAF hoặc qua domain:

```bash
curl -m 10 -I https://example.com
```

Kết quả mong đợi: HTTP 200/301/302 từ backend.

Trên VPS:

```bash
sudo ipset list vipproxy_waf
sudo iptables -t raw -S VIPPROXY_RAW | grep vipproxy_waf
sudo ufw status verbose
sudo journalctl -u haproxy -n 50
```

## Lưu ý

- `WAF_TRUSTED_CIDRS` chỉ hỗ trợ IPv4.
- Nếu IP WAF thay đổi, cập nhật cấu hình và chạy lại `install.sh`; nếu không port 80 sẽ bị khóa.
- Không đặt `WAF_TRUSTED_CIDRS` bằng dải quá rộng như `0.0.0.0/0`, vì sẽ mất tác dụng khóa origin.
- WAF không thay thế scrubbing upstream. Tấn công 100 Gbps vẫn phải chặn ở nhà cung cấp/anycast trước khi tới WAF hoặc VPS.
- Không trỏ DNS trực tiếp về IP backend; chỉ trỏ về WAF.
