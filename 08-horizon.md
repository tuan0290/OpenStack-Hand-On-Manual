# Cài đặt Dashboard (Horizon)

> Cài đặt trên node **Controller**

## Mục lục

1. [Cài đặt và cấu hình Horizon](#1-cài-đặt-và-cấu-hình-horizon)
2. [Kết thúc cài đặt](#2-kết-thúc-cài-đặt)
3. [Kiểm tra](#3-kiểm-tra)

---

## 1. Cài đặt và cấu hình Horizon

Cài đặt gói:

```bash
apt install -y openstack-dashboard
```

Sao lưu file cấu hình gốc:

```bash
cp /etc/openstack-dashboard/local_settings.py \
   /etc/openstack-dashboard/local_settings.py.orig
```

Sửa file `/etc/openstack-dashboard/local_settings.py`, tìm và cập nhật các dòng sau:

Cấu hình host controller:

```python
OPENSTACK_HOST = "controller"
```

Cho phép tất cả host truy cập (môi trường lab):

```python
ALLOWED_HOSTS = ['*']
```

Cấu hình Memcached session storage, tìm section `CACHES` và thay thế:

```python
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.PyMemcacheCache',
        'LOCATION': 'controller:11211',
    }
}
```

> Comment out hoặc xóa bất kỳ cấu hình session storage nào khác.

Cấu hình Keystone URL:

```python
OPENSTACK_KEYSTONE_URL = "http://%s:5000/identity/v3" % OPENSTACK_HOST
```

> Lưu ý: Keystone chạy trên port 5000, không phải port 80.

Enable multi-domain support:

```python
OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
```

Cấu hình API versions:

```python
OPENSTACK_API_VERSIONS = {
    "identity": 3,
    "image": 2,
    "volume": 3,
}
```

Cấu hình default domain:

```python
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = "Default"
```

Cấu hình default role:

```python
OPENSTACK_KEYSTONE_DEFAULT_ROLE = "member"
```

Cấu hình timezone (Việt Nam):

```python
TIME_ZONE = "Asia/Ho_Chi_Minh"
```

Kiểm tra file `/etc/apache2/conf-available/openstack-dashboard.conf`, đảm bảo có dòng:

```bash
grep "WSGIApplicationGroup" /etc/apache2/conf-available/openstack-dashboard.conf
```

Nếu chưa có thì thêm vào:

```bash
echo "WSGIApplicationGroup %{GLOBAL}" >> \
  /etc/apache2/conf-available/openstack-dashboard.conf
```

---

## 2. Kết thúc cài đặt

```bash
systemctl reload apache2
```

---

## 3. Kiểm tra

Mở trình duyệt trên máy Windows host, truy cập:

```
http://192.168.182.195/horizon
```

Đăng nhập với:
- Domain: `Default`
- Username: `admin`
- Password: `Welcome123`

Kết quả mong đợi: giao diện Horizon hiển thị với dashboard tổng quan.

---

Trước: [07-launch-instance.md](07-launch-instance.md)
