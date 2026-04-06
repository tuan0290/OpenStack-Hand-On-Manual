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
# Generate static files và compression manifest
cd /usr/share/openstack-dashboard
python3 manage.py compress
python3 manage.py collectstatic --noinput 2>/dev/null || true

systemctl reload apache2
```

> **Lưu ý:** Bước `python3 manage.py compress` là bắt buộc. Nếu bỏ qua, Horizon sẽ hiện lỗi **"Something went wrong!"** với message `OfflineGenerationError: key is missing from offline manifest`. Đây là do Django offline compression được bật mặc định nhưng chưa có manifest file.

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

---

## Hỏi & Đáp

### Lỗi "Something went wrong!" khi truy cập Horizon

**Triệu chứng:** Horizon load được trang nhưng hiện lỗi "Something went wrong! An unexpected error has occurred."

**Nguyên nhân:** Django offline compression được bật mặc định nhưng chưa generate manifest file. Log Apache sẽ thấy:

```
compressor.exceptions.OfflineGenerationError: You have offline compression enabled
but key "xxx" is missing from offline manifest.
You may need to run "python manage.py compress".
```

**Cách fix:**

```bash
cd /usr/share/openstack-dashboard
python3 manage.py compress
systemctl reload apache2
```

---

### DNS bị mất sau khi chuyển ens33 vào OVS bridge

**Triệu chứng:** `apt install` báo `Temporary failure resolving` dù ping IP vẫn được.

**Nguyên nhân:** Khi `ens33` được gán vào OVS bridge, cấu hình DNS từ netplan/systemd-resolved bị mất vì interface không còn được netplan quản lý.

**Cách fix:**

```bash
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

Đã được thêm vào systemd service `ovs-br-provider` để tự động fix sau mỗi lần reboot.
