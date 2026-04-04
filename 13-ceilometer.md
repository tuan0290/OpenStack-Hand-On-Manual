# Cài đặt Telemetry (Ceilometer + Gnocchi + Aodh)

> Telemetry stack gồm 3 service phối hợp:
> - **Ceilometer**: thu thập metrics từ các service OpenStack
> - **Gnocchi**: lưu trữ và query time-series metrics
> - **Aodh**: alarming - cảnh báo khi metric vượt ngưỡng

## Kiến trúc

```
Nova/Neutron/Cinder...
    │ notifications (RabbitMQ)
    ▼
ceilometer-agent-notification
    │
    ▼
ceilometer-agent-central (polling)
    │
    │ gửi metrics
    ▼
Gnocchi (time-series DB)
    │
    ├── gnocchi-api (port 8041)    ← query metrics
    └── gnocchi-metricd            ← xử lý và lưu metrics
    │
    ▼
Aodh (alarming)
    │
    ├── aodh-api (port 8042)       ← quản lý alarm
    ├── aodh-evaluator             ← đánh giá alarm
    └── aodh-notifier              ← gửi notification khi alarm trigger
```

## Mục lục

1. [Cài đặt Gnocchi trên Controller](#1-cài-đặt-gnocchi-trên-controller)
2. [Cài đặt Ceilometer trên Controller](#2-cài-đặt-ceilometer-trên-controller)
3. [Cài đặt Ceilometer trên Compute Node](#3-cài-đặt-ceilometer-trên-compute-node)
4. [Cài đặt Aodh trên Controller](#4-cài-đặt-aodh-trên-controller)
5. [Kiểm tra](#5-kiểm-tra)
6. [Lab: Query metrics và tạo Alarm](#6-lab-query-metrics-và-tạo-alarm)

---

## 1. Cài đặt Gnocchi trên Controller

> Thực hiện trên node **controller**

### 1.1 Tạo user và endpoint Gnocchi trong Keystone

```bash
source ~/admin-openrc

openstack user create --domain default --password Welcome123 gnocchi
openstack role add --project service --user gnocchi admin

openstack service create --name gnocchi \
  --description "Metric Service" metric

openstack endpoint create --region RegionOne metric public http://controller:8041
openstack endpoint create --region RegionOne metric internal http://controller:8041
openstack endpoint create --region RegionOne metric admin http://controller:8041
```

### 1.2 Tạo database Gnocchi

```bash
mysql -u root -pWelcome123
```

```sql
CREATE DATABASE gnocchi;
CREATE USER 'gnocchi'@'localhost' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON gnocchi.* TO 'gnocchi'@'localhost';
CREATE USER 'gnocchi'@'%' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON gnocchi.* TO 'gnocchi'@'%';
FLUSH PRIVILEGES;
EXIT;
```

### 1.3 Cài đặt Gnocchi

```bash
apt install -y gnocchi-api gnocchi-metricd python3-gnocchiclient
apt install -y uwsgi-plugin-python3 uwsgi
# Redis dùng cho coordination (cải thiện performance với nhiều worker)
apt install -y redis-server
```

Trong quá trình cài, `apt` sẽ hỏi cấu hình database qua **dbconfig-common**:

```
Configure database for gnocchi-common with dbconfig-common? → No
```

> Chọn **No** vì đã tạo database thủ công ở bước 1.2. Nếu lỡ chọn Yes → chọn **mysql** và điền:
> - Database host: `controller`
> - Database name: `gnocchi`
> - Database user: `gnocchi`
> - Database password: `Welcome123`

### 1.4 Cấu hình Gnocchi

Sửa file `/etc/gnocchi/gnocchi.conf`:

Trong section `[api]`:

```ini
[api]
auth_mode = keystone
port = 8041
uwsgi_mode = http-socket
```

Trong section `[keystone_authtoken]`:

```ini
[keystone_authtoken]
auth_type = password
auth_url = http://controller:5000/v3
project_domain_name = Default
user_domain_name = Default
project_name = service
username = gnocchi
password = Welcome123
interface = internalURL
region_name = RegionOne
```

Trong section `[indexer]`:

```ini
[indexer]
url = mysql+pymysql://gnocchi:Welcome123@controller/gnocchi
```

Trong section `[storage]`:

```ini
[storage]
# coordination_url giúp phân chia workload giữa các worker
coordination_url = redis://controller:6379
file_basepath = /var/lib/gnocchi
driver = file
```

### 1.5 Khởi tạo và khởi động Gnocchi

```bash
# Khởi tạo database và storage
gnocchi-upgrade

# Phân quyền thư mục storage
chown -R gnocchi:gnocchi /var/lib/gnocchi

systemctl restart gnocchi-api gnocchi-metricd
systemctl enable gnocchi-api gnocchi-metricd

# Verify
systemctl status gnocchi-api gnocchi-metricd
curl http://controller:8041/
```

---

## 2. Cài đặt Ceilometer trên Controller

> Thực hiện trên node **controller**

### 2.1 Tạo user Ceilometer trong Keystone

```bash
source ~/admin-openrc

openstack user create --domain default --password Welcome123 ceilometer
openstack role add --project service --user ceilometer admin

openstack service create --name ceilometer \
  --description "Telemetry" metering
```

> Ceilometer không cần endpoint vì không có API riêng - nó push data vào Gnocchi.

### 2.2 Cài đặt package

```bash
apt install -y ceilometer-agent-notification ceilometer-agent-central
```

### 2.3 Cấu hình Ceilometer

Sửa file `/etc/ceilometer/pipeline.yaml`, tìm section `publishers` và cấu hình Gnocchi:

```yaml
publishers:
    - gnocchi://?filter_project=service&archive_policy=low
```

> Nếu không có file `pipeline.yaml`, kiểm tra `/etc/ceilometer/polling.yaml` - từ 2024.x trở đi Ceilometer tách polling config riêng. File `pipeline.yaml` vẫn dùng cho publishers.

Sửa file `/etc/ceilometer/ceilometer.conf`:

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller
```

Trong section `[service_credentials]`:

```ini
[service_credentials]
auth_type = password
auth_url = http://controller:5000/v3
project_domain_id = default
user_domain_id = default
project_name = service
username = ceilometer
password = Welcome123
interface = internalURL
region_name = RegionOne
```

### 2.4 Khởi tạo Ceilometer resources trong Gnocchi

```bash
# Gnocchi phải đang chạy trước khi chạy lệnh này
ceilometer-upgrade
```

> Nếu gặp lỗi `ceilometer-upgrade: command not found`, dùng:
> ```bash
> ceilometer-agent-notification --config-file /etc/ceilometer/ceilometer.conf &
> # hoặc
> python3 -m ceilometer.cmd.agent_notification --config-file /etc/ceilometer/ceilometer.conf
> ```

### 2.5 Khởi động service

```bash
systemctl restart ceilometer-agent-central ceilometer-agent-notification
systemctl enable ceilometer-agent-central ceilometer-agent-notification
```

---

## 3. Cài đặt Ceilometer trên Compute Node

> Thực hiện trên node **compute1**

### 3.1 Cài đặt package

```bash
apt install -y ceilometer-agent-compute
```

### 3.2 Cấu hình

Sửa `/etc/ceilometer/ceilometer.conf`:

```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller

[service_credentials]
auth_type = password
auth_url = http://controller:5000/v3
project_domain_id = default
user_domain_id = default
project_name = service
username = ceilometer
password = Welcome123
interface = internalURL
region_name = RegionOne
```

Thêm vào `/etc/nova/nova.conf` trên compute1:

```ini
[DEFAULT]
instance_usage_audit = True
instance_usage_audit_period = hour

[notifications]
notify_on_state_change = vm_and_task_state
```

### 3.3 Khởi động service

```bash
systemctl restart ceilometer-agent-compute nova-compute
systemctl enable ceilometer-agent-compute
```

---

## 4. Cài đặt Aodh trên Controller

> Thực hiện trên node **controller**

### 4.1 Tạo database và user

```bash
mysql -u root -pWelcome123
```

```sql
CREATE DATABASE aodh;
CREATE USER 'aodh'@'localhost' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON aodh.* TO 'aodh'@'localhost';
CREATE USER 'aodh'@'%' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON aodh.* TO 'aodh'@'%';
FLUSH PRIVILEGES;
EXIT;
```

### 4.2 Tạo user và endpoint trong Keystone

```bash
source ~/admin-openrc

openstack user create --domain default --password Welcome123 aodh
openstack role add --project service --user aodh admin

openstack service create --name aodh \
  --description "Telemetry Alarming" alarming

openstack endpoint create --region RegionOne alarming public http://controller:8042
openstack endpoint create --region RegionOne alarming internal http://controller:8042
openstack endpoint create --region RegionOne alarming admin http://controller:8042
```

### 4.3 Cài đặt package

```bash
apt install -y aodh-api aodh-evaluator aodh-notifier \
  aodh-listener aodh-expirer python3-aodhclient
```

### 4.4 Cấu hình Aodh

Sửa file `/etc/aodh/aodh.conf`:

Trong section `[database]`:

```ini
[database]
connection = mysql+pymysql://aodh:Welcome123@controller/aodh
```

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller
auth_strategy = keystone
```

Trong section `[keystone_authtoken]`:

```ini
[keystone_authtoken]
www_authenticate_uri = http://controller:5000
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = aodh
password = Welcome123
```

Trong section `[service_credentials]`:

```ini
[service_credentials]
auth_type = password
auth_url = http://controller:5000/v3
project_domain_id = default
user_domain_id = default
project_name = service
username = aodh
password = Welcome123
interface = internalURL
region_name = RegionOne
```

Trong section `[oslo_concurrency]`:

```ini
[oslo_concurrency]
lock_path = /var/lib/aodh/tmp
```

### 4.5 Đồng bộ database và khởi động

```bash
su -s /bin/sh -c "aodh-dbsync" aodh

systemctl restart aodh-api aodh-evaluator aodh-notifier aodh-listener
systemctl enable aodh-api aodh-evaluator aodh-notifier aodh-listener
```

---

## 5. Kiểm tra

```bash
source ~/admin-openrc

# Kiểm tra Gnocchi API
curl http://controller:8041/
openstack metric status

# Kiểm tra resource types đã được tạo bởi ceilometer-upgrade
openstack metric resource-type list

# Kiểm tra Ceilometer đang thu thập metrics (chờ 1-2 phút sau khi start)
openstack metric resource list --type instance

# Kiểm tra Aodh
openstack alarm list
```

---

## 6. Lab: Query metrics và tạo Alarm

### 6.1 Xem metrics của instance

```bash
source ~/admin-openrc

# Xem tất cả resource
openstack metric resource list

# Lấy ID của instance
INSTANCE_ID=$(openstack server show my-first-instance -f value -c id)

# Xem metrics của instance
openstack metric resource show $INSTANCE_ID

# Xem CPU usage
openstack metric measures show \
  --resource-id $INSTANCE_ID \
  cpu_util
```

### 6.2 Tạo Alarm - cảnh báo khi CPU cao

```bash
source ~/demo-openrc

INSTANCE_ID=$(openstack server show my-first-instance -f value -c id)

# Tạo alarm: cảnh báo khi CPU > 80% trong 5 phút
openstack alarm create \
  --name cpu-high-alarm \
  --type gnocchi_resources_threshold \
  --description "CPU usage > 80%" \
  --metric cpu_util \
  --threshold 80 \
  --comparison-operator gt \
  --aggregation-method mean \
  --granularity 300 \
  --evaluation-periods 1 \
  --resource-id $INSTANCE_ID \
  --resource-type instance \
  --alarm-action "log://" \
  --ok-action "log://"

# Xem alarm
openstack alarm list
openstack alarm show cpu-high-alarm
```

### 6.3 Xem lịch sử alarm

```bash
openstack alarm-history show cpu-high-alarm
```

### 6.4 Các loại alarm phổ biến

```bash
# Alarm theo threshold (ngưỡng)
openstack alarm create --type gnocchi_resources_threshold ...

# Alarm theo combination (kết hợp nhiều alarm)
openstack alarm create --type combination \
  --alarm-ids alarm1,alarm2 \
  --operator and ...

# Alarm theo event (sự kiện)
openstack alarm create --type event \
  --event-type compute.instance.* ...
```

### 6.5 Dọn dẹp

```bash
openstack alarm delete cpu-high-alarm
```

---

Trước: [12-octavia.md](12-octavia.md)
