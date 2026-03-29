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
