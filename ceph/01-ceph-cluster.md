# Cài đặt Ceph Cluster cho OpenStack

> Ceph cung cấp storage backend phân tán cho OpenStack:
> - **RBD** (RADOS Block Device) → thay thế Cinder LVM
> - **CephFS** → shared filesystem (tùy chọn)
> - **RGW** (RADOS Gateway) → thay thế Swift Object Storage (tùy chọn)

## Kiến trúc

```
OpenStack Nodes                    Ceph Cluster
┌─────────────┐                   ┌──────────────────────────────────┐
│ controller  │──── RBD (Glance)──►│                                  │
│ compute1    │──── RBD (Nova)  ──►│  ceph-mon1 (192.168.225.202)     │
│ storage1    │──── RBD (Cinder)──►│  ceph-osd1 (192.168.225.203)     │
└─────────────┘                   │  ceph-osd2 (192.168.225.204)     │
                                  │                                  │
                                  │  MON: quorum, cluster map        │
                                  │  OSD: lưu data trên disk         │
                                  └──────────────────────────────────┘
```

**Các thành phần Ceph:**

| Component | Vai trò |
|---|---|
| MON (Monitor) | Duy trì cluster map, quorum. Cần số lẻ (1, 3, 5) |
| OSD (Object Storage Daemon) | Lưu data thực tế, mỗi disk = 1 OSD |
| MGR (Manager) | Dashboard, metrics, orchestration |
| MDS (Metadata Server) | Chỉ cần cho CephFS |
| RGW (RADOS Gateway) | S3/Swift compatible API |

## Mục lục

1. [IP Planning và chuẩn bị VM](#1-ip-planning-và-chuẩn-bị-vm)
2. [Chuẩn bị môi trường trên tất cả nodes](#2-chuẩn-bị-môi-trường-trên-tất-cả-nodes)
3. [Cài đặt Ceph bằng cephadm](#3-cài-đặt-ceph-bằng-cephadm)
4. [Thêm OSD nodes](#4-thêm-osd-nodes)
5. [Tạo pools cho OpenStack](#5-tạo-pools-cho-openstack)
6. [Tích hợp với OpenStack](#6-tích-hợp-với-openstack)
7. [Kiểm tra](#7-kiểm-tra)

---

## 1. IP Planning và chuẩn bị VM

### 1.1 IP Planning

| Hostname | ens33 (NAT) | ens37 (Management) | ens38 (Ceph cluster) | Disk OS | Disk Data |
|---|---|---|---|---|---|
| ceph-mon1 | 192.168.182.202 | 192.168.225.202 | 192.168.147.202 | 20 GB | - |
| ceph-osd1 | 192.168.182.203 | 192.168.225.203 | 192.168.147.203 | 20 GB | 50 GB |
| ceph-osd2 | 192.168.182.204 | 192.168.225.204 | 192.168.147.204 | 20 GB | 50 GB |

> Dùng `ens38` (VMnet2) làm Ceph cluster network để tách biệt replication traffic khỏi management.

### 1.2 Yêu cầu phần cứng

| Node | vCPU | RAM | Disk 1 (OS) | Disk 2 (Data) | Ghi chú |
|---|---|---|---|---|---|
| ceph-mon1 | 2 | 4 GB | 20 GB | - | MON + MGR |
| ceph-osd1 | 2 | 4 GB | 20 GB | 50 GB | OSD |
| ceph-osd2 | 2 | 4 GB | 20 GB | 50 GB | OSD |

> Disk 2 trên OSD nodes phải là **raw disk, không format**, không mount.

---

## 2. Chuẩn bị môi trường trên tất cả nodes

> Thực hiện trên **ceph-mon1, ceph-osd1, ceph-osd2**

### 2.1 Cấu hình hostname

Trên **ceph-mon1**:
```bash
hostnamectl set-hostname ceph-mon1
```

Trên **ceph-osd1**:
```bash
hostnamectl set-hostname ceph-osd1
```

Trên **ceph-osd2**:
```bash
hostnamectl set-hostname ceph-osd2
```

### 2.2 Cấu hình /etc/hosts trên tất cả nodes

```bash
cat >> /etc/hosts << 'EOF'
# Ceph cluster
192.168.225.202   ceph-mon1
192.168.225.203   ceph-osd1
192.168.225.204   ceph-osd2
# OpenStack nodes
192.168.225.195   controller
192.168.225.196   compute1
192.168.225.197   storage1
EOF
```

### 2.3 Cấu hình network (netplan)

Trên **ceph-mon1** (`/etc/netplan/00-installer-config.yaml`):

```yaml
network:
  version: 2
  ethernets:
    ens33:
      addresses: [192.168.182.202/24]
      routes:
        - to: default
          via: 192.168.182.2
      nameservers:
        addresses: [8.8.8.8]
    ens37:
      addresses: [192.168.225.202/24]
    ens38:
      addresses: [192.168.147.202/24]
```

Trên **ceph-osd1**:
```yaml
network:
  version: 2
  ethernets:
    ens33:
      addresses: [192.168.182.203/24]
      routes:
        - to: default
          via: 192.168.182.2
      nameservers:
        addresses: [8.8.8.8]
    ens37:
      addresses: [192.168.225.203/24]
    ens38:
      addresses: [192.168.147.203/24]
```

Trên **ceph-osd2**:
```yaml
network:
  version: 2
  ethernets:
    ens33:
      addresses: [192.168.182.204/24]
      routes:
        - to: default
          via: 192.168.182.2
      nameservers:
        addresses: [8.8.8.8]
    ens37:
      addresses: [192.168.225.204/24]
    ens38:
      addresses: [192.168.147.204/24]
```

```bash
netplan apply
```

### 2.4 Cài đặt package cơ bản

```bash
apt update && apt upgrade -y
apt install -y chrony curl wget vim python3
```

### 2.5 Cấu hình NTP

```bash
cat > /etc/chrony/chrony.conf << 'EOF'
server controller iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF

systemctl restart chrony
```

### 2.6 Cấu hình SSH key từ ceph-mon1

Trên **ceph-mon1**:

```bash
ssh-keygen -q -N "" -f ~/.ssh/id_rsa

# Copy key sang các nodes
ssh-copy-id root@ceph-osd1
ssh-copy-id root@ceph-osd2

# Copy sang OpenStack nodes (cần khi tích hợp)
ssh-copy-id root@controller
ssh-copy-id root@compute1
ssh-copy-id root@storage1
```

---

## 3. Cài đặt Ceph bằng cephadm

> Thực hiện trên **ceph-mon1**

### 3.1 Cài đặt cephadm

```bash
apt install -y cephadm

# Hoặc download trực tiếp
curl --silent --remote-name --location https://github.com/ceph/ceph/raw/quincy/src/cephadm/cephadm
chmod +x cephadm
mv cephadm /usr/local/bin/

# Thêm Ceph repo
cephadm add-repo --release reef
cephadm install
```

### 3.2 Bootstrap cluster

```bash
# Bootstrap với MON IP là Management IP của ceph-mon1
cephadm bootstrap \
  --mon-ip 192.168.225.202 \
  --cluster-network 192.168.147.0/24 \
  --initial-dashboard-user admin \
  --initial-dashboard-password Welcome123 \
  --allow-overwrite

# Output sẽ hiển thị:
# Ceph Dashboard: https://192.168.225.202:8443
# Username: admin
# Password: Welcome123
```

> `--cluster-network` chỉ định mạng dùng cho OSD replication (ens38).

### 3.3 Cài đặt Ceph CLI

```bash
cephadm install ceph-common

# Verify
ceph -v
ceph status
```

### 3.4 Thêm hosts vào cluster

```bash
# Copy SSH key của cephadm sang các nodes
ssh-copy-id -f -i /etc/ceph/ceph.pub root@ceph-osd1
ssh-copy-id -f -i /etc/ceph/ceph.pub root@ceph-osd2

# Thêm hosts
ceph orch host add ceph-osd1 192.168.225.203
ceph orch host add ceph-osd2 192.168.225.204

# Verify
ceph orch host ls
```

---

## 4. Thêm OSD nodes

> Thực hiện trên **ceph-mon1**

### 4.1 Kiểm tra disk available

```bash
# Xem disk nào có thể dùng làm OSD
ceph orch device ls

# Disk phải có status: Available
# Nếu không Available → disk đã có partition hoặc filesystem
```

### 4.2 Wipe disk nếu cần

```bash
# Trên ceph-osd1 và ceph-osd2
# Xác định disk data (thường là /dev/sdb)
lsblk

# Wipe disk
wipefs -a /dev/sdb
sgdisk --zap-all /dev/sdb
```

### 4.3 Thêm OSD

```bash
# Thêm tất cả disk available tự động
ceph orch apply osd --all-available-devices

# Hoặc thêm từng disk cụ thể
ceph orch daemon add osd ceph-osd1:/dev/sdb
ceph orch daemon add osd ceph-osd2:/dev/sdb

# Theo dõi quá trình
watch ceph status
# Chờ đến khi: health: HEALTH_OK
```

### 4.4 Verify cluster

```bash
ceph status
# Phải thấy:
#   cluster: HEALTH_OK
#   osd: 2 osds: 2 up, 2 in

ceph osd tree
ceph df
```

---

## 5. Tạo pools cho OpenStack

> Thực hiện trên **ceph-mon1**

### 5.1 Tạo pools

```bash
# Pool cho Glance images
ceph osd pool create volumes 64
ceph osd pool create images 64
ceph osd pool create backups 64
ceph osd pool create vms 64

# Enable RBD application cho từng pool
rbd pool init volumes
rbd pool init images
rbd pool init backups
rbd pool init vms
```

> Số PG (64) phù hợp cho lab nhỏ với 2 OSD. Production dùng công thức: `(OSDs * 100) / replicas`.

### 5.2 Tạo Ceph users cho OpenStack

```bash
# User cho Cinder
ceph auth get-or-create client.cinder \
  mon 'profile rbd' \
  osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd-read-only pool=images' \
  mgr 'profile rbd pool=volumes, profile rbd pool=vms'

# User cho Glance
ceph auth get-or-create client.glance \
  mon 'profile rbd' \
  osd 'profile rbd pool=images' \
  mgr 'profile rbd pool=images'

# User cho Nova
ceph auth get-or-create client.nova \
  mon 'profile rbd' \
  osd 'profile rbd pool=vms, profile rbd-read-only pool=images' \
  mgr 'profile rbd pool=vms'

# Lưu keyring ra file
ceph auth get-or-create client.cinder > /etc/ceph/ceph.client.cinder.keyring
ceph auth get-or-create client.glance > /etc/ceph/ceph.client.glance.keyring
ceph auth get-or-create client.nova   > /etc/ceph/ceph.client.nova.keyring
```

### 5.3 Copy config và keyring sang OpenStack nodes

```bash
# Copy ceph.conf
for node in controller compute1 storage1; do
  ssh root@$node "mkdir -p /etc/ceph"
  scp /etc/ceph/ceph.conf root@$node:/etc/ceph/
done

# Copy keyring theo từng node
scp /etc/ceph/ceph.client.glance.keyring root@controller:/etc/ceph/
scp /etc/ceph/ceph.client.cinder.keyring root@storage1:/etc/ceph/
scp /etc/ceph/ceph.client.cinder.keyring root@compute1:/etc/ceph/
scp /etc/ceph/ceph.client.nova.keyring   root@compute1:/etc/ceph/
```

---

## 6. Tích hợp với OpenStack

### 6.1 Tích hợp Glance → Ceph RBD

Trên **controller**:

```bash
apt install -y python3-rbd

# Phân quyền keyring
chown glance:glance /etc/ceph/ceph.client.glance.keyring
```

Sửa `/etc/glance/glance-api.conf`:

```ini
[glance_store]
stores = rbd
default_store = rbd
rbd_store_pool = images
rbd_store_user = glance
rbd_store_ceph_conf = /etc/ceph/ceph.conf
rbd_store_chunk_size = 8
```

```bash
systemctl restart glance-api
```

### 6.2 Tích hợp Cinder → Ceph RBD

Trên **storage1** (hoặc controller nếu không có storage1):

```bash
apt install -y python3-rbd ceph-common

chown cinder:cinder /etc/ceph/ceph.client.cinder.keyring
```

Sửa `/etc/cinder/cinder.conf`:

```ini
[DEFAULT]
enabled_backends = ceph

[ceph]
volume_driver = cinder.volume.drivers.rbd.RBDDriver
volume_backend_name = ceph
rbd_pool = volumes
rbd_ceph_conf = /etc/ceph/ceph.conf
rbd_flatten_volume_from_snapshot = false
rbd_max_clone_depth = 5
rbd_store_chunk_size = 4
rados_connect_timeout = -1
rbd_user = cinder
rbd_secret_uuid = <LIBVIRT_SECRET_UUID>
```

Tạo libvirt secret cho Nova (trên **compute1**):

```bash
# Tạo UUID
CINDER_UUID=$(uuidgen)
echo "CINDER_UUID=$CINDER_UUID"
# Lưu UUID này để điền vào rbd_secret_uuid ở trên

# Lấy key của client.cinder
CINDER_KEY=$(ceph auth get-key client.cinder)

# Tạo libvirt secret
cat > /tmp/secret.xml << EOF
<secret ephemeral='no' private='no'>
  <uuid>$CINDER_UUID</uuid>
  <usage type='ceph'>
    <name>client.cinder secret</name>
  </usage>
</secret>
EOF

virsh secret-define --file /tmp/secret.xml
virsh secret-set-value --secret $CINDER_UUID --base64 $CINDER_KEY
```

```bash
# Restart Cinder
systemctl restart cinder-volume
```

### 6.3 Tích hợp Nova → Ceph RBD (ephemeral disk)

Trên **compute1**:

```bash
apt install -y python3-rbd ceph-common
chown nova:nova /etc/ceph/ceph.client.nova.keyring
```

Sửa `/etc/nova/nova.conf`:

```ini
[libvirt]
images_type = rbd
images_rbd_pool = vms
images_rbd_ceph_conf = /etc/ceph/ceph.conf
rbd_user = nova
rbd_secret_uuid = <CINDER_UUID>
disk_cachemodes = network=writeback
```

```bash
systemctl restart nova-compute
```

---

## 7. Kiểm tra

```bash
# Trên ceph-mon1
ceph status
ceph df
ceph osd tree

# Test tạo RBD image
rbd create --size 1024 volumes/test-image
rbd ls volumes
rbd info volumes/test-image
rbd rm volumes/test-image

# Test từ OpenStack - tạo volume dùng Ceph backend
source ~/admin-openrc
openstack volume type create ceph-rbd \
  --property volume_backend_name=ceph

openstack volume create --size 1 --type ceph-rbd test-ceph-vol
openstack volume show test-ceph-vol
# status phải là available

# Cleanup
openstack volume delete test-ceph-vol
```

---

Tiếp theo: [02-ceph-openstack-integration.md](02-ceph-openstack-integration.md)
