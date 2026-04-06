# Cài đặt Block Storage (Cinder)

> Cinder cung cấp persistent block storage (volume) cho VM.
> Volume tồn tại độc lập với VM - xóa VM không mất data.

## Mục lục

1. [Mô hình triển khai](#1-mô-hình-triển-khai)
2. [Chuẩn bị VM Storage Node](#2-chuẩn-bị-vm-storage-node)
3. [Cài đặt Cinder trên Controller](#3-cài-đặt-cinder-trên-controller)
4. [Cài đặt Cinder Volume trên Storage Node](#4-cài-đặt-cinder-volume-trên-storage-node)
5. [Kiểm tra](#5-kiểm-tra)

---

## 1. Mô hình triển khai

Thêm 1 VM mới đóng vai trò **Storage Node** riêng biệt:

```
                    [VMware NAT (VMnet8)]
                     192.168.182.0/24
                    /         |         \
      [CONTROLLER]    [COMPUTE1]    [STORAGE1]
      (đã có)         (đã có)       (VM mới)
                                    ens33: 192.168.182.197 (NAT - internet)
                                    ens37: 192.168.225.197 (Management)
                                    /dev/sdb: 50GB (Cinder LVM)
```

**IP Planning bổ sung:**

| Hostname | VMware Net | Interface | IP Address | Netmask | Gateway | DNS |
|---|---|---|---|---|---|---|
| storage1 | VMnet8 (NAT) | ens33 | 192.168.182.197 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 |
| storage1 | VMnet1 (Host-only) | ens37 | 192.168.225.197 | 255.255.255.0 | | |

**Yêu cầu phần cứng Storage Node:**

| Node | vCPU | RAM | Disk 1 (OS) | Disk 2 (Cinder) |
|---|---|---|---|---|
| storage1 | 2 | 2 GB | 20 GB | 50 GB |

> `ens33` (VMnet8/NAT) dùng để download packages khi cài đặt.
> `ens37` (VMnet1) là Management network - giao tiếp với controller và compute.

---

## 2. Chuẩn bị VM Storage Node

### 2.1 Tạo VM trong VMware

Trong **VM Settings**, cấu hình **2 disk riêng biệt**:

```
storage1 VM:
├── Hard Disk 1: 20 GB  ← Ubuntu cài OS vào đây
└── Hard Disk 2: 50 GB  ← để trống, dùng cho Cinder LVM sau khi cài xong
```

Cách thêm disk 2 trong VMware:
- VM Settings → Add → Hard Disk → Next → SCSI → Create new → 50GB

Network Adapter:

| Adapter | Kết nối vào | Mục đích |
|---|---|---|
| Network Adapter 1 | VMnet8 (NAT) | Internet để cài packages |
| Network Adapter 2 | VMnet1 (Host-only) | Management |

> Khi cài Ubuntu, chọn **Disk 1 (20GB)** làm installation target. Disk 2 (50GB) để nguyên, không format, không mount. Sau khi cài xong sẽ thấy `/dev/sdb` trống sẵn sàng cho LVM.

![Cấu hình storageVM](/image/storage1.png)

### 2.2 Cấu hình OS cơ bản

Sau khi cài Ubuntu 24.04, thực hiện trên **storage1**:

```bash
apt update && apt upgrade -y
```

Cấu hình network `/etc/netplan/50-cloud-init.yaml`:

```yaml
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - 192.168.182.197/24
      routes:
        - to: default
          via: 192.168.182.2
      nameservers:
        addresses: [8.8.8.8]
    ens37:
      addresses:
        - 192.168.225.197/24
```

```bash
chmod 600 /etc/netplan/50-cloud-init.yaml
netplan apply
```

Cấu hình hostname:

```bash
hostnamectl set-hostname storage1
```

Sửa `/etc/hosts` trên **tất cả node** (controller, compute1, storage1):

```
192.168.225.195    controller
192.168.225.196    compute1
192.168.225.197    storage1
```

> Dùng **Management IP** (`192.168.225.x`) cho hostname, không dùng Provider IP (`192.168.182.x`). Chrony và các service OpenStack giao tiếp qua Management network.

Cài đặt NTP đồng bộ từ controller:

```bash
apt install -y chrony
```

Sửa `/etc/chrony/chrony.conf`:

```
server controller iburst
```

```bash
rm -f /run/chrony-dhcp/* /etc/chrony/sources.d/*
systemctl restart chrony
```

Kiểm tra đồng bộ từ controller:

```bash
chronyc sources
```

Kết quả mong đợi:

```
210 Number of sources = 1
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
^* controller                    3   6    17    23    -10ns[+6000ns] +/-  248ms
```

Cài đặt OpenStack repository:

```bash
apt install -y software-properties-common
add-apt-repository cloud-archive:flamingo -y
apt update && apt dist-upgrade -y
apt install -y python3-openstackclient
reboot
```

### 2.3 Chuẩn bị LVM trên Storage Node

Kiểm tra disk 2:

```bash
lsblk
# Phải thấy /dev/sdb chưa được dùng
```

Cài đặt LVM tools:

```bash
apt install -y lvm2 thin-provisioning-tools
```

Tạo LVM Physical Volume:

```bash
pvcreate /dev/sdb
```

Kết quả:
```
Physical volume "/dev/sdb" successfully created
```

Tạo Volume Group:

```bash
vgcreate cinder-volumes /dev/sdb
```

Kết quả:
```
Volume group "cinder-volumes" successfully created
```

Cấu hình LVM filter, sửa `/etc/lvm/lvm.conf` trong section `devices`:

```ini
devices {
    filter = ["a/sda/", "a/sdb/", "r/.*/"]
}
```

> `a/sda/` = accept sda (OS disk), `a/sdb/` = accept sdb (Cinder disk), `r/.*/` = reject tất cả còn lại.

---

## 3. Cài đặt Cinder trên Controller

> Thực hiện trên node **controller**

### 3.1 Tạo database

```bash
mysql -u root -pWelcome123
```

```sql
CREATE DATABASE cinder;
CREATE USER 'cinder'@'localhost' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost';
CREATE USER 'cinder'@'%' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%';
FLUSH PRIVILEGES;
EXIT;
```

### 3.2 Tạo user, service và endpoint

```bash
source ~/admin-openrc
```

```bash
openstack user create --domain default --password Welcome123 cinder
openstack role add --project service --user cinder admin
```

```bash
openstack service create --name cinderv3 \
  --description "OpenStack Block Storage" volumev3
```

Kết quả:
```
+-------------+----------------------------------+
| Field       | Value                            |
+-------------+----------------------------------+
| description | OpenStack Block Storage          |
| enabled     | True                             |
| id          | ab3bbbef780845a1a283490d281e7fda |
| name        | cinderv3                         |
| type        | volumev3                         |
+-------------+----------------------------------+
```

```bash
openstack endpoint create --region RegionOne \
  volumev3 public http://controller:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne \
  volumev3 internal http://controller:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne \
  volumev3 admin http://controller:8776/v3/%\(project_id\)s
```

### 3.3 Cài đặt package

```bash
apt install -y cinder-api cinder-scheduler
```

### 3.4 Cấu hình Cinder

Sao lưu file cấu hình gốc:

```bash
cp /etc/cinder/cinder.conf /etc/cinder/cinder.conf.orig
```

Sửa file `/etc/cinder/cinder.conf`:

Trong section `[database]`:

```ini
[database]
connection = mysql+pymysql://cinder:Welcome123@controller/cinder
```

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller
auth_strategy = keystone
my_ip = 192.168.225.195
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
username = cinder
password = Welcome123
```

Trong section `[oslo_concurrency]`:

```ini
[oslo_concurrency]
lock_path = /var/lib/cinder/tmp
```

### 3.5 Đồng bộ database

```bash
su -s /bin/sh -c "cinder-manage db sync" cinder
```

> Bỏ qua deprecation warning nếu có.

### 3.6 Cấu hình Nova dùng Cinder

Thêm vào `/etc/nova/nova.conf`:

```ini
[cinder]
os_region_name = RegionOne
```

> **Tại sao cần `os_region_name`?**
> Nova không hardcode địa chỉ Cinder mà hỏi Keystone Service Catalog: "Cinder endpoint ở đâu trong region RegionOne?". Nếu có nhiều region (RegionOne HN, RegionTwo HCM), Nova cần biết phải dùng Cinder của region nào. Trong lab chỉ có 1 region nên `RegionOne` là đủ.

### 3.7 Khởi động service

> Trên Ubuntu 24.04, cinder-api chạy qua Apache.

```bash
systemctl restart apache2
systemctl restart cinder-scheduler
systemctl enable cinder-scheduler
```

---

## 4. Cài đặt Cinder Volume trên Storage Node

> Thực hiện trên node **storage1**

### 4.1 Cài đặt package

```bash
apt install -y cinder-volume tgt
```

### 4.2 Cấu hình Cinder Volume

Sửa file `/etc/cinder/cinder.conf`:

Trong section `[database]`:

```ini
[database]
connection = mysql+pymysql://cinder:Welcome123@controller/cinder
```

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller
auth_strategy = keystone
my_ip = 192.168.225.197
enabled_backends = lvm
glance_api_servers = http://controller:9292
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
username = cinder
password = Welcome123
```

Thêm section `[lvm]` mới:

```ini
[lvm]
volume_driver = cinder.volume.drivers.lvm.LVMVolumeDriver
volume_group = cinder-volumes
target_protocol = iscsi
target_helper = tgtadm
```

Trong section `[oslo_concurrency]`:

```ini
[oslo_concurrency]
lock_path = /var/lib/cinder/tmp
```

### 4.3 Cấu hình tgt

```bash
echo "include /var/lib/cinder/volumes/*" > /etc/tgt/conf.d/cinder.conf
```

### 4.4 Khởi động service

```bash
systemctl restart tgt cinder-volume
systemctl enable tgt cinder-volume
```

---

## 5. Kiểm tra

> Thực hiện trên node **controller**

```bash
source ~/admin-openrc

openstack volume service list
```

Kết quả mong đợi:

```
+------------------+--------------------+------+---------+-------+----------------------------+
| Binary           | Host               | Zone | Status  | State | Updated At                 |
+------------------+--------------------+------+---------+-------+----------------------------+
| cinder-scheduler | controller         | nova | enabled | up    | 2025-10-01T10:00:00.000000 |
| cinder-volume    | storage1@lvm       | nova | enabled | up    | 2025-10-01T10:00:00.000000 |
+------------------+--------------------+------+---------+-------+----------------------------+
```

Tạo volume test:

```bash
source ~/demo-openrc

openstack volume create --size 1 test-volume
openstack volume list
```

Kết quả mong đợi:

```
+--------------------------------------+-------------+-----------+------+-------------+
| ID                                   | Name        | Status    | Size | Attached to |
+--------------------------------------+-------------+-----------+------+-------------+
| xxx                                  | test-volume | available |    1 |             |
+--------------------------------------+-------------+-----------+------+-------------+
```

Attach volume vào instance:

```bash
openstack server add volume my-first-instance test-volume
openstack volume list
# Status phải chuyển từ available → in-use
```

Detach và xóa volume test:

```bash
openstack server remove volume my-first-instance test-volume
openstack volume delete test-volume
```

---

Trước: [08-horizon.md](08-horizon.md) | Tiếp theo: [10-swift.md](10-swift.md)
