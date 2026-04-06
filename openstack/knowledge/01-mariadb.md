# MariaDB trong OpenStack

## MariaDB là gì?

MariaDB là hệ quản trị cơ sở dữ liệu quan hệ (RDBMS) - fork của MySQL. Trong OpenStack, MariaDB đóng vai trò **kho lưu trữ trạng thái** cho tất cả các service.

## Vai trò trong OpenStack

Mỗi service có database riêng:

```
MariaDB Server (controller)
├── keystone      ← user, project, role, endpoint, token
├── glance        ← image metadata (không lưu file image)
├── placement     ← resource provider, inventory, allocation
├── nova_api      ← flavor, keypair, quota (global)
├── nova          ← instance, migration, console (cell1)
├── nova_cell0    ← instance bị lỗi scheduling
├── neutron       ← network, subnet, port, router, security group
└── cinder        ← volume, snapshot, backup metadata
```

## Tại sao bind-address = Management IP?

```ini
bind-address = 192.168.225.195
```

Mặc định MariaDB chỉ listen `127.0.0.1` - chỉ local access. OpenStack cần các service trên các node khác kết nối vào DB qua Management network, nên phải bind ra Management IP.

Không bind ra `0.0.0.0` vì không muốn expose DB ra Provider network (internet).

## Cấu hình InnoDB

```ini
default-storage-engine = innodb
innodb_file_per_table = on
```

- **InnoDB**: storage engine hỗ trợ transaction, foreign key - cần thiết cho tính nhất quán dữ liệu
- **innodb_file_per_table**: mỗi table lưu trong file riêng → dễ quản lý, dễ reclaim disk space

## Connection pooling

```ini
max_connections = 4096
```

OpenStack có nhiều service, mỗi service có nhiều worker process, mỗi worker có connection pool riêng. Với lab 2 node, 4096 là dư thừa nhưng không gây hại.

## Luồng kết nối

```
Nova API (controller)
    │
    │ connection string:
    │ mysql+pymysql://nova:Welcome123@controller/nova_api
    ▼
MariaDB (192.168.225.195:3306)
    │
    │ authenticate user nova
    │ select database nova_api
    ▼
Execute SQL query
```

**pymysql** là Python driver thuần Python để kết nối MySQL/MariaDB, không cần cài thêm C library.

## Backup và restore cơ bản

```bash
# Backup tất cả database OpenStack
mysqldump -u root -pWelcome123 --databases \
  keystone glance placement nova_api nova nova_cell0 neutron \
  > openstack_backup.sql

# Restore
mysql -u root -pWelcome123 < openstack_backup.sql
```

## Debug

```bash
# Xem các connection đang active
mysql -u root -pWelcome123 -e "SHOW PROCESSLIST;"

# Xem size từng database
mysql -u root -pWelcome123 -e "
SELECT table_schema, 
  ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
FROM information_schema.tables
GROUP BY table_schema;"
```

---

## Cấu trúc bên trong MariaDB

### Storage Engine InnoDB

```
InnoDB Architecture:
┌─────────────────────────────────────────────┐
│              Buffer Pool (RAM)               │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  │
│  │ Data Page│  │Index Page│  │ Undo Log  │  │
│  └──────────┘  └──────────┘  └───────────┘  │
└─────────────────────────────────────────────┘
         │ flush khi đầy hoặc checkpoint
         ▼
┌─────────────────────────────────────────────┐
│                  Disk                        │
│  ┌──────────────┐  ┌──────────────────────┐  │
│  │  .ibd files  │  │  ib_logfile0/1       │  │
│  │ (table data) │  │  (redo log/WAL)      │  │
│  └──────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────┘
```

- **Buffer Pool**: cache data/index pages trong RAM - đọc nhanh hơn disk
- **Redo Log (WAL)**: ghi thay đổi vào log trước khi ghi vào data file - đảm bảo durability
- **.ibd files**: mỗi table 1 file (do `innodb_file_per_table = on`)

### Transaction và ACID

InnoDB đảm bảo ACID - quan trọng với OpenStack vì nhiều service ghi DB đồng thời:

```
A - Atomicity:   transaction hoặc thành công toàn bộ hoặc rollback toàn bộ
C - Consistency: DB luôn ở trạng thái hợp lệ
I - Isolation:   transaction không ảnh hưởng nhau
D - Durability:  dữ liệu đã commit không bị mất dù crash
```

Ví dụ: Nova tạo instance cần ghi vào nhiều bảng (instances, instance_info_caches, block_device_mapping...) - nếu crash giữa chừng, InnoDB rollback toàn bộ, không để DB ở trạng thái nửa vời.

### Cấu trúc file trên disk

```bash
ls /var/lib/mysql/
```

```
/var/lib/mysql/
├── ibdata1          ← system tablespace (shared)
├── ib_logfile0      ← redo log file 0
├── ib_logfile1      ← redo log file 1
├── keystone/
│   ├── db.opt       ← database options (charset)
│   ├── user.ibd     ← user table data + index
│   ├── project.ibd
│   └── ...
├── nova/
│   ├── instances.ibd
│   ├── instance_info_caches.ibd
│   └── ...
└── nova_api/
    ├── flavors.ibd
    └── ...
```

### Schema quan trọng của từng DB

```sql
-- Keystone: user và role assignment
USE keystone;
SHOW TABLES;
-- user, project, role, assignment, endpoint, service, token...

-- Nova: instance lifecycle
USE nova;
SHOW TABLES;
-- instances, instance_actions, instance_faults, migrations...

-- Neutron: network topology
USE neutron;
SHOW TABLES;
-- networks, subnets, ports, routers, floatingips, securitygroups...
```

---

## Lab: Khám phá MariaDB trong OpenStack

### Alias hữu ích - thêm vào ~/.bashrc

```bash
cat >> ~/.bashrc << 'EOF'

# MariaDB OpenStack aliases
alias mysql-os='mysql -u root -pWelcome123'
alias mysql-ks='mysql -u root -pWelcome123 keystone'
alias mysql-nova='mysql -u root -pWelcome123 nova'
alias mysql-nova-api='mysql -u root -pWelcome123 nova_api'
alias mysql-glance='mysql -u root -pWelcome123 glance'
alias mysql-neutron='mysql -u root -pWelcome123 neutron'
alias mysql-placement='mysql -u root -pWelcome123 placement'

# Xem size tất cả DB
alias mysql-size='mysql -u root -pWelcome123 -e "
SELECT table_schema AS \"Database\",
  ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS \"Size (MB)\"
FROM information_schema.tables
GROUP BY table_schema
ORDER BY 2 DESC;"'

# Xem connection đang active
alias mysql-conn='mysql -u root -pWelcome123 -e "SHOW PROCESSLIST;"'
EOF

source ~/.bashrc
```

---

### 1. Khám phá cấu trúc database

```bash
# Xem tất cả database
mysql-os -e "SHOW DATABASES;"

# Xem size từng DB
mysql-size

# Xem tables trong keystone
mysql-ks -e "SHOW TABLES;"

# Xem schema của bảng user
mysql-ks -e "DESCRIBE user;"

# Xem schema của bảng instances trong nova
mysql-nova -e "DESCRIBE instances;"
```

---

### 2. Theo dõi DB khi tạo instance

Mở 2 terminal:

**Terminal 1 - watch DB:**
```bash
# Xem instances table thay đổi
watch -n 2 "mysql -u root -pWelcome123 nova \
  -e 'SELECT uuid, hostname, vm_state, task_state, host FROM instances ORDER BY created_at DESC LIMIT 5\G'"
```

**Terminal 2 - tạo instance:**
```bash
source ~/demo-openrc
NET_ID=$(openstack network list --name selfservice-net -f value -c ID)
openstack server create --flavor m1.tiny --image cirros \
  --nic net-id=$NET_ID db-test-vm
```

**Quan sát:** `vm_state` thay đổi từ `building` → `active`, `task_state` thay đổi qua các bước.

---

### 3. Xem dữ liệu thực tế trong DB

```bash
# Xem user trong Keystone
mysql-ks -e "SELECT id, name, enabled FROM user\G"

# Xem project
mysql-ks -e "SELECT id, name, domain_id FROM project\G"

# Xem role assignment (ai có role gì trong project nào)
mysql-ks -e "
SELECT
  u.name AS user,
  r.name AS role,
  p.name AS project
FROM assignment a
JOIN user u ON a.actor_id = u.id
JOIN role r ON a.role_id = r.id
LEFT JOIN project p ON a.target_id = p.id
WHERE a.type = 'UserProject'\G"

# Xem flavor trong nova_api
mysql-nova-api -e "SELECT id, name, memory_mb, vcpus, root_gb FROM flavors\G"

# Xem network trong neutron
mysql-neutron -e "SELECT id, name, status, admin_state_up FROM networks\G"

# Xem port của instance
mysql-neutron -e "
SELECT id, network_id, mac_address, status, device_owner
FROM ports
WHERE device_owner LIKE 'compute%'\G"
```

---

### 4. Xem instance lifecycle trong DB

```bash
# Xem instance hiện tại
mysql-nova -e "
SELECT uuid, hostname, vm_state, task_state, host, created_at
FROM instances
WHERE deleted = 0\G"

# Xem action history của instance
INSTANCE_ID=$(openstack server show db-test-vm -f value -c id)
mysql-nova -e "
SELECT action, start_time, finish_time, message
FROM instance_actions
WHERE instance_uuid = '$INSTANCE_ID'
ORDER BY start_time\G"

# Xem lỗi nếu có
mysql-nova -e "
SELECT instance_uuid, code, message, created_at
FROM instance_faults
ORDER BY created_at DESC LIMIT 5\G"
```

---

### 5. Xem Placement data

```bash
# Xem resource provider (compute node)
mysql-placement -e "SELECT uuid, name FROM resource_providers\G"

# Xem inventory (tài nguyên có sẵn)
mysql-placement -e "
SELECT rp.name, rc.name AS resource_class,
  i.total, i.reserved, i.allocation_ratio
FROM inventories i
JOIN resource_providers rp ON i.resource_provider_id = rp.id
JOIN resource_classes rc ON i.resource_class_id = rc.id\G"

# Xem allocation (tài nguyên đã dùng)
mysql-placement -e "
SELECT rp.name AS provider, rc.name AS resource_class,
  a.used, a.consumer_id
FROM allocations a
JOIN resource_providers rp ON a.resource_provider_id = rp.id
JOIN resource_classes rc ON a.resource_class_id = rc.id\G"
```

---

### 6. Monitor performance

```bash
# Xem slow queries (nếu có)
mysql-os -e "SHOW VARIABLES LIKE 'slow_query%';"
mysql-os -e "SHOW VARIABLES LIKE 'long_query_time';"

# Xem InnoDB status
mysql-os -e "SHOW ENGINE INNODB STATUS\G" | head -50

# Xem buffer pool hit rate
mysql-os -e "
SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read%';" 
# Tính hit rate = (reads - reads_disk) / reads * 100
# Hit rate > 95% là tốt

# Xem connection stats
mysql-os -e "SHOW GLOBAL STATUS LIKE 'Threads%';"
mysql-os -e "SHOW GLOBAL STATUS LIKE 'Max_used_connections';"
```

---

### 7. Dọn dẹp sau lab

```bash
source ~/admin-openrc
openstack server delete db-test-vm 2>/dev/null || true
```
