# Cài đặt Object Storage (Swift)

> Swift cung cấp object storage - lưu trữ file/object với tính HA và scale cao.
> Cần thêm **2 VM mới** làm Object Storage node.

## Mục lục

1. [Mô hình triển khai](#1-mô-hình-triển-khai)
2. [Chuẩn bị Object Storage Nodes](#2-chuẩn-bị-object-storage-nodes)
3. [Cài đặt Swift trên Controller](#3-cài-đặt-swift-trên-controller)
4. [Cài đặt Swift trên Object Nodes](#4-cài-đặt-swift-trên-object-nodes)
5. [Tạo Ring và hoàn tất](#5-tạo-ring-và-hoàn-tất)
6. [Kiểm tra](#6-kiểm-tra)

---

## 1. Mô hình triển khai

```
                    [VMware NAT (VMnet8)]
                     192.168.182.0/24
                    /    |    |    \
      [CONTROLLER] [COMPUTE1] [OBJECT1] [OBJECT2]
      (đã có)      (đã có)    (VM mới)  (VM mới)
                              ens33:.182.198  ens33:.182.199  (NAT - internet)
                              ens37:.225.198  ens37:.225.199  (Management)
                              /dev/sdb        /dev/sdb
                              /dev/sdc        /dev/sdc
```

**IP Planning bổ sung:**

| Hostname | VMware Net | Interface | IP Address | Netmask | Gateway | DNS |
|---|---|---|---|---|---|---|
| object1 | VMnet8 (NAT) | ens33 | 192.168.182.198 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 |
| object1 | VMnet1 (Host-only) | ens37 | 192.168.225.198 | 255.255.255.0 | | |
| object2 | VMnet8 (NAT) | ens33 | 192.168.182.199 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 |
| object2 | VMnet1 (Host-only) | ens37 | 192.168.225.199 | 255.255.255.0 | | |

> `ens33` (VMnet8/NAT) dùng để download packages khi cài đặt.
> `ens37` (VMnet1) là Management network - Swift dùng để giao tiếp giữa các node.
>
> Nếu đã tạo storage1 cho Cinder dùng `.197`, thì object1/object2 dùng `.198`/`.199`.

**Yêu cầu phần cứng mỗi Object Node:**

| Node | vCPU | RAM | Disk 1 (OS) | Disk 2 (Swift) | Disk 3 (Swift) |
|---|---|---|---|---|---|
| object1 | 2 | 2 GB | 20 GB | 20 GB | 20 GB |
| object2 | 2 | 2 GB | 20 GB | 20 GB | 20 GB |

> Mỗi object node cần **3 disk riêng biệt** khi tạo VM:
> - Disk 1 (20GB): Ubuntu cài OS vào đây
> - Disk 2 (20GB): để trống → `/dev/sdb` → Swift data
> - Disk 3 (20GB): để trống → `/dev/sdc` → Swift data
>
> Khi cài Ubuntu chỉ chọn Disk 1. Disk 2 và 3 để nguyên, sau khi cài xong mới format XFS.

---

## 2. Chuẩn bị Object Storage Nodes

> Thực hiện trên **object1** và **object2** (các bước giống nhau, chỉ khác IP)

### 2.1 Cấu hình OS cơ bản

Sau khi cài Ubuntu 24.04:

```bash
apt update && apt upgrade -y
```

Cấu hình network `/etc/netplan/50-cloud-init.yaml`:

**Trên object1:**
```yaml
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - 192.168.182.198/24
      routes:
        - to: default
          via: 192.168.182.2
      nameservers:
        addresses: [8.8.8.8]
    ens37:
      addresses:
        - 192.168.225.198/24
```

**Trên object2:**
```yaml
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - 192.168.182.199/24
      routes:
        - to: default
          via: 192.168.182.2
      nameservers:
        addresses: [8.8.8.8]
    ens37:
      addresses:
        - 192.168.225.199/24
```

```bash
chmod 600 /etc/netplan/50-cloud-init.yaml
netplan apply
```

Cấu hình hostname:

```bash
# Trên object1
hostnamectl set-hostname object1

# Trên object2
hostnamectl set-hostname object2
```

Sửa `/etc/hosts` trên **tất cả node**:

```
192.168.225.195    controller
192.168.225.196    compute1
192.168.225.198    object1
192.168.225.199    object2
```

> Dùng **Management IP** (`192.168.225.x`) cho hostname, không dùng Provider IP (`192.168.182.x`).

Cài NTP đồng bộ từ controller:

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

Cài OpenStack repository:

```bash
apt install -y software-properties-common
add-apt-repository cloud-archive:flamingo -y
apt update && apt dist-upgrade -y
apt install -y python3-openstackclient
reboot
```

### 2.2 Chuẩn bị disk data

Thực hiện trên **cả object1 và object2**:

```bash
apt install -y xfsprogs rsync
```

Kiểm tra disk đã được add vào VM chưa:

```bash
lsblk
```

Kết quả mong đợi:

```
sda   20G  ← OS disk
sdb   20G  ← Swift data disk 1 (chưa có filesystem)
sdc   20G  ← Swift data disk 2 (chưa có filesystem)
```

Format disk data với XFS:

```bash
mkfs.xfs /dev/sdb
mkfs.xfs /dev/sdc
```

> **Tại sao XFS?**
> Swift lưu metadata của object dưới dạng **extended attributes (xattr)** trực tiếp trên filesystem.
> XFS hỗ trợ xattr tốt hơn ext4, hiệu năng cao hơn với nhiều file nhỏ - đặc trưng của object storage.
> Docs chính thức Swift khuyến nghị XFS.

Tạo mount point:

```bash
mkdir -p /srv/node/sdb
mkdir -p /srv/node/sdc
```

Lấy UUID của disk:

```bash
blkid /dev/sdb
blkid /dev/sdc
```

Thêm vào `/etc/fstab`:

```
UUID="<UUID-sdb>" /srv/node/sdb xfs noatime 0 2
UUID="<UUID-sdc>" /srv/node/sdc xfs noatime 0 2
```

Mount:

```bash
mount /srv/node/sdb
mount /srv/node/sdc
```

### 2.3 Cấu hình rsync

Tạo file `/etc/rsyncd.conf`:

**Trên object1** (thay IP tương ứng):

```ini
uid = swift
gid = swift
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid
address = 192.168.225.198

[account]
max connections = 2
path = /srv/node/
read only = False
lock file = /var/lock/account.lock

[container]
max connections = 2
path = /srv/node/
read only = False
lock file = /var/lock/container.lock

[object]
max connections = 2
path = /srv/node/
read only = False
lock file = /var/lock/object.lock
```

**Trên object2**: thay `address = 192.168.225.199`

Bật rsync:

```bash
# Sửa /etc/default/rsync
sed -i 's/RSYNC_ENABLE=false/RSYNC_ENABLE=true/' /etc/default/rsync

systemctl start rsync
systemctl enable rsync
```

---

## 3. Cài đặt Swift trên Controller

> Thực hiện trên node **controller**

### 3.1 Tạo user, service và endpoint

```bash
source ~/admin-openrc
```

```bash
openstack user create --domain default --password Welcome123 swift
openstack role add --project service --user swift admin
```

```bash
openstack service create --name swift \
  --description "OpenStack Object Storage" object-store
```

Kết quả:
```
+-------------+----------------------------------+
| Field       | Value                            |
+-------------+----------------------------------+
| description | OpenStack Object Storage         |
| enabled     | True                             |
| id          | 75ef509da2c340499d454ae96a2c5c34 |
| name        | swift                            |
| type        | object-store                     |
+-------------+----------------------------------+
```

```bash
openstack endpoint create --region RegionOne \
  object-store public http://controller:8080/v1/AUTH_%\(project_id\)s
openstack endpoint create --region RegionOne \
  object-store internal http://controller:8080/v1/AUTH_%\(project_id\)s
openstack endpoint create --region RegionOne \
  object-store admin http://controller:8080/v1
```

### 3.2 Cài đặt package

```bash
apt install -y swift swift-proxy python3-swiftclient \
  python3-keystoneclient python3-keystonemiddleware
```

> Trên Ubuntu 24.04 dùng `python3-*` thay vì `python-*` như docs cũ.

### 3.3 Cấu hình proxy server

```bash
mkdir -p /etc/swift

cat > /etc/swift/proxy-server.conf << 'EOF'
[DEFAULT]
bind_port = 8080
user = swift
swift_dir = /etc/swift

[pipeline:main]
pipeline = catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk ratelimit authtoken keystoneauth container-quotas account-quotas slo dlo versioned_writes proxy-logging proxy-server

[app:proxy-server]
use = egg:swift#proxy
account_autocreate = True

[filter:keystoneauth]
use = egg:swift#keystoneauth
operator_roles = admin,user,member

[filter:authtoken]
paste.filter_factory = keystonemiddleware.auth_token:filter_factory
www_authenticate_uri = http://controller:5000
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_id = default
user_domain_id = default
project_name = service
username = swift
password = Welcome123
delay_auth_decision = True

[filter:cache]
use = egg:swift#memcache
memcache_servers = controller:11211

[filter:catch_errors]
use = egg:swift#catch_errors

[filter:healthcheck]
use = egg:swift#healthcheck

[filter:proxy-logging]
use = egg:swift#proxy_logging

[filter:bulk]
use = egg:swift#bulk

[filter:ratelimit]
use = egg:swift#ratelimit

[filter:gatekeeper]
use = egg:swift#gatekeeper

[filter:container_sync]
use = egg:swift#container_sync

[filter:slo]
use = egg:swift#slo

[filter:dlo]
use = egg:swift#dlo

[filter:versioned_writes]
use = egg:swift#versioned_writes

[filter:container-quotas]
use = egg:swift#container_quotas

[filter:account-quotas]
use = egg:swift#account_quotas
EOF
```

---

## 4. Cài đặt Swift trên Object Nodes

> Thực hiện trên **object1** và **object2**

```bash
apt install -y swift swift-account swift-container swift-object

mkdir -p /etc/swift
```

**Trên object1** - tạo 3 file config:

```bash
cat > /etc/swift/account-server.conf << 'EOF'
[DEFAULT]
bind_ip = 192.168.225.198
bind_port = 6202
user = swift
swift_dir = /etc/swift
devices = /srv/node
mount_check = True

[pipeline:main]
pipeline = healthcheck recon account-server

[app:account-server]
use = egg:swift#account

[filter:healthcheck]
use = egg:swift#healthcheck

[filter:recon]
use = egg:swift#recon
recon_cache_path = /var/cache/swift
EOF
```

```bash
cat > /etc/swift/container-server.conf << 'EOF'
[DEFAULT]
bind_ip = 192.168.225.198
bind_port = 6201
user = swift
swift_dir = /etc/swift
devices = /srv/node
mount_check = True

[pipeline:main]
pipeline = healthcheck recon container-server

[app:container-server]
use = egg:swift#container

[filter:healthcheck]
use = egg:swift#healthcheck

[filter:recon]
use = egg:swift#recon
recon_cache_path = /var/cache/swift
EOF
```

```bash
cat > /etc/swift/object-server.conf << 'EOF'
[DEFAULT]
bind_ip = 192.168.225.198
bind_port = 6200
user = swift
swift_dir = /etc/swift
devices = /srv/node
mount_check = True

[pipeline:main]
pipeline = healthcheck recon object-server

[app:object-server]
use = egg:swift#object

[filter:healthcheck]
use = egg:swift#healthcheck

[filter:recon]
use = egg:swift#recon
recon_cache_path = /var/cache/swift
recon_lock_path = /var/lock
EOF
```

**Trên object2** - copy nguyên 3 lệnh sau:

```bash
cat > /etc/swift/account-server.conf << 'EOF'
[DEFAULT]
bind_ip = 192.168.225.199
bind_port = 6202
user = swift
swift_dir = /etc/swift
devices = /srv/node
mount_check = True

[pipeline:main]
pipeline = healthcheck recon account-server

[app:account-server]
use = egg:swift#account

[filter:healthcheck]
use = egg:swift#healthcheck

[filter:recon]
use = egg:swift#recon
recon_cache_path = /var/cache/swift
EOF
```

```bash
cat > /etc/swift/container-server.conf << 'EOF'
[DEFAULT]
bind_ip = 192.168.225.199
bind_port = 6201
user = swift
swift_dir = /etc/swift
devices = /srv/node
mount_check = True

[pipeline:main]
pipeline = healthcheck recon container-server

[app:container-server]
use = egg:swift#container

[filter:healthcheck]
use = egg:swift#healthcheck

[filter:recon]
use = egg:swift#recon
recon_cache_path = /var/cache/swift
EOF
```

```bash
cat > /etc/swift/object-server.conf << 'EOF'
[DEFAULT]
bind_ip = 192.168.225.199
bind_port = 6200
user = swift
swift_dir = /etc/swift
devices = /srv/node
mount_check = True

[pipeline:main]
pipeline = healthcheck recon object-server

[app:object-server]
use = egg:swift#object

[filter:healthcheck]
use = egg:swift#healthcheck

[filter:recon]
use = egg:swift#recon
recon_cache_path = /var/cache/swift
recon_lock_path = /var/lock
EOF
```

Phân quyền (chạy trên **cả object1 và object2**):

```bash
chown -R swift:swift /srv/node
mkdir -p /var/cache/swift
chown -R root:swift /var/cache/swift
chmod -R 775 /var/cache/swift
```

---

## 5. Tạo Ring và hoàn tất

> Thực hiện trên node **controller**

```bash
cd /etc/swift
```

### 5.1 Tạo Account Ring

```bash
swift-ring-builder account.builder create 10 3 1

swift-ring-builder account.builder add \
  --region 1 --zone 1 --ip 192.168.225.198 --port 6202 --device sdb --weight 100
swift-ring-builder account.builder add \
  --region 1 --zone 1 --ip 192.168.225.198 --port 6202 --device sdc --weight 100
swift-ring-builder account.builder add \
  --region 1 --zone 2 --ip 192.168.225.199 --port 6202 --device sdb --weight 100
swift-ring-builder account.builder add \
  --region 1 --zone 2 --ip 192.168.225.199 --port 6202 --device sdc --weight 100

swift-ring-builder account.builder rebalance
```

### 5.2 Tạo Container Ring

```bash
swift-ring-builder container.builder create 10 3 1

swift-ring-builder container.builder add \
  --region 1 --zone 1 --ip 192.168.225.198 --port 6201 --device sdb --weight 100
swift-ring-builder container.builder add \
  --region 1 --zone 1 --ip 192.168.225.198 --port 6201 --device sdc --weight 100
swift-ring-builder container.builder add \
  --region 1 --zone 2 --ip 192.168.225.199 --port 6201 --device sdb --weight 100
swift-ring-builder container.builder add \
  --region 1 --zone 2 --ip 192.168.225.199 --port 6201 --device sdc --weight 100

swift-ring-builder container.builder rebalance
```

### 5.3 Tạo Object Ring

```bash
swift-ring-builder object.builder create 10 3 1

swift-ring-builder object.builder add \
  --region 1 --zone 1 --ip 192.168.225.198 --port 6200 --device sdb --weight 100
swift-ring-builder object.builder add \
  --region 1 --zone 1 --ip 192.168.225.198 --port 6200 --device sdc --weight 100
swift-ring-builder object.builder add \
  --region 1 --zone 2 --ip 192.168.225.199 --port 6200 --device sdb --weight 100
swift-ring-builder object.builder add \
  --region 1 --zone 2 --ip 192.168.225.199 --port 6200 --device sdc --weight 100

swift-ring-builder object.builder rebalance
```

### 5.4 Tạo swift.conf và distribute

Tạo file `/etc/swift/swift.conf` với hash ngẫu nhiên:

```bash
SUFFIX=$(openssl rand -hex 10)
PREFIX=$(openssl rand -hex 10)

cat > /etc/swift/swift.conf << EOF
[swift-hash]
swift_hash_path_suffix = $SUFFIX
swift_hash_path_prefix = $PREFIX

[storage-policy:0]
name = Policy-0
default = yes
EOF

echo "Suffix: $SUFFIX"
echo "Prefix: $PREFIX"
# Lưu lại 2 giá trị này để tham khảo
```

> `swift_hash_path_suffix` và `swift_hash_path_prefix` phải **giống nhau trên tất cả node**.
> Đây là lý do dùng `scp` để copy file này sang object nodes thay vì tạo lại.

Copy ring files và swift.conf sang object nodes:

```bash
scp /etc/swift/*.ring.gz root@object1:/etc/swift/
scp /etc/swift/*.ring.gz root@object2:/etc/swift/
scp /etc/swift/swift.conf root@object1:/etc/swift/
scp /etc/swift/swift.conf root@object2:/etc/swift/
```

Phân quyền trên **tất cả node** (controller, object1, object2):

```bash
chown -R root:swift /etc/swift
```

### 5.5 Khởi động service

Trên **controller**:

```bash
systemctl restart memcached swift-proxy
systemctl enable swift-proxy
```

Trên **object1** và **object2**:

```bash
swift-init all start
```

---

## 6. Kiểm tra

> Thực hiện trên node **controller**

```bash
source ~/demo-openrc

# Xem trạng thái Swift
swift stat
```

Kết quả mong đợi:

```
               Account: AUTH_xxx
            Containers: 0
               Objects: 0
                 Bytes: 0
       X-Put-Timestamp: xxx
           X-Timestamp: xxx
            X-Trans-Id: xxx
          Content-Type: text/plain; charset=utf-8
```

Tạo container và upload file:

```bash
openstack container create test-container

echo "Hello Swift" > /tmp/test-file.txt

# Dùng --name để đặt tên object không có đường dẫn
openstack object create test-container /tmp/test-file.txt --name test-file.txt

openstack object list test-container
```

Kết quả mong đợi:

```
+-----------+
| Name      |
+-----------+
| test-file |
+-----------+
```

Download và verify:

```bash
openstack object save test-container /tmp/test-file.txt --file /tmp/downloaded.txt
cat /tmp/downloaded.txt
# Hello Swift
```

Dọn dẹp:

```bash
openstack object delete test-container test-file.txt
openstack container delete test-container
```

---

Trước: [09-cinder.md](09-cinder.md) | Tiếp theo: [11-heat.md](11-heat.md)
