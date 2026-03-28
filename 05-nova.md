# Cài đặt dịch vụ Compute (Nova)

## Mục lục

1. [Cài đặt các thành phần trên node Controller](#1-cài-đặt-các-thành-phần-trên-node-controller)
2. [Cài đặt Nova Compute trên node Compute](#2-cài-đặt-nova-compute-trên-node-compute)
3. [Hoàn tất cấu hình trên node Controller](#3-hoàn-tất-cấu-hình-trên-node-controller)

---

## 1. Cài đặt các thành phần trên node Controller

> Thực hiện trên node **controller**

### 1.1 Tạo database cho Nova

Đăng nhập vào MariaDB:

```bash
mysql -u root -pWelcome123
```

Tạo 3 database và cấp quyền:

```sql
CREATE DATABASE nova_api;
CREATE DATABASE nova;
CREATE DATABASE nova_cell0;

CREATE USER 'nova'@'localhost' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost';

CREATE USER 'nova'@'%' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%';

FLUSH PRIVILEGES;
EXIT;
```

### 1.2 Tạo user, service và endpoint API

Chạy script biến môi trường:

```bash
source ~/admin-openrc
```

Tạo user `nova`:

```bash
openstack user create --domain default --password Welcome123 nova
```

Kết quả:

```
+---------------------+----------------------------------+
| Field               | Value                            |
+---------------------+----------------------------------+
| domain_id           | default                          |
| enabled             | True                             |
| id                  | d4645d60bdb14e9b9148a2e3193e744f |
| name                | nova                             |
| options             | {}                               |
| password_expires_at | None                             |
+---------------------+----------------------------------+
```

Gán role `admin` cho user `nova` trên project `service`:

```bash
openstack role add --project service --user nova admin
```

Tạo service entity:

```bash
openstack service create --name nova --description "OpenStack Compute" compute
```

Kết quả:

```
+-------------+----------------------------------+
| Field       | Value                            |
+-------------+----------------------------------+
| description | OpenStack Compute                |
| enabled     | True                             |
| id          | 29b8545253fd4bb389480040882eff31 |
| name        | nova                             |
| type        | compute                          |
+-------------+----------------------------------+
```

Tạo các endpoint API:

```bash
openstack endpoint create --region RegionOne compute public http://controller:8774/v2.1
openstack endpoint create --region RegionOne compute internal http://controller:8774/v2.1
openstack endpoint create --region RegionOne compute admin http://controller:8774/v2.1
```

### 1.3 Cài đặt và cấu hình Nova trên Controller

Cài đặt các gói:

```bash
apt install -y nova-api nova-conductor nova-novncproxy nova-scheduler
```

Sao lưu file cấu hình gốc:

```bash
cp /etc/nova/nova.conf /etc/nova/nova.conf.orig
```

Sửa file `/etc/nova/nova.conf`, cấu hình các section sau:

Trong section `[api_database]` và `[database]`:

```ini
[api_database]
connection = mysql+pymysql://nova:Welcome123@controller/nova_api

[database]
connection = mysql+pymysql://nova:Welcome123@controller/nova
```

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
enabled_apis = osapi_compute,metadata
transport_url = rabbit://openstack:Welcome123@controller:5672/
my_ip = 192.168.225.195
use_neutron = true
firewall_driver = nova.virt.firewall.NoopFirewallDriver
```

Trong section `[api]` và `[keystone_authtoken]`:

```ini
[api]
auth_strategy = keystone

[keystone_authtoken]
www_authenticate_uri = http://controller:5000/
auth_url = http://controller:5000/
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = nova
password = Welcome123
```

Trong section `[service_user]` (thêm mới nếu chưa có):

```ini
[service_user]
send_service_user_token = true
auth_url = http://controller:5000/
auth_type = password
project_domain_name = Default
project_name = service
user_domain_name = Default
username = nova
password = Welcome123
```

Trong section `[vnc]`:

```ini
[vnc]
enabled = true
server_listen = $my_ip
server_proxyclient_address = $my_ip
```

Trong section `[glance]`:

```ini
[glance]
api_servers = http://controller:9292
```

Trong section `[oslo_concurrency]`:

```ini
[oslo_concurrency]
lock_path = /var/lib/nova/tmp
```

Trong section `[placement]`:

```ini
[placement]
region_name = RegionOne
project_domain_name = Default
project_name = service
auth_type = password
user_domain_name = Default
auth_url = http://controller:5000/v3
username = placement
password = Welcome123
```

### 1.4 Đồng bộ database cho Nova

```bash
su -s /bin/sh -c "nova-manage api_db sync" nova
su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova
su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova
su -s /bin/sh -c "nova-manage db sync" nova
```

> Bỏ qua các deprecation warning nếu có.

Kiểm tra cell đã tạo:

```bash
nova-manage cell_v2 list_cells
```

Kết quả mong đợi:

```
+-------+--------------------------------------+--------------------------------------------+--------------------------------------------------------------+
|  Name |                 UUID                 |             Transport URL                  |                   Database Connection                        |
+-------+--------------------------------------+--------------------------------------------+--------------------------------------------------------------+
| cell0 | 00000000-0000-0000-0000-000000000000 |                  none:/                    | mysql+pymysql://nova:****@controller/nova_cell0?charset=utf8 |
| cell1 | 3ca28930-9d49-4a26-867e-88f7285d3b0e | rabbit://openstack:****@controller:5672/   | mysql+pymysql://nova:****@controller/nova_cell1?charset=utf8 |
+-------+--------------------------------------+--------------------------------------------+--------------------------------------------------------------+
```

### 1.5 Khởi động các dịch vụ Nova trên Controller

> Trên Ubuntu 24.04 (Flamingo), `nova-api` chạy qua Apache (không có `nova-api.service` riêng).

```bash
systemctl restart apache2
systemctl restart nova-scheduler nova-conductor nova-novncproxy
systemctl enable nova-scheduler nova-conductor nova-novncproxy
```

---

## 2. Cài đặt Nova Compute trên node Compute

> Thực hiện trên node **compute1**

### 2.1 Cài đặt gói

```bash
apt install -y nova-compute
```

Sao lưu file cấu hình gốc:

```bash
cp /etc/nova/nova.conf /etc/nova/nova.conf.orig
```

### 2.2 Cấu hình Nova Compute

Sửa file `/etc/nova/nova.conf`:

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller
my_ip = 192.168.225.196
use_neutron = true
firewall_driver = nova.virt.firewall.NoopFirewallDriver
```

Trong section `[api]` và `[keystone_authtoken]`:

```ini
[api]
auth_strategy = keystone

[keystone_authtoken]
www_authenticate_uri = http://controller:5000/
auth_url = http://controller:5000/
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = nova
password = Welcome123
```

Trong section `[service_user]` (thêm mới nếu chưa có):

```ini
[service_user]
send_service_user_token = true
auth_url = http://controller:5000/
auth_type = password
project_domain_name = Default
project_name = service
user_domain_name = Default
username = nova
password = Welcome123
```

Trong section `[vnc]`:

```ini
[vnc]
enabled = true
server_listen = 0.0.0.0
server_proxyclient_address = $my_ip
novncproxy_base_url = http://controller:6080/vnc_auto.html
```

Trong section `[glance]`:

```ini
[glance]
api_servers = http://controller:9292
```

Trong section `[oslo_concurrency]`:

```ini
[oslo_concurrency]
lock_path = /var/lib/nova/tmp
```

Trong section `[placement]`:

```ini
[placement]
region_name = RegionOne
project_domain_name = Default
project_name = service
auth_type = password
user_domain_name = Default
auth_url = http://controller:5000/v3
username = placement
password = Welcome123
```

### 2.3 Kiểm tra hỗ trợ ảo hóa phần cứng

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
```

Nếu kết quả trả về `1` hoặc lớn hơn, node hỗ trợ ảo hóa phần cứng (KVM).

Nếu kết quả là `0`, sửa file `/etc/nova/nova-compute.conf` để dùng QEMU:

```ini
[libvirt]
virt_type = qemu
```

### 2.4 Khởi động Nova Compute

```bash
systemctl restart nova-compute
systemctl enable nova-compute
```

---

## 3. Hoàn tất cấu hình trên node Controller

> Quay lại node **controller** thực hiện các bước sau

Chạy script biến môi trường:

```bash
source ~/admin-openrc
```

Kiểm tra nova-compute đã đăng ký:

```bash
openstack compute service list --service nova-compute
```

Kết quả mong đợi:

```
+----+--------------+----------+------+-------+---------+----------------------------+
| ID | Host         | Binary   | Zone | State | Status  | Updated At                 |
+----+--------------+----------+------+-------+---------+----------------------------+
|  1 | compute1     | nova-... | nova | up    | enabled | 2025-10-01T10:00:00.000000 |
+----+--------------+----------+------+-------+---------+----------------------------+
```

Discover compute hosts để thêm vào cell:

```bash
su -s /bin/sh -c "nova-manage cell_v2 discover_hosts --verbose" nova
```

Kết quả mong đợi:

```
Found 2 cell mappings.
Skipping cell0 since it does not contain hosts.
Getting compute nodes from cell 'cell1': 3ca28930-9d49-4a26-867e-88f7285d3b0e
Found 1 computes in cell: 3ca28930-9d49-4a26-867e-88f7285d3b0e
Creating host mapping for compute host 'compute1': dc48e539-3223-48d1-8a3c-47c016be15e6
```

> Mỗi khi thêm compute node mới, phải chạy lại lệnh này. Hoặc cấu hình tự động trong `/etc/nova/nova.conf`:
> ```ini
> [scheduler]
> discover_hosts_in_cells_interval = 300
> ```

Kiểm tra tất cả dịch vụ Nova:

```bash
openstack compute service list
```

Kết quả mong đợi:

```
+----+----------------+------------+----------+---------+-------+----------------------------+
| ID | Binary         | Host       | Zone     | Status  | State | Updated At                 |
+----+----------------+------------+----------+---------+-------+----------------------------+
|  1 | nova-scheduler | controller | internal | enabled | up    | 2025-10-01T10:00:00.000000 |
|  2 | nova-conductor | controller | internal | enabled | up    | 2025-10-01T10:00:00.000000 |
|  3 | nova-compute   | compute1   | nova     | enabled | up    | 2025-10-01T10:00:00.000000 |
+----+----------------+------------+----------+---------+-------+----------------------------+
```

Kiểm tra tổng thể:

```bash
nova-status upgrade check
```

Kết quả mong đợi:

```
+---------------------------+
| Upgrade Check Results     |
+---------------------------+
| Check: Cells v2           |
| Result: Success           |
| Details: None             |
+---------------------------+
| Check: Placement API      |
| Result: Success           |
| Details: None             |
+---------------------------+
| Check: Resource Providers |
| Result: Success           |
| Details: None             |
+---------------------------+
```

---

Trước: [04-placement.md](04-placement.md) | Tiếp theo: [06-neutron.md](06-neutron.md)

---

## Hỏi & Đáp

### Các thành phần của Nova là gì?

Nova gồm nhiều thành phần chạy độc lập, giao tiếp với nhau qua RabbitMQ:

```
                    USER / CLI / Horizon
                           │
                           │ HTTP
                           ▼
                      NOVA API (Apache)
                           │
                           │ RabbitMQ message
                    ┌──────┴──────┐
                    ▼             ▼
             NOVA SCHEDULER   NOVA CONDUCTOR
                    │             │
                    └──────┬──────┘
                           │ RabbitMQ message
                           ▼
                    NOVA COMPUTE (compute node)
                           │
                           ▼
                      libvirt / KVM
```

**Chi tiết từng thành phần:**

```
┌─────────────────┬──────────────────────────────────────────────────────┐
│ nova-api        │ Nhận HTTP request từ user/CLI                        │
│ (Apache)        │ Validate token với Keystone                          │
│                 │ Đẩy job vào RabbitMQ queue                           │
├─────────────────┼──────────────────────────────────────────────────────┤
│ nova-scheduler  │ Quyết định VM sẽ chạy trên compute node nào         │
│                 │ Hỏi Placement xem node nào còn tài nguyên           │
│                 │ Áp dụng filter (RAM, CPU, AZ, affinity...)           │
├─────────────────┼──────────────────────────────────────────────────────┤
│ nova-conductor  │ Trung gian giữa nova-compute và database             │
│                 │ nova-compute KHÔNG được query DB trực tiếp           │
│                 │ Mọi DB operation phải qua conductor                  │
│                 │ Tăng bảo mật: compromise compute không lộ DB        │
├─────────────────┼──────────────────────────────────────────────────────┤
│ nova-compute    │ Chạy trên compute node                               │
│                 │ Gọi libvirt để tạo/xóa/resize VM                    │
│                 │ Báo cáo tài nguyên lên Placement                    │
│                 │ Quản lý vòng đời instance                            │
├─────────────────┼──────────────────────────────────────────────────────┤
│ nova-novncproxy │ Web proxy cho VNC console                            │
│                 │ User mở browser → novncproxy → VM console           │
│                 │ Chạy port 6080                                       │
└─────────────────┴──────────────────────────────────────────────────────┘
```

**Flow tạo instance chi tiết:**

```
1. User: "Tạo VM flavor m1.small, image cirros"
         │
2. nova-api nhận request, validate token Keystone
         │
3. nova-api gửi message vào RabbitMQ: "create_instance"
         │
4. nova-scheduler nhận message
   → Hỏi Placement: node nào còn 1 CPU + 2GB RAM?
   → Placement trả về: [compute1]
   → Scheduler chọn compute1
         │
5. nova-conductor nhận task
   → Lưu trạng thái VM vào DB (status: BUILDING)
   → Hỏi Glance lấy image URL
   → Hỏi Neutron tạo network port
         │
6. nova-compute trên compute1 nhận lệnh
   → Download image từ Glance
   → Gọi libvirt tạo VM
   → Báo Placement: đã dùng 1 CPU + 2GB RAM
   → Báo conductor: VM đã ACTIVE
         │
7. conductor cập nhật DB: status = ACTIVE
8. User thấy VM đang chạy
```

---

### Các command quản trị và debug Nova

**Kiểm tra trạng thái service:**

```bash
# Xem tất cả nova service
openstack compute service list

# Xem hypervisor
openstack hypervisor list
openstack hypervisor show compute1

# Xem tài nguyên tổng
openstack hypervisor stats show
```

**Quản lý instance:**

```bash
# Liệt kê tất cả instance (tất cả project)
openstack server list --all-projects

# Xem chi tiết instance
openstack server show <instance-id>

# Xem log console
openstack console log show <instance-id>

# Lấy VNC URL
openstack console url show <instance-id>

# Reboot
openstack server reboot <instance-id>
openstack server reboot --hard <instance-id>

# Stop/Start
openstack server stop <instance-id>
openstack server start <instance-id>

# Xóa
openstack server delete <instance-id>
```

**nova-manage - công cụ quản trị trực tiếp:**

```bash
# Xem cell
nova-manage cell_v2 list_cells

# Discover compute node mới
nova-manage cell_v2 discover_hosts --verbose

# Kiểm tra upgrade
nova-status upgrade check

# Xem version DB schema
nova-manage db version
nova-manage api_db version

# Dọn dẹp các bản ghi đã xóa trong DB
nova-manage db archive_deleted_rows --max_rows 100
```

**Debug - xem log:**

```bash
# Nova API (chạy qua Apache)
tail -f /var/log/apache2/nova-api.log

# Các service khác (trên controller)
tail -f /var/log/nova/nova-scheduler.log
tail -f /var/log/nova/nova-conductor.log

# Trên compute node
tail -f /var/log/nova/nova-compute.log

# Xem lý do instance bị lỗi
openstack server show <id> -f value -c fault
```

**Kiểm tra kết nối RabbitMQ:**

```bash
rabbitmqctl list_queues | grep nova
rabbitmqctl list_connections | grep nova
```

---

### Cell là gì?

Cell là cơ chế phân vùng compute node trong Nova để scale lớn hơn.

Hình dung một cloud lớn có hàng nghìn compute node - nếu tất cả dùng chung 1 database và 1 RabbitMQ thì sẽ bị bottleneck. Cell giải quyết bằng cách chia nhỏ:

```
                    nova-api (global)
                    nova-scheduler (global)
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
           cell0         cell1        cell2
           (đặc biệt)    │            │
                    ┌────┴───┐   ┌────┴───┐
                    DB  MQ   │   DB  MQ   │
                    │        │   │        │
                 compute1  compute2  compute3  compute4
```

**cell0 - đặc biệt:**
- Không chứa compute node nào
- Lưu các instance bị lỗi scheduling (không tìm được node phù hợp)
- UUID cố định: `00000000-0000-0000-0000-000000000000`

**cell1 - cell thông thường:**
- Chứa các compute node thực tế
- Có DB và RabbitMQ riêng
- Trong lab này tất cả compute node đều ở cell1

**Tại sao lab nhỏ vẫn cần cell?**

Từ OpenStack Queens, cell v2 là bắt buộc dù chỉ có 1 cell. Nova không chạy được nếu không có cell0 và cell1.

```
nova-manage cell_v2 map_cell0      → tạo cell0 (bắt buộc)
nova-manage cell_v2 create_cell    → tạo cell1 (chứa compute node)
nova-manage cell_v2 discover_hosts → đăng ký compute node vào cell1
```

Trong production lớn có thể tạo nhiều cell:

```bash
nova-manage cell_v2 create_cell --name=cell-hanoi
nova-manage cell_v2 create_cell --name=cell-hcm
```

---

### Database và RabbitMQ của cell là gì?

Đây là lý do Nova tạo 3 database thay vì 1:

```
nova_api    → DB global, dùng chung cho tất cả cell
              Lưu: flavor, keypair, quota, aggregate...
              nova-api và nova-scheduler đọc/ghi vào đây

nova_cell0  → DB của cell0
              Lưu instance bị lỗi scheduling

nova        → DB của cell1
              Lưu: instance, migration, console, block device...
              nova-conductor và nova-compute đọc/ghi vào đây
```

Trong lab này cả 3 DB đều nằm trên cùng 1 MariaDB server (controller). Trong production lớn mỗi cell có DB server riêng:

```
Controller (global)
├── MariaDB: nova_api      ← nova-api, nova-scheduler dùng
│
Cell1 (datacenter HN)
├── MariaDB: nova_cell1    ← nova-conductor, nova-compute HN dùng
├── RabbitMQ: rabbit-hn    ← message queue riêng cho cell1
│
Cell2 (datacenter HCM)
├── MariaDB: nova_cell2    ← nova-conductor, nova-compute HCM dùng
└── RabbitMQ: rabbit-hcm   ← message queue riêng cho cell2
```

**RabbitMQ của cell:**

Mỗi cell có RabbitMQ riêng để:
- nova-conductor và nova-compute trong cell giao tiếp nội bộ
- Tránh message của cell này lẫn vào cell kia
- Nếu RabbitMQ 1 cell chết, cell khác vẫn hoạt động

Trong lab chỉ có 1 RabbitMQ server dùng chung. Kiểm tra connection string của từng cell:

```bash
nova-manage cell_v2 list_cells
# cell1: rabbit://openstack:****@controller:5672/
#        mysql+pymysql://nova:****@controller/nova
```
