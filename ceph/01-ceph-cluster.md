# Cài đặt Ceph Cluster cho OpenStack

> **Version:** Ceph **Squid (v19.2)** - phiên bản mới nhất, hỗ trợ Ubuntu 24.04 LTS native.
>
> Ceph cung cấp storage backend phân tán cho OpenStack:
> - **RBD** (RADOS Block Device) → thay thế Cinder LVM, Nova ephemeral, Glance images
> - **RGW** (RADOS Gateway) → thay thế Swift Object Storage (tùy chọn)
> - **CephFS** → shared filesystem (tùy chọn)

## Kiến trúc

```
OpenStack Nodes                    Ceph Cluster (Squid v19)
┌─────────────────────┐           ┌──────────────────────────────────────┐
│ controller          │──RBD──────►│ ceph-mon1 (192.168.225.202)          │
│  ├─ Glance (images) │           │  ├─ MON: cluster map, quorum         │
│  └─ Cinder (volume) │           │  └─ MGR: dashboard, metrics          │
├─────────────────────┤           │                                      │
│ compute1            │──RBD──────►│ ceph-osd1 (192.168.225.203)          │
│  └─ Nova (vms)      │           │  └─ OSD: /dev/sdb (50GB)             │
└─────────────────────┘           │                                      │
                                  │ ceph-osd2 (192.168.225.204)          │
                                  │  └─ OSD: /dev/sdb (50GB)             │
                                  └──────────────────────────────────────┘

Ceph Pools:
  images  → Glance image storage
  volumes → Cinder block volumes
  vms     → Nova ephemeral disks
  backups → Cinder volume backups

Networks:
  Management (ens37/192.168.225.x) → API, admin traffic
  Cluster    (ens38/192.168.147.x) → OSD replication traffic (tách biệt)
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
3. [Cài đặt Ceph Squid bằng cephadm](#3-cài-đặt-ceph-squid-bằng-cephadm)
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

```bash
# Trên ceph-mon1
hostnamectl set-hostname ceph-mon1

# Trên ceph-osd1
hostnamectl set-hostname ceph-osd1

# Trên ceph-osd2
hostnamectl set-hostname ceph-osd2
```

### 2.2 Cấu hình /etc/hosts trên tất cả nodes

Trên **bastion** - thêm Ceph nodes vào hosts:

```bash
cat >> /etc/hosts << 'EOF'
# Ceph cluster
192.168.225.202   ceph-mon1
192.168.225.203   ceph-osd1
192.168.225.204   ceph-osd2
EOF
```

Trên **ceph-mon1, ceph-osd1, ceph-osd2** - thêm toàn bộ cluster:

```bash
cat >> /etc/hosts << 'EOF'
# Ceph cluster
192.168.225.202   ceph-mon1
192.168.225.203   ceph-osd1
192.168.225.204   ceph-osd2
# OpenStack nodes
192.168.225.195   controller
192.168.225.196   compute1
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

Trên **ceph-osd1** (`/etc/netplan/00-installer-config.yaml`):

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

Trên **ceph-osd2** (`/etc/netplan/00-installer-config.yaml`):

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

### 2.4 Cài đặt package cơ bản và fix DNS

```bash
# Fix DNS (tránh bị ghi đè bởi systemd-resolved)
mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/dns.conf << 'EOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
DNSStubListener=no
EOF
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved

apt update && apt upgrade -y
apt install -y chrony curl wget vim python3

# Bắt buộc: cephadm dùng container để chạy daemons
apt install -y podman
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
chronyc tracking
```

### 2.6 Cấu hình SSH key từ ceph-mon1

Trên **ceph-mon1**:

```bash
ssh-keygen -q -N "" -f ~/.ssh/id_rsa 2>/dev/null || true

# Copy key sang Ceph nodes
ssh-copy-id root@ceph-osd1
ssh-copy-id root@ceph-osd2

# Copy sang OpenStack nodes (cần khi tích hợp)
ssh-copy-id root@controller
ssh-copy-id root@compute1
```

---

## 3. Cài đặt Ceph Squid bằng cephadm

> Thực hiện trên **ceph-mon1**

### 3.1 Cài đặt cephadm và thêm repo Squid

```bash
# Ceph Squid (v19) có sẵn trong Ubuntu 24.04 noble archive
# KHÔNG cần thêm repo từ download.ceph.com (repo đó chưa hỗ trợ noble)
apt install -y cephadm ceph-common

# Verify version - phải thấy 19.x (squid)
cephadm --version
ceph --version
```

> Nếu lỡ chạy `cephadm add-repo --release squid` và bị lỗi 404, xóa repo đó đi:
> ```bash
> rm -f /etc/apt/sources.list.d/ceph.list
> apt update
> ```

### 3.2 Bootstrap cluster

```bash
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
> `--mon-ip` dùng Management IP (ens37).

### 3.3 Verify cài đặt

```bash
# Kiểm tra version
ceph -v
# Phải thấy: ceph version 19.x.x (squid)

ceph status
# Phải thấy: health: HEALTH_WARN (bình thường khi chưa có OSD)
```

### 3.4 Thêm hosts vào cluster

```bash
# Copy SSH key của cephadm sang OSD nodes
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

### 4.1 Thêm disk vào VM trên VMware (trước khi cài OSD)

Vì ceph-osd1 và ceph-osd2 được clone từ VM khác nên chưa có disk data. Cần add thủ công trên VMware:

```
1. Tắt VM ceph-osd1 (nếu đang chạy)
2. VMware → ceph-osd1 → Settings → Add → Hard Disk
   - Disk type: SCSI
   - Create a new virtual disk
   - Size: 50 GB
   - Store as single file
   - Disk file: ceph-osd1-data.vmdk
3. Finish → OK
4. Bật VM lại
5. Lặp lại cho ceph-osd2
```

Verify disk đã được nhận trên VM:

```bash
# Trên ceph-osd1 và ceph-osd2
lsblk
# Phải thấy /dev/sdb (hoặc /dev/sdc tùy thứ tự)
# Disk mới sẽ không có partition, không có filesystem
```

### 4.2 Kiểm tra disk available từ ceph-mon1

```bash
# Xem disk nào có thể dùng làm OSD
ceph orch device ls --refresh

# Disk phải có status: Available=Yes
# Nếu không → disk đã có partition hoặc filesystem
```

### 4.3 Wipe disk nếu cần

Trên **ceph-osd1** và **ceph-osd2**:

```bash
# Xác định disk data
lsblk
# Thường là /dev/sdb

# Wipe sạch
wipefs -a /dev/sdb
sgdisk --zap-all /dev/sdb
dd if=/dev/zero of=/dev/sdb bs=1M count=100
```

### 4.4 Thêm OSD

```bash
# Thêm tất cả disk available tự động (khuyến nghị)
ceph orch apply osd --all-available-devices

# Theo dõi quá trình (chờ 1-2 phút)
watch ceph status
# Chờ đến khi: osd: 2 osds: 2 up, 2 in
```

### 4.5 Fix HEALTH_WARN - OSD count < replication size

Sau khi thêm OSD, cluster sẽ báo:
```
HEALTH_WARN: OSD count 2 < osd_pool_default_size 3
```

Nguyên nhân: Ceph mặc định replication size = 3 (cần 3 OSD), lab chỉ có 2 OSD.

```bash
# Set replication size = 2 cho lab 2 OSD
ceph config set global osd_pool_default_size 2
ceph config set global osd_pool_default_min_size 1

# Verify - phải thấy HEALTH_OK
ceph status
```

### 4.6 Verify cluster

```bash
ceph status
# Phải thấy:
#   health: HEALTH_OK
#   osd: 2 osds: 2 up, 2 in
#   usage: xxx GiB / 100 GiB avail

ceph osd tree
ceph df
```

---

## 5. Tạo pools cho OpenStack

> Thực hiện trên **ceph-mon1**

### 5.1 Tạo pools

```bash
# Tạo pools với số PG phù hợp cho lab 2 OSD
# Công thức: (OSDs * 100) / replicas / pool_count → làm tròn lên 2^n
ceph osd pool create volumes 32
ceph osd pool create images  32
ceph osd pool create backups 32
ceph osd pool create vms     32

# Enable RBD application
rbd pool init volumes
rbd pool init images
rbd pool init backups
rbd pool init vms
```

> Với 2 OSD, replication size mặc định là 2. Dùng 32 PG/pool là phù hợp cho lab.

### 5.2 Tạo Ceph users cho OpenStack

```bash
# User cho Cinder (volumes + vms + read images)
ceph auth get-or-create client.cinder \
  mon 'profile rbd' \
  osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd-read-only pool=images' \
  mgr 'profile rbd pool=volumes, profile rbd pool=vms'

# User cho Glance (images)
ceph auth get-or-create client.glance \
  mon 'profile rbd' \
  osd 'profile rbd pool=images' \
  mgr 'profile rbd pool=images'

# User cho Nova (vms + read images)
ceph auth get-or-create client.nova \
  mon 'profile rbd' \
  osd 'profile rbd pool=vms, profile rbd-read-only pool=images' \
  mgr 'profile rbd pool=vms'

# Lưu keyring ra file
ceph auth get-or-create client.cinder > /etc/ceph/ceph.client.cinder.keyring
ceph auth get-or-create client.glance > /etc/ceph/ceph.client.glance.keyring
ceph auth get-or-create client.nova   > /etc/ceph/ceph.client.nova.keyring

# Verify
ceph auth ls | grep client
```

### 5.3 Copy config và keyring sang OpenStack nodes

```bash
# Copy ceph.conf và ceph.client.admin.keyring
for node in controller compute1; do
  ssh root@$node "mkdir -p /etc/ceph"
  scp /etc/ceph/ceph.conf root@$node:/etc/ceph/
done

# Copy keyring theo từng node
scp /etc/ceph/ceph.client.glance.keyring root@controller:/etc/ceph/
scp /etc/ceph/ceph.client.cinder.keyring root@controller:/etc/ceph/
scp /etc/ceph/ceph.client.cinder.keyring root@compute1:/etc/ceph/
scp /etc/ceph/ceph.client.nova.keyring   root@compute1:/etc/ceph/
```

---

## 6. Tích hợp với OpenStack

### 6.1 Tích hợp Glance → Ceph RBD

Trên **controller**:

```bash
apt install -y python3-rbd ceph-common

# Phân quyền keyring
chown glance:glance /etc/ceph/ceph.client.glance.keyring
chmod 640 /etc/ceph/ceph.client.glance.keyring
```

Sửa `/etc/glance/glance-api.conf`:

> Từ OpenStack 2024.x trở đi, Glance dùng **multi-store** config. Cần set `enabled_backends` và `default_backend` trong `[DEFAULT]`, sau đó tạo section riêng cho backend.

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
enabled_backends = ceph:rbd
default_backend = ceph
```

Thêm section `[ceph]` mới (thay thế `[glance_store]`):

```ini
[ceph]
rbd_store_pool = images
rbd_store_user = glance
rbd_store_ceph_conf = /etc/ceph/ceph.conf
rbd_store_chunk_size = 8
```

```bash
systemctl restart glance-api
systemctl status glance-api

# Verify
source ~/admin-openrc
openstack image list
```

### 6.2 Tích hợp Cinder → Ceph RBD

> Cinder volume service chạy trên **controller**.

Trên **controller**:

```bash
apt install -y python3-rbd ceph-common

chown cinder:cinder /etc/ceph/ceph.client.cinder.keyring
chmod 640 /etc/ceph/ceph.client.cinder.keyring
```

Sửa `/etc/cinder/cinder.conf`:

```ini
[DEFAULT]
enabled_backends = ceph
glance_api_version = 2

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

```bash
systemctl restart cinder-volume cinder-scheduler apache2
```

### 6.3 Tạo libvirt secret trên compute1

Trên **compute1** (cần để Nova attach Cinder volume):

```bash
apt install -y python3-rbd ceph-common

# Tạo UUID cố định cho secret
CINDER_UUID=$(uuidgen)
echo "CINDER_UUID=$CINDER_UUID"
# Lưu UUID này → điền vào rbd_secret_uuid trong cinder.conf ở trên

# Lấy key của client.cinder
CINDER_KEY=$(ssh root@ceph-mon1 "ceph auth get-key client.cinder")

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

# Verify
virsh secret-list
```

> Sau khi có UUID, quay lại cập nhật `rbd_secret_uuid` trong `/etc/cinder/cinder.conf` trên controller.

### 6.4 Tích hợp Nova → Ceph RBD (ephemeral disk)

Trên **compute1**:

```bash
chown nova:nova /etc/ceph/ceph.client.nova.keyring
chmod 640 /etc/ceph/ceph.client.nova.keyring
```

Sửa `/etc/nova/nova.conf`, trong section `[libvirt]`:

```ini
[libvirt]
images_type = rbd
images_rbd_pool = vms
images_rbd_ceph_conf = /etc/ceph/ceph.conf
rbd_user = nova
rbd_secret_uuid = <CINDER_UUID>
disk_cachemodes = network=writeback
hw_disk_discard = unmap
```

```bash
systemctl restart nova-compute
```

---

## 7. Kiểm tra

```bash
# Trên ceph-mon1 - cluster health
ceph status
ceph df
ceph osd tree

# Test RBD trực tiếp
rbd create --size 1024 volumes/test-image
rbd ls volumes
rbd info volumes/test-image
rbd rm volumes/test-image

# Test từ OpenStack
source ~/admin-openrc

# Tạo volume type Ceph
openstack volume type create ceph-rbd \
  --property volume_backend_name=ceph

# Tạo volume
openstack volume create --size 1 --type ceph-rbd test-ceph-vol
openstack volume show test-ceph-vol
# status phải là: available

# Verify volume tồn tại trong Ceph
ssh root@ceph-mon1 "rbd ls volumes"
# Phải thấy volume-<uuid>

# Upload image và verify lưu trong Ceph
openstack image create --disk-format qcow2 --container-format bare \
  --file /tmp/cirros.img test-ceph-image
ssh root@ceph-mon1 "rbd ls images"
# Phải thấy image-<uuid>

# Cleanup
openstack volume delete test-ceph-vol
openstack image delete test-ceph-image
```

---

Tiếp theo: [02-ceph-openstack-integration.md](02-ceph-openstack-integration.md)
