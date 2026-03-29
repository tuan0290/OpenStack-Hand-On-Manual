# Memcached trong OpenStack

## Memcached là gì?

Memcached là in-memory key-value cache. Trong OpenStack, Memcached dùng để **cache token đã validate** của Keystone, tránh phải query Keystone DB mỗi lần xác thực.

## Vấn đề không có cache

```
Mỗi API request đến Nova:
  1. Nova nhận request kèm token
  2. Nova gửi token đến Keystone để validate
  3. Keystone query MariaDB kiểm tra token
  4. Keystone trả về kết quả
  5. Nova xử lý request

→ Mỗi request = 1 lần query DB Keystone
→ Với hàng nghìn request/giây → DB quá tải
```

## Với Memcached

```
Request lần đầu:
  Nova → Keystone validate → DB query → kết quả → lưu vào Memcached

Request lần 2 (cùng token):
  Nova → Keystone validate → Memcached HIT → trả về ngay
  (không cần query DB)

→ Giảm tải DB đáng kể
→ Latency thấp hơn (~0.1ms vs ~5ms)
```

## Cấu hình trong OpenStack

```ini
# keystone_authtoken section trong mọi service config
[keystone_authtoken]
memcached_servers = controller:11211
```

Mỗi service (Nova, Glance, Neutron...) đều cấu hình Memcached để cache token validation result.

## Tại sao bind ra Management IP?

```
-l 192.168.225.195
```

Tương tự MariaDB - các service trên compute node cần kết nối vào Memcached trên controller qua Management network.

## TTL của cache

Token Fernet có thời hạn 1 giờ. Memcached cache token validation result với TTL ngắn hơn (thường vài phút) để đảm bảo token bị revoke sẽ không còn được cache.

## Debug

```bash
# Kiểm tra Memcached đang chạy
systemctl status memcached

# Xem stats
echo "stats" | nc 192.168.225.195 11211

# Xem số item đang cache
echo "stats" | nc 192.168.225.195 11211 | grep curr_items

# Flush tất cả cache (debug)
echo "flush_all" | nc 192.168.225.195 11211
```

## Lưu ý bảo mật

Memcached không có authentication mặc định. Trong lab bind ra Management IP là chấp nhận được vì Management network là private. Trong production cần:
- Bind chỉ localhost hoặc Management IP
- Dùng SASL authentication
- Hoặc dùng Redis thay thế (có auth, có persistence)
