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
