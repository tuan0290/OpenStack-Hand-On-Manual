# Cài đặt dịch vụ Placement API

> Cài đặt trên node **Controller**

## Mục lục

1. [Tạo database cho Placement](#1-tạo-database-cho-placement)
2. [Tạo user, service và endpoint API](#2-tạo-user-service-và-endpoint-api)
3. [Cài đặt và cấu hình Placement](#3-cài-đặt-và-cấu-hình-placement)
4. [Kết thúc cài đặt](#4-kết-thúc-cài-đặt)
5. [Kiểm tra cài đặt Placement](#5-kiểm-tra-cài-đặt-placement)

---

## 1. Tạo database cho Placement

Đăng nhập vào MariaDB:

```bash
mysql -u root -pWelcome123
```

Tạo database và cấp quyền:

```sql
CREATE DATABASE placement;
CREATE USER 'placement'@'localhost' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'localhost';
CREATE USER 'placement'@'%' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'%';
FLUSH PRIVILEGES;
EXIT;
```

---

## 2. Tạo user, service và endpoint API

Chạy script biến môi trường:

```bash
source ~/admin-openrc
```

Tạo user `placement`:

```bash
openstack user create --domain default --password Welcome123 placement
```

Kết quả:

```
+---------------------+----------------------------------+
| Field               | Value                            |
+---------------------+----------------------------------+
| domain_id           | default                          |
| enabled             | True                             |
| id                  | 6328b10db2734a4bbc8f022d8bee2630 |
| name                | placement                        |
| options             | {}                               |
| password_expires_at | None                             |
+---------------------+----------------------------------+
```

Gán role `admin` cho user `placement` trên project `service`:

```bash
openstack role add --project service --user placement admin
```

Tạo service entity:

```bash
openstack service create --name placement --description "Placement API" placement
```

Kết quả:

```
+-------------+----------------------------------+
| Field       | Value                            |
+-------------+----------------------------------+
| description | Placement API                    |
| enabled     | True                             |
| id          | 19372a41560d4df5ba04842174ef4ced |
| name        | placement                        |
| type        | placement                        |
+-------------+----------------------------------+
```

Tạo các endpoint API:

```bash
openstack endpoint create --region RegionOne placement public http://controller:8778
openstack endpoint create --region RegionOne placement internal http://controller:8778
openstack endpoint create --region RegionOne placement admin http://controller:8778
```

---

## 3. Cài đặt và cấu hình Placement

Cài đặt gói:

```bash
apt install -y placement-api
```

Sao lưu file cấu hình gốc:

```bash
cp /etc/placement/placement.conf /etc/placement/placement.conf.orig
```

Sửa file `/etc/placement/placement.conf`, cấu hình các section sau:

Trong section `[placement_database]`:

```ini
[placement_database]
connection = mysql+pymysql://placement:Welcome123@controller/placement
```

Trong section `[api]`:

```ini
[api]
auth_strategy = keystone
```

Trong section `[keystone_authtoken]`:

```ini
[keystone_authtoken]
auth_url = http://controller:5000/v3
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = placement
password = Welcome123
```

Đồng bộ database cho Placement:

```bash
su -s /bin/sh -c "placement-manage db sync" placement
```

---

## 4. Kết thúc cài đặt

Placement chạy qua WSGI/Apache, reload Apache để áp dụng:

```bash
systemctl restart apache2
```

---

## 5. Kiểm tra cài đặt Placement

```bash
source ~/admin-openrc
placement-status upgrade check
```

Kết quả mong đợi:

```
+----------------------------------+
| Upgrade Check Results            |
+----------------------------------+
| Check: Missing Root Provider IDs |
| Result: Success                  |
| Details: None                    |
+----------------------------------+
| Check: Incomplete Consumers      |
| Result: Success                  |
| Details: None                    |
+----------------------------------+
```

Tất cả check đều `Success` là cài đặt thành công.

---

Trước: [03-glance.md](03-glance.md) | Tiếp theo: [05-nova.md](05-nova.md)

---

## Hỏi & Đáp

### Placement là gì, đóng vai trò gì?

Placement là service theo dõi và quản lý tài nguyên (CPU, RAM, disk, GPU...) của các compute node - hoạt động như một **kế toán trưởng**.

```
Không có Placement:
Nova muốn tạo VM 2 CPU, 4GB RAM
→ Phải tự đi hỏi từng compute node "mày còn bao nhiêu tài nguyên?"
→ Chậm, không scale được

Có Placement:
Nova muốn tạo VM 2 CPU, 4GB RAM
→ Hỏi Placement 1 lần "node nào còn đủ 2 CPU + 4GB RAM?"
→ Placement trả về danh sách ngay lập tức
```

**Placement theo dõi những gì:**

```
Resource Provider (compute node)
├── VCPU:        total=8,  used=3,  free=5
├── MEMORY_MB:   total=16384, used=4096, free=12288
├── DISK_GB:     total=100, used=20, free=80
└── (custom: GPU, FPGA, SR-IOV port...)
```

**Vị trí trong flow tạo instance:**

```
Nova API
   │
   │ "Tôi cần 2 CPU + 4GB RAM"
   ▼
Placement
   │
   │ Query DB → tìm compute node phù hợp
   │ Trả về: [compute1, compute3]
   ▼
Nova Scheduler
   │
   │ Chọn compute1 (ít load hơn)
   ▼
Nova Compute → tạo VM trên compute1
   │
   │ Báo lại Placement: "đã dùng 2 CPU + 4GB RAM trên compute1"
   ▼
Placement cập nhật: compute1 used += 2 CPU, 4GB RAM
```

Placement được tách ra thành service độc lập từ OpenStack Rocky (2018), trước đó logic này nằm trong Nova và rất khó scale.
