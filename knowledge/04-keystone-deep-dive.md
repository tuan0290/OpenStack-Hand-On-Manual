# Keystone - Deep Dive

## Keystone là gì?

Keystone là Identity Service của OpenStack - cung cấp:
- **Authentication**: xác thực "bạn là ai"
- **Authorization**: phân quyền "bạn được làm gì"
- **Service Catalog**: danh mục các service và endpoint

## Các khái niệm cốt lõi

```
Domain
└── Project (tenant)
    └── User ←→ Role (assignment)
                    │
                    ▼
              Permissions
```

**Domain**: phân vùng quản lý cấp cao nhất. Mặc định có domain `Default`.

**Project**: đơn vị tổ chức tài nguyên. VM, network, volume đều thuộc về 1 project.

**User**: tài khoản người dùng hoặc service account.

**Role**: tập hợp quyền. Các role mặc định:
- `admin`: toàn quyền
- `member`: quyền thông thường trong project
- `reader`: chỉ đọc

**Role Assignment**: gán role cho user trong context của project hoặc domain.

## Token - Fernet vs UUID

```
UUID Token (cũ):
  - Chuỗi ngẫu nhiên 32 ký tự
  - Phải lưu vào DB để validate
  - Mỗi validate = 1 DB query
  - DB phình to theo thời gian

Fernet Token (hiện tại):
  - Chuỗi mã hóa chứa thông tin user/project/role
  - Không lưu DB
  - Validate bằng cách giải mã với Fernet key
  - DB không phình to
  - Nhược điểm: không thể revoke ngay lập tức
```

## Fernet Key Rotation

Có **3 loại key** trong repository:

```
/etc/keystone/fernet-keys/
├── 0    ← STAGED key (sẽ trở thành primary ở lần rotate tiếp theo)
├── 1    ← secondary key (decrypt token cũ)
├── 2    ← secondary key (decrypt token cũ)
└── 3    ← PRIMARY key (index cao nhất - ký token mới + decrypt)
```

**Primary key**: index cao nhất, dùng để **encrypt và decrypt** token mới.

**Secondary key**: từng là primary, bị demote. Chỉ dùng để **decrypt** token cũ.

**Staged key**: luôn là file `0`, chưa bao giờ là primary. Chỉ dùng để **decrypt**. Sẽ trở thành primary ở lần rotate tiếp theo. Mục đích: cho phép distribute key mới sang các node khác trước khi nó trở thành primary - tránh token validation fail khi cluster chưa đồng bộ.

**Lifecycle của 1 key:**
```
staged (0) → primary (index cao nhất) → secondary → bị xóa
```

**Khi rotate:**
1. Staged key (0) được promote thành primary (đổi tên thành index cao nhất)
2. Primary cũ trở thành secondary
3. Staged key mới được tạo (file 0)
4. Secondary key cũ nhất bị xóa nếu vượt `max_active_keys`

```bash
# Rotate key thủ công
keystone-manage fernet_rotate --keystone-user keystone --keystone-group keystone

# Tính max_active_keys:
# max_active_keys = (token_expiration_hours / rotation_frequency_hours) + 2
# Ví dụ: token 1h, rotate mỗi 15 phút → max_active_keys = (1/0.25) + 2 = 6
```

> Trong production: cron job rotate định kỳ và distribute key sang tất cả Keystone node.

## Policy - Phân quyền chi tiết

Keystone dùng file policy để định nghĩa ai được làm gì:

```bash
cat /etc/keystone/policy.yaml
```

Ví dụ:
```yaml
# Chỉ admin mới tạo được user
"identity:create_user": "rule:admin_required"

# Member có thể xem project của mình
"identity:get_project": "rule:admin_or_token_subject"
```

## Service Catalog

Khi user lấy token, Keystone trả về token kèm service catalog:

```json
{
  "token": {
    "catalog": [
      {
        "name": "keystone",
        "type": "identity",
        "endpoints": [
          {"interface": "public", "url": "http://controller:5000/v3"},
          {"interface": "internal", "url": "http://controller:5000/v3"},
          {"interface": "admin", "url": "http://controller:5000/v3"}
        ]
      },
      {
        "name": "nova",
        "type": "compute",
        "endpoints": [...]
      }
    ]
  }
}
```

Client dùng catalog này để biết URL của từng service, không cần hardcode.

## Luồng xác thực đầy đủ

```
1. User gửi username + password đến Keystone
   POST /v3/auth/tokens
   Body: {auth: {identity: {password: ...}, scope: {project: ...}}}

2. Keystone xác thực:
   a. Tìm user trong DB
   b. Verify password (bcrypt hash)
   c. Lấy role assignments của user trong project
   d. Tạo Fernet token chứa: user_id, project_id, roles, expiry, audit_id

3. Keystone trả về:
   Header: X-Subject-Token: gAAAAABZ...
   Body: token details + service catalog

4. User gửi request đến Nova kèm token:
   GET /v2.1/servers
   Header: X-Auth-Token: gAAAAABZ...

5. Nova validate token:
   a. Gửi token đến Keystone: GET /v3/auth/tokens
      Header: X-Auth-Token: <nova_service_token>
              X-Subject-Token: <user_token>
   b. Keystone giải mã Fernet token
   c. Kiểm tra expiry, revocation list
   d. Trả về token info (user, project, roles)
   e. Kết quả cache vào Memcached

6. Nova kiểm tra policy:
   user có role "member" trong project → được phép list servers
   → Trả về danh sách VM
```

## Các lệnh quản trị Keystone

```bash
source ~/admin-openrc

# User management
openstack user list
openstack user show admin
openstack user create --domain default --password Pass123 newuser
openstack user set --password NewPass123 newuser
openstack user delete newuser

# Project management
openstack project list
openstack project create --domain default myproject
openstack project delete myproject

# Role management
openstack role list
openstack role assignment list --user admin --project admin

# Token
openstack token issue
openstack token revoke <token_id>

# Endpoint
openstack endpoint list
openstack catalog list

# Service
openstack service list
```

## Debug Keystone

```bash
# Xem log
tail -f /var/log/apache2/keystone.log

# Test token validate
TOKEN=$(openstack token issue -f value -c id)
curl -s -H "X-Auth-Token: $TOKEN" \
     -H "X-Subject-Token: $TOKEN" \
     http://controller:5000/v3/auth/tokens | python3 -m json.tool

# Kiểm tra Fernet keys
ls -la /etc/keystone/fernet-keys/

# Kiểm tra DB
mysql -u keystone -pWelcome123 keystone -e "SELECT * FROM user LIMIT 5\G"
```

---

## Lab: Quan sát Keystone hoạt động thực tế

### 1. Theo dõi luồng xác thực

Mở 2 terminal song song:

**Terminal 1 - theo dõi Keystone log:**
```bash
tail -f /var/log/apache2/keystone.log | grep -v "^$"
```

**Terminal 2 - thực hiện các thao tác:**
```bash
source ~/admin-openrc

# Lấy token và quan sát log
openstack token issue

# Thử với sai password - quan sát log báo lỗi gì
openstack --os-auth-url http://controller:5000/v3 \
  --os-project-domain-name Default \
  --os-user-domain-name Default \
  --os-project-name admin \
  --os-username admin \
  --os-password WRONG_PASSWORD \
  token issue
```

---

### 2. Giải mã Fernet token

```bash
source ~/admin-openrc
TOKEN=$(openstack token issue -f value -c id)
echo "Token: $TOKEN"
echo "Token length: ${#TOKEN}"

# Fernet token là base64url encoded
# Giải mã phần header (không decrypt được nội dung vì cần key)
echo $TOKEN | cut -d'.' -f1 | base64 -d 2>/dev/null | xxd | head -5

# Xem token info qua API
curl -s \
  -H "X-Auth-Token: $TOKEN" \
  -H "X-Subject-Token: $TOKEN" \
  http://controller:5000/v3/auth/tokens | python3 -m json.tool | head -50
```

---

### 3. Quan sát Fernet key rotation

```bash
# Xem trạng thái keys hiện tại
ls -la /etc/keystone/fernet-keys/
# File 0 = staged key, file số cao nhất = primary key

# Lấy token với key hiện tại
TOKEN_BEFORE=$(openstack token issue -f value -c id)

# Rotate keys
keystone-manage fernet_rotate \
  --keystone-user keystone \
  --keystone-group keystone

# Xem keys sau rotate
ls -la /etc/keystone/fernet-keys/
# Primary key mới = index cao hơn trước
# Staged key mới = file 0 (khác với staged key cũ)

# Token cũ vẫn còn valid (secondary key vẫn có thể decrypt)
openstack --os-auth-url http://controller:5000/v3 \
  --os-project-domain-name Default \
  --os-user-domain-name Default \
  --os-project-name admin \
  --os-username admin \
  token issue
```

---

### 4. Kiểm tra Service Catalog

```bash
source ~/admin-openrc

# Xem toàn bộ catalog
openstack catalog list

# Xem endpoint của từng service
openstack endpoint list

# Xem endpoint của 1 service cụ thể
openstack endpoint list --service keystone
openstack endpoint list --service nova

# Lấy token và xem catalog trong token
TOKEN=$(openstack token issue -f value -c id)
curl -s \
  -H "X-Auth-Token: $TOKEN" \
  -H "X-Subject-Token: $TOKEN" \
  http://controller:5000/v3/auth/tokens \
  | python3 -m json.tool | grep -A3 '"catalog"'
```

---

### 5. Test phân quyền Role

```bash
source ~/admin-openrc

# Tạo user test với role member
openstack user create --domain default --password Test123 testuser
openstack role add --project demo --user testuser member

# Tạo file openrc cho testuser
cat > ~/test-openrc << 'EOF'
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=demo
export OS_USERNAME=testuser
export OS_PASSWORD=Test123
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
EOF

source ~/test-openrc

# testuser có thể làm gì?
openstack server list          # OK - xem VM của project demo
openstack flavor list          # OK - xem flavor (public)
openstack user list            # FAIL - không có quyền admin

# Thử thao tác admin
openstack project create test-project  # FAIL - cần admin role

# Dọn dẹp
source ~/admin-openrc
openstack user delete testuser
```

---

### 6. Xem Memcached cache token

```bash
# Xem stats Memcached trước khi validate token
echo "stats" | nc 192.168.225.195 11211 | grep -E "curr_items|get_hits|get_misses"

# Validate token lần đầu (cache miss)
source ~/admin-openrc
openstack server list

# Xem stats sau - get_misses tăng (lần đầu không có cache)
echo "stats" | nc 192.168.225.195 11211 | grep -E "curr_items|get_hits|get_misses"

# Validate lại ngay (cache hit)
openstack server list

# Xem stats - get_hits tăng (lần này có cache)
echo "stats" | nc 192.168.225.195 11211 | grep -E "curr_items|get_hits|get_misses"
```

---

## Troubleshooting: Các lỗi phổ biến với Keystone

### Cách đọc lỗi nhanh

```bash
# Bước 1: xem log Keystone
tail -50 /var/log/apache2/keystone.log | grep -i "error\|warn\|unauthorized"

# Bước 2: test kết nối Keystone
curl -s http://controller:5000/v3 | python3 -m json.tool

# Bước 3: test lấy token thủ công
curl -s -X POST http://controller:5000/v3/auth/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "auth": {
      "identity": {"methods": ["password"],
        "password": {"user": {"name": "admin", "domain": {"name": "Default"},
          "password": "Welcome123"}}},
      "scope": {"project": {"name": "admin", "domain": {"name": "Default"}}}
    }
  }' | python3 -m json.tool
```

---

### Lỗi 1: "HTTP 401 Unauthorized / The request you have made requires authentication"

**Triệu chứng:**
```
ERROR (Unauthorized): The request you have made requires authentication. (HTTP 401)
```

**Nguyên nhân và cách kiểm tra:**

```bash
# A. Biến môi trường chưa được set hoặc sai
env | grep OS_
# Phải có đủ: OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, OS_PROJECT_NAME...

# Nếu thiếu → source lại
source ~/admin-openrc

# B. Password có ký tự đặc biệt
# Ký tự như !, @, #, $ trong password cần escape trong shell
# Ví dụ: password = "Pass!123"
export OS_PASSWORD='Pass!123'  # dùng single quote

# C. OS_AUTH_URL sai
echo $OS_AUTH_URL
# Phải là: http://controller:5000/v3 (không phải /v2 hay /v2.0)

# D. Keystone không chạy
curl http://controller:5000/v3
# Nếu connection refused → Apache chưa chạy
systemctl status apache2

# E. Sai password thực sự
# Test trực tiếp
openstack --os-auth-url http://controller:5000/v3 \
  --os-project-domain-name Default \
  --os-user-domain-name Default \
  --os-project-name admin \
  --os-username admin \
  --os-password Welcome123 \
  token issue
```

---

### Lỗi 2: "Unable to validate token / Failed to fetch token data"

**Triệu chứng:**
```
CRITICAL keystonemiddleware.auth_token [-] Unable to validate token:
Failed to fetch token data from identity server
```

**Nguyên nhân:** Service (Nova, Glance...) không kết nối được Keystone để validate token.

```bash
# Kiểm tra từ service đang lỗi (ví dụ Nova)
grep "keystonemiddleware\|auth_token" /var/log/nova/nova-conductor.log | tail -10

# Kiểm tra keystone_authtoken config trong service
grep -A10 "\[keystone_authtoken\]" /etc/nova/nova.conf

# Test kết nối Keystone từ controller
curl http://controller:5000/v3

# Kiểm tra Memcached (nếu cache bị corrupt)
echo "flush_all" | nc 192.168.225.195 11211
# Sau đó thử lại
```

---

### Lỗi 3: "404 Not Found" khi gọi Keystone

**Triệu chứng:**
```
Not Found (HTTP 404)
```

**Nguyên nhân:** Keystone WSGI script không tồn tại hoặc Apache config sai.

```bash
# Kiểm tra WSGI script
ls -la /usr/bin/keystone-wsgi-public

# Nếu không tồn tại → tạo lại (vấn đề thực tế với Flamingo)
cat > /usr/bin/keystone-wsgi-public << 'EOF'
import sys
sys.path.insert(0, '/usr/lib/python3/dist-packages')
from keystone.server.wsgi import initialize_public_application
application = initialize_public_application()
EOF
chmod 755 /usr/bin/keystone-wsgi-public
chown keystone:keystone /usr/bin/keystone-wsgi-public

systemctl restart apache2

# Kiểm tra Apache config
cat /etc/apache2/sites-enabled/keystone.conf
# WSGIScriptAlias phải trỏ đúng file
```

---

### Lỗi 4: Token hết hạn liên tục / "Token not found"

**Triệu chứng:** Token expire quá nhanh hoặc bị invalidate.

```bash
# Xem thời hạn token mặc định
grep "expiration" /etc/keystone/keystone.conf
# Mặc định: 3600 giây (1 giờ)

# Xem token vừa lấy hết hạn lúc nào
openstack token issue | grep expires

# Nếu token expire quá nhanh → kiểm tra đồng hồ hệ thống
date
# Phải đồng bộ với NTP
chronyc tracking | grep "System time"

# Nếu đồng hồ lệch nhiều → sync lại
chronyc makestep
```

---

### Lỗi 5: "Fernet key not found" / Token không decrypt được

**Triệu chứng:**
```
keystone.exception.ValidationError: Invalid token
```

**Nguyên nhân:** Fernet key đã bị rotate và key cũ không còn tồn tại.

```bash
# Xem keys hiện tại
ls -la /etc/keystone/fernet-keys/

# Xem log lỗi
grep "fernet\|token\|decrypt" /var/log/apache2/keystone.log | tail -10

# Nếu key bị mất → user phải lấy token mới
# Không thể recover token cũ

# Kiểm tra max_active_keys
grep "max_active_keys" /etc/keystone/keystone.conf
# Mặc định: 3
# Nếu rotate quá thường → tăng max_active_keys
```

---

### Lỗi 6: Endpoint không tìm thấy service

**Triệu chứng:**
```
EndpointNotFound: Endpoint not found
```

```bash
# Kiểm tra service catalog
openstack service list
openstack endpoint list

# Nếu thiếu endpoint → tạo lại
# Ví dụ thiếu nova endpoint:
openstack endpoint create --region RegionOne \
  compute public http://controller:8774/v2.1
openstack endpoint create --region RegionOne \
  compute internal http://controller:8774/v2.1
openstack endpoint create --region RegionOne \
  compute admin http://controller:8774/v2.1

# Kiểm tra OS_REGION_NAME có khớp không
echo $OS_REGION_NAME
openstack endpoint list --region RegionOne
```

---

### Lỗi 7: "Connection refused" khi gọi http://controller:5000

```bash
# Kiểm tra Apache đang chạy
systemctl status apache2

# Kiểm tra port 5000 đang listen
ss -tlnp | grep 5000

# Kiểm tra Apache config
apache2ctl -t  # test syntax
apache2ctl -S  # xem virtual hosts

# Xem error log Apache
tail -20 /var/log/apache2/error.log

# Restart Apache
systemctl restart apache2
```

---

### Quick Diagnostic Script cho Keystone

```bash
#!/bin/bash
# Chạy trên controller

echo "=== Apache Status ==="
systemctl is-active apache2

echo ""
echo "=== Keystone Endpoint ==="
curl -s http://controller:5000/v3 | python3 -m json.tool | grep version

echo ""
echo "=== Fernet Keys ==="
ls -la /etc/keystone/fernet-keys/

echo ""
echo "=== Token Test ==="
TOKEN=$(curl -s -X POST http://controller:5000/v3/auth/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "auth": {
      "identity": {"methods": ["password"],
        "password": {"user": {"name": "admin", "domain": {"name": "Default"},
          "password": "Welcome123"}}},
      "scope": {"project": {"name": "admin", "domain": {"name": "Default"}}}
    }
  }' -D - 2>/dev/null | grep "X-Subject-Token" | awk '{print $2}' | tr -d '\r')

if [ -n "$TOKEN" ]; then
  echo "Token obtained: ${TOKEN:0:20}..."
else
  echo "FAILED to get token"
fi

echo ""
echo "=== Service List ==="
OS_AUTH_URL=http://controller:5000/v3 \
OS_USERNAME=admin OS_PASSWORD=Welcome123 \
OS_PROJECT_NAME=admin OS_USER_DOMAIN_NAME=Default \
OS_PROJECT_DOMAIN_NAME=Default OS_IDENTITY_API_VERSION=3 \
openstack service list 2>/dev/null || echo "FAILED"

echo ""
echo "=== Recent Keystone Errors ==="
grep -i "error\|warn\|unauthorized" /var/log/apache2/keystone.log 2>/dev/null | tail -5
```
