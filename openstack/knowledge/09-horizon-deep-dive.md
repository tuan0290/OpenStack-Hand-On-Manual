# Horizon - Deep Dive

## Horizon là gì?

Horizon là Dashboard Service của OpenStack - giao diện web cho phép quản lý OpenStack qua trình duyệt. Được xây dựng trên **Django** framework.

## Kiến trúc

```
Browser
    │ HTTP (port 80)
    ▼
Apache HTTP Server
    │ mod_wsgi / WSGI
    ▼
Django Application (Horizon)
    │
    ├── openstack_auth    ← xác thực với Keystone
    ├── openstack_dashboard ← UI panels
    │   ├── Project panel  ← user view
    │   ├── Admin panel    ← admin view
    │   └── Identity panel ← user/project management
    │
    └── OpenStack Python SDK / openstackclient
        │ REST API calls
        ▼
    OpenStack Services (Keystone, Nova, Glance, Neutron...)
```

## Django Offline Compression

Horizon dùng Django Compressor để minify CSS/JS:

```
COMPRESS_OFFLINE = True  (mặc định)
```

Khi `COMPRESS_OFFLINE = True`, Django pre-compile tất cả CSS/JS thành file nén và lưu manifest. Nếu manifest không tồn tại → lỗi:

```
OfflineGenerationError: key "xxx" is missing from offline manifest
```

**Fix:**

```bash
cd /usr/share/openstack-dashboard
python3 manage.py compress
python3 manage.py collectstatic --noinput
systemctl reload apache2
```

Phải chạy lại sau mỗi lần update Horizon.

## Cấu hình quan trọng

File: `/etc/openstack-dashboard/local_settings.py`

```python
# Keystone endpoint
OPENSTACK_KEYSTONE_URL = "http://%s:5000/identity/v3" % OPENSTACK_HOST

# Multi-domain support
OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True

# API versions
OPENSTACK_API_VERSIONS = {
    "identity": 3,
    "image": 2,
    "volume": 3,
}

# Session storage (Memcached)
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.PyMemcacheCache',
        'LOCATION': 'controller:11211',
    }
}

# Timezone
TIME_ZONE = "Asia/Ho_Chi_Minh"
```

## Project vs Admin Panel

**Project panel** - góc nhìn của user trong project hiện tại:

```
Project
├── Compute
│   ├── Overview      ← quota usage
│   ├── Instances     ← VM của project này
│   ├── Images        ← image public + của project
│   └── Key Pairs
├── Network
│   ├── Network Topology
│   ├── Networks
│   ├── Routers
│   ├── Security Groups
│   └── Floating IPs
└── Volumes
    ├── Volumes
    └── Snapshots
```

**Admin panel** - chỉ user có role `admin` mới thấy:

```
Admin
├── Compute
│   ├── Overview      ← tổng quan toàn hệ thống
│   ├── Instances     ← TẤT CẢ instance mọi project
│   ├── Hypervisors   ← compute node status
│   ├── Host Aggregates
│   └── Flavors
├── Network
│   ├── Networks      ← TẤT CẢ network
│   └── Routers       ← TẤT CẢ router
└── Identity
    ├── Projects
    ├── Users
    ├── Groups
    └── Roles
```

## Session Management

Horizon dùng Memcached để lưu session:

```
User login → Keystone trả về token
           → Horizon lưu token vào Memcached session
           → Browser nhận session cookie

Mỗi request:
  Browser gửi session cookie
  → Horizon lấy token từ Memcached
  → Gọi OpenStack API với token
```

Nếu Memcached restart → tất cả session mất → user phải login lại.

## Customization

Horizon có thể customize:

```python
# Thêm custom panel
INSTALLED_APPS += ['my_custom_panel']

# Thay đổi logo
SITE_BRANDING = "My Cloud"

# Ẩn panel không cần
HORIZON_CONFIG = {
    'dashboards': ('project', 'admin', 'identity'),
}
```

## Debug

```bash
# Xem log Apache
tail -f /var/log/apache2/error.log | grep -v "wsgi:error.*template"

# Xem lỗi thực sự
grep -i "exception\|traceback\|error" /var/log/apache2/error.log | tail -20

# Test kết nối Keystone từ Horizon
python3 -c "
import keystoneauth1.session as ks
from keystoneauth1.identity import v3
auth = v3.Password(
    auth_url='http://controller:5000/v3',
    username='admin', password='Welcome123',
    project_name='admin',
    user_domain_name='Default',
    project_domain_name='Default'
)
sess = ks.Session(auth=auth)
print(sess.get_token())
"

# Regenerate static files
cd /usr/share/openstack-dashboard
python3 manage.py compress
python3 manage.py collectstatic --noinput
systemctl reload apache2
```
