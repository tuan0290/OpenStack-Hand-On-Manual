# Cài đặt dịch vụ Identity (Keystone)

> Cài đặt trên node **Controller**

## Mục lục

1. [Tạo database cho Keystone](#1-tạo-database-cho-keystone)
2. [Cài đặt và cấu hình Keystone](#2-cài-đặt-và-cấu-hình-keystone)
3. [Cấu hình Apache cho Keystone](#3-cấu-hình-apache-cho-keystone)
4. [Kết thúc cài đặt](#4-kết-thúc-cài-đặt)
5. [Tạo domain, project, user, role](#5-tạo-domain-project-user-role)
6. [Kiểm tra cài đặt Keystone](#6-kiểm-tra-cài-đặt-keystone)
7. [Tạo script biến môi trường](#7-tạo-script-biến-môi-trường)

---

## 1. Tạo database cho Keystone

Đăng nhập vào MariaDB:

```bash
mysql -u root -pWelcome123
```

Tạo database và cấp quyền:

```sql
CREATE DATABASE keystone;
CREATE USER 'keystone'@'localhost' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost';
CREATE USER 'keystone'@'%' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%';
FLUSH PRIVILEGES;
EXIT;
```

---

## 2. Cài đặt và cấu hình Keystone

Cài đặt gói:

```bash
apt install -y keystone
```

Sao lưu file cấu hình gốc:

```bash
cp /etc/keystone/keystone.conf /etc/keystone/keystone.conf.orig
```

Sửa file `/etc/keystone/keystone.conf`, cấu hình các section sau:

Trong section `[database]`:

```ini
[database]
connection = mysql+pymysql://keystone:Welcome123@controller/keystone
```

Trong section `[token]`:

```ini
[token]
provider = fernet
```

Đồng bộ database cho Keystone:

```bash
su -s /bin/sh -c "keystone-manage db_sync" keystone
```

Khởi tạo Fernet keys:

```bash
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
```

Bootstrap Identity service:

```bash
keystone-manage bootstrap --bootstrap-password Welcome123 \
  --bootstrap-admin-url http://controller:5000/v3/ \
  --bootstrap-internal-url http://controller:5000/v3/ \
  --bootstrap-public-url http://controller:5000/v3/ \
  --bootstrap-region-id RegionOne
```

---

## 3. Cấu hình Apache cho Keystone

Sửa file `/etc/apache2/apache2.conf`, thêm dòng sau ngay sau dòng `# Global configuration`:

```
# Global configuration
ServerName controller
```

> Lưu ý: Keystone 28 (Flamingo) trên Ubuntu 24.04 không ship file wsgi script. Cần tạo thủ công:

```bash
cat > /usr/bin/keystone-wsgi-public << 'EOF'
import sys
sys.path.insert(0, '/usr/lib/python3/dist-packages')
from keystone.server.wsgi import initialize_public_application
application = initialize_public_application()
EOF

chmod 755 /usr/bin/keystone-wsgi-public
chown keystone:keystone /usr/bin/keystone-wsgi-public
```

---

## 4. Kết thúc cài đặt

Restart Apache và xóa database SQLite mặc định:

```bash
systemctl restart apache2
systemctl enable apache2
rm -f /var/lib/keystone/keystone.db
```

Cấu hình biến môi trường cho tài khoản admin:

```bash
export OS_USERNAME=admin
export OS_PASSWORD=Welcome123
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
```

---

## 5. Tạo domain, project, user, role

Tạo project `service`:

```bash
openstack project create --domain default --description "Service Project" service
```

Kết quả:

```
+-------------+----------------------------------+
| Field       | Value                            |
+-------------+----------------------------------+
| description | Service Project                  |
| domain_id   | default                          |
| enabled     | True                             |
| id          | e99255bab0a94a87b1184d18e14bd928 |
| is_domain   | False                            |
| name        | service                          |
| parent_id   | default                          |
+-------------+----------------------------------+
```

Tạo project `demo`:

```bash
openstack project create --domain default --description "Demo Project" demo
```

Tạo user `demo`:

```bash
openstack user create --domain default --password Welcome123 demo
```

Tạo role `member`:

```bash
# Role 'member' thường đã tồn tại sẵn sau khi bootstrap, kiểm tra trước:
openstack role list
```

Nếu chưa có thì tạo:

```bash
openstack role create member
```

Gán role `member` cho user `demo` trên project `demo`:

```bash
openstack role add --project demo --user demo member
```

---

## 6. Kiểm tra cài đặt Keystone

Bỏ biến môi trường tạm thời:

```bash
unset OS_AUTH_URL OS_PASSWORD
```

Kiểm tra với tài khoản admin:

```bash
openstack --os-auth-url http://controller:5000/v3 \
  --os-project-domain-name Default --os-user-domain-name Default \
  --os-project-name admin --os-username admin token issue
```

Nhập mật khẩu `Welcome123` khi được hỏi. Kết quả mong đợi:

```
+------------+---------------------------------------------------------+
| Field      | Value                                                   |
+------------+---------------------------------------------------------+
| expires    | 2025-10-01T10:00:00+0000                                |
| id         | gAAAAABZ...                                             |
| project_id | b54646bf669746db8c62ec0410bd0528                        |
| user_id    | 102f8ea368cd4451ad6fefeb15801177                        |
+------------+---------------------------------------------------------+
```

Kiểm tra với tài khoản demo:

```bash
openstack --os-auth-url http://controller:5000/v3 \
  --os-project-domain-name Default --os-user-domain-name Default \
  --os-project-name demo --os-username demo token issue
```

---

## 7. Tạo script biến môi trường

Tạo file `~/admin-openrc`:

```bash
cat > ~/admin-openrc << 'EOF'
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=Welcome123
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF
```

Tạo file `~/demo-openrc`:

```bash
cat > ~/demo-openrc << 'EOF'
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=demo
export OS_USERNAME=demo
export OS_PASSWORD=Welcome123
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF
```

Kiểm tra bằng cách chạy script và lấy token:

```bash
source ~/admin-openrc
openstack token issue
```

Kết quả mong đợi:

```
+------------+---------------------------------------------------------+
| Field      | Value                                                   |
+------------+---------------------------------------------------------+
| expires    | 2025-10-01T10:00:00+0000                                |
| id         | gAAAAABZ...                                             |
| project_id | b54646bf669746db8c62ec0410bd0528                        |
| user_id    | 102f8ea368cd4451ad6fefeb15801177                        |
+------------+---------------------------------------------------------+
```

---

Trước: [01-environment-prepare.md](01-environment-prepare.md) | Tiếp theo: [03-glance.md](03-glance.md)

---

## Hỏi & Đáp

### Fernet keys là gì?

Fernet keys là cặp khóa mã hóa dùng để tạo và xác thực token trong Keystone.

Trước đây OpenStack dùng **UUID token** - mỗi token được lưu vào database, mỗi lần xác thực phải query DB. Khi hệ thống lớn, DB phình to và chậm.

Fernet giải quyết bằng cách mã hóa thông tin user/project/role trực tiếp vào token - không cần lưu DB. Keystone chỉ cần dùng key để giải mã token là biết ngay token hợp lệ không, user là ai.

Cấu trúc gồm 2 loại key:
- `0` - primary key: dùng để ký token mới
- `1, 2...` - secondary keys: dùng để verify token cũ (rotation)

Key được lưu tại `/etc/keystone/fernet-keys/`, rotate định kỳ để bảo mật.

---

### Luồng hoạt động của Keystone

```
USER
 │
 │ 1. Gửi username + password
 ▼
KEYSTONE API (port 5000)
 │
 │ 2. Kiểm tra user trong MariaDB
 ▼
MARIADB
 │
 │ 3. Trả về thông tin user/project/role
 ▼
KEYSTONE
 │
 │ 4. Mã hóa thông tin bằng Fernet key
 │    → Tạo TOKEN (chứa user_id, project_id, roles, expiry)
 ▼
USER (nhận TOKEN)
 │
 │ 5. Gửi request đến bất kỳ service nào (Nova, Glance...) kèm TOKEN
 ▼
SERVICE (Nova/Glance/Neutron...)
 │
 │ 6. Gửi TOKEN đến Keystone để validate
 ▼
KEYSTONE
 │
 │ 7. Dùng Fernet key giải mã TOKEN
 │    → Kiểm tra còn hạn không, role có đủ quyền không
 │    → Kết quả cache vào Memcached
 ▼
SERVICE
 │
 │ 8. Được phép → xử lý request
 │    Không được phép → trả về 403 Forbidden
 ▼
USER nhận kết quả
```

**Các thành phần Keystone tương tác:**

```
KEYSTONE ←→ MARIADB     : lưu user, project, role, endpoint
KEYSTONE ←→ MEMCACHED   : cache token đã validate
KEYSTONE ←→ APACHE      : nhận HTTP request qua mod_wsgi port 5000
```

---

### Bootstrap Identity service là gì?

Bootstrap là bước khởi tạo dữ liệu ban đầu cho Keystone - tạo ra "hạt giống" đầu tiên để hệ thống có thể hoạt động.

Vấn đề kiểu "con gà - quả trứng": Keystone cần có admin user để tạo user/project/role, nhưng muốn tạo admin user thì phải có Keystone đang chạy với quyền admin. Vòng lặp này được phá vỡ bằng lệnh `keystone-manage bootstrap` - chạy trực tiếp trên server, không qua API.

Lệnh này tạo ra một lần duy nhất:

```
keystone-manage bootstrap --bootstrap-password Welcome123 ...
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
             Domain: Default   Project: admin   User: admin
                                    │               │
                                    └───────────────┘
                                          │
                                    Role: admin
                                    (gán cho user admin
                                     trên project admin)
                                          │
                                    Endpoint: Keystone
                                    (public/internal/admin
                                     đều trỏ port 5000)
```

Sau bước này mới có thể dùng OpenStack CLI để tạo thêm user/project/role khác.

---

### Có những cách nào để tạo user/project/role trong Keystone?

Có 3 cách, bản chất đều gọi vào Keystone API:

**1. OpenStack CLI** (cách dùng trong tài liệu này)
```bash
openstack user create --domain default --password Welcome123 demo
```

**2. Keystone REST API trực tiếp**
```bash
curl -X POST http://controller:5000/v3/users \
  -H "X-Auth-Token: <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "user": {
      "name": "demo",
      "password": "Welcome123",
      "domain_id": "default"
    }
  }'
```

**3. Horizon Dashboard** - sau khi cài Horizon thì quản lý hoàn toàn qua giao diện web.

OpenStack CLI thực chất chỉ là wrapper gọi Keystone API, bản chất giống nhau. CLI tiện hơn vì không cần tự format JSON và quản lý token thủ công.

---

### Làm sao để lấy token?

**1. Dùng OpenStack CLI**
```bash
source ~/admin-openrc
openstack token issue
```

**2. Gọi Keystone API trực tiếp**
```bash
curl -X POST http://controller:5000/v3/auth/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "auth": {
      "identity": {
        "methods": ["password"],
        "password": {
          "user": {
            "name": "admin",
            "domain": {"name": "Default"},
            "password": "Welcome123"
          }
        }
      },
      "scope": {
        "project": {
          "name": "admin",
          "domain": {"name": "Default"}
        }
      }
    }
  }'
```

Token trả về nằm trong response header `X-Subject-Token`, không phải body. Để lấy ra:

```bash
curl -si -X POST http://controller:5000/v3/auth/tokens \
  -H "Content-Type: application/json" \
  -d '{...}' | grep -i x-subject-token
```

Token có thời hạn mặc định **1 giờ**, sau đó phải lấy lại.

---

### Apache làm gì trong Keystone?

Apache đóng vai trò web server trung gian giữa client và Keystone application.

Keystone bản thân là một Python app, không tự lắng nghe HTTP request được. Apache nhận request vào rồi chuyển cho Keystone xử lý qua mod_wsgi:

```
CLIENT (curl/CLI/Nova...)
        │
        │ HTTP request port 5000
        ▼
    APACHE
        │
        │ mod_wsgi chuyển request
        ▼
  KEYSTONE (Python app)
        │
        │ xử lý logic: xác thực, tạo token...
        ▼
    MARIADB
        │
        │ trả kết quả ngược lại
        ▼
    APACHE
        │
        │ HTTP response
        ▼
    CLIENT
```

**Tại sao không để Keystone tự serve HTTP?**

Keystone có thể tự chạy standalone nhưng Apache mang lại:
- Xử lý nhiều request đồng thời tốt hơn (multi-process/thread)
- SSL termination
- Access log, error log chuẩn
- Tích hợp sẵn với hệ thống Ubuntu

Đó là lý do file `keystone.conf` trong Apache có dòng `WSGIDaemonProcess keystone-public processes=5` - tức là 5 process Python chạy song song để xử lý request.

---

### `keystone-manage db_sync` là gì và hoạt động như thế nào?

Phân tích từng phần của lệnh `su -s /bin/sh -c "keystone-manage db_sync" keystone`:

**`su -s /bin/sh -c "..." keystone`**
- `su keystone` = chạy lệnh với user `keystone` (không phải root)
- `-s /bin/sh` = dùng shell `/bin/sh` vì user `keystone` không có login shell
- `-c "..."` = lệnh cần chạy

Tại sao không chạy thẳng bằng root? Vì file config, fernet keys của Keystone thuộc sở hữu user `keystone`, chạy bằng root có thể tạo ra file với permission sai.

**`keystone-manage db_sync`**

Đây là lệnh migration database. Keystone dùng SQLAlchemy để quản lý schema DB. Khi chạy `db_sync` nó:

```
keystone-manage db_sync
        │
        │ 1. Đọc /etc/keystone/keystone.conf
        │    lấy connection string đến MariaDB
        ▼
        │ 2. Kiểm tra database hiện tại đang ở version schema nào
        ▼
        │ 3. Chạy tuần tự các migration script còn thiếu
        ▼
MariaDB: tạo đủ các bảng
        │
        ├── user
        ├── project
        ├── role
        ├── assignment
        ├── endpoint
        ├── service
        └── ...v.v
```

Nếu sau này upgrade Keystone lên version mới, chạy lại `db_sync` sẽ tự động ALTER TABLE thêm cột mới hoặc tạo bảng mới mà không xóa dữ liệu cũ.
