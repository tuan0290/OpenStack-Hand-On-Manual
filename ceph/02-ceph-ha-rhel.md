# Cài đặt Ceph HA Cluster trên RHEL 9

> **Mô hình:** 6 VM - 3 MON/MGR + 3 OSD - đảm bảo High Availability thực sự.
> **OS:** Red Hat Enterprise Linux 9 (hoặc Rocky Linux 9 / AlmaLinux 9)
> **Version:** Ceph Squid (v19) via cephadm

## Tại sao cần 6 VM cho HA?

```
Lab (3 VM):                    HA Production (6 VM):
ceph-mon1 (MON+OSD)            ceph-mon1 (MON+MGR)  ← quorum node 1
ceph-osd1 (OSD)                ceph-mon2 (MON+MGR)  ← quorum node 2
ceph-osd2 (OSD)                ceph-mon3 (MON+MGR)  ← quorum node 3
                               ceph-osd1 (OSD)      ← data node 1
Vấn đề:                        ceph-osd2 (OSD)      ← data node 2
- 1 MON → mất quorum           ceph-osd3 (OSD)      ← data node 3
- 2 OSD → replication=2 only
- Không thực sự HA             Lợi ích:
                               - Mất 1 MON → vẫn có quorum (2/3)
                               - Mất 1 OSD → data vẫn đủ replicas (2/3)
                               - replication=3 → production-grade
```

## Kiến trúc

```
┌─────────────────────────────────────────────────────────────────┐
│                    Ceph HA Cluster                              │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │  ceph-mon1   │  │  ceph-mon2   │  │  ceph-mon3   │          │
│  │  MON + MGR   │  │  MON + MGR   │  │  MON + MGR   │          │
│  │  .202        │  │  .205        │  │  .206        │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │  ceph-osd1   │  │  ceph-osd2   │  │  ceph-osd3   │          │
│  │  OSD         │  │  OSD         │  │  OSD         │          │
│  │  .203        │  │  .204        │  │  .207        │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│                                                                 │
│  Networks:                                                      │
│  ens160 (192.168.182.x) → NAT/Internet                          │
│  ens192 (192.168.225.x) → Management / Public                   │
│  ens224 (192.168.147.x) → Cluster (OSD replication)             │
└─────────────────────────────────────────────────────────────────┘
```

## Mục lục

1. [IP Planning](#1-ip-planning)
2. [Chuẩn bị OS trên tất cả nodes](#2-chuẩn-bị-os-trên-tất-cả-nodes)
3. [Cài đặt Ceph bằng cephadm](#3-cài-đặt-ceph-bằng-cephadm)
4. [Thêm MON nodes](#4-thêm-mon-nodes)
5. [Thêm OSD nodes](#5-thêm-osd-nodes)
6. [Cấu hình HA và replication](#6-cấu-hình-ha-và-replication)
7. [Tạo pools cho OpenStack](#7-tạo-pools-cho-openstack)
8. [Kiểm tra HA](#8-kiểm-tra-ha)

---

## 1. IP Planning

| Hostname | ens160 (NAT) | ens192 (Management) | ens224 (Cluster) | Role | Disk OS | Disk Data |
|---|---|---|---|---|---|---|
| ceph-mon1 | 192.168.182.202 | 192.168.225.202 | 192.168.147.202 | MON + MGR | 20 GB | - |
| ceph-mon2 | 192.168.182.205 | 192.168.225.205 | 192.168.147.205 | MON + MGR | 20 GB | - |
| ceph-mon3 | 192.168.182.206 | 192.168.225.206 | 192.168.147.206 | MON + MGR | 20 GB | - |
| ceph-osd1 | 192.168.182.203 | 192.168.225.203 | 192.168.147.203 | OSD | 20 GB | 50 GB |
| ceph-osd2 | 192.168.182.204 | 192.168.225.204 | 192.168.147.204 | OSD | 20 GB | 50 GB |
| ceph-osd3 | 192.168.182.207 | 192.168.225.207 | 192.168.147.207 | OSD | 20 GB | 50 GB |

**Yêu cầu phần cứng:**

| Node | vCPU | RAM | Disk 1 (OS) | Disk 2 (Data) |
|---|---|---|---|---|
| ceph-mon1/2/3 | 2 | 4 GB | 20 GB | - |
| ceph-osd1/2/3 | 2 | 4 GB | 20 GB | 50 GB |

---

## 2. Chuẩn bị OS trên tất cả nodes

> Thực hiện trên **tất cả 6 nodes**

### 2.1 Cấu hình hostname

```bash
# Trên từng node
hostnamectl set-hostname ceph-mon1   # thay tên tương ứng
```

### 2.2 Cấu hình /etc/hosts

```bash
cat >> /etc/hosts << 'EOF'
# Ceph HA cluster
192.168.225.202   ceph-mon1
192.168.225.205   ceph-mon2
192.168.225.206   ceph-mon3
192.168.225.203   ceph-osd1
192.168.225.204   ceph-osd2
192.168.225.207   ceph-osd3
# OpenStack nodes
192.168.225.195   controller
192.168.225.196   compute1
EOF
```

### 2.3 Cấu hình network

Trên RHEL 9, dùng `nmcli con mod` để chỉ sửa những field cần thiết - giữ nguyên `uuid`, `autoconnect-priority` và các field khác của file gốc.

Trên **ceph-mon1** (thay IP tương ứng cho các node khác):

```bash
# ens160 - NAT/Internet
nmcli con mod ens160 \
  ipv4.method manual \
  ipv4.addresses "192.168.182.202/24" \
  ipv4.gateway "192.168.182.2" \
  ipv4.dns "8.8.8.8" \
  ipv6.method disabled

# ens192 - Management
nmcli con mod ens192 \
  ipv4.method manual \
  ipv4.addresses "192.168.225.202/24" \
  ipv4.gateway "" \
  ipv6.method disabled

# ens224 - Cluster network
nmcli con mod ens224 \
  ipv4.method manual \
  ipv4.addresses "192.168.147.202/24" \
  ipv4.gateway "" \
  ipv6.method disabled

# Apply
nmcli con up ens160
nmcli con up ens192
nmcli con up ens224

# Verify
ip addr show ens160
ip addr show ens192
ip addr show ens224
```

> `nmcli con mod` chỉ ghi đè field được chỉ định, `uuid`/`autoconnect-priority`/`timestamp` giữ nguyên.

### 2.4 Cấu hình SELinux và Firewall

```bash
# SELinux - set permissive cho lab (production nên dùng enforcing với policy đúng)
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# Firewall - mở ports cần thiết
firewall-cmd --permanent --add-service=ceph
firewall-cmd --permanent --add-service=ceph-mon
firewall-cmd --permanent --add-port=8443/tcp   # dashboard
firewall-cmd --permanent --add-port=9283/tcp   # prometheus
firewall-cmd --permanent --add-port=7480/tcp   # RGW
firewall-cmd --reload

# Hoặc disable firewall cho lab
systemctl stop firewalld
systemctl disable firewalld
```

### 2.5 Cài đặt package cơ bản

```bash
# Update system
dnf update -y

# Cài packages cần thiết
dnf install -y chrony curl wget vim python3 podman

# Bắt buộc: cephadm dùng podman để chạy containers
systemctl enable --now podman
```

### 2.6 Cấu hình NTP

```bash
cat > /etc/chrony.conf << 'EOF'
server controller iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF

systemctl enable --now chronyd
chronyc tracking
```

### 2.7 Cấu hình SSH key từ ceph-mon1

Trên **ceph-mon1**:

```bash
ssh-keygen -q -N "" -f ~/.ssh/id_rsa 2>/dev/null || true

# Copy key sang tất cả nodes
for node in ceph-mon2 ceph-mon3 ceph-osd1 ceph-osd2 ceph-osd3; do
  ssh-copy-id root@$node
done

# Copy sang OpenStack nodes
ssh-copy-id root@controller
ssh-copy-id root@compute1
```

---

## 3. Cài đặt Ceph bằng cephadm

> Thực hiện trên **ceph-mon1**

### 3.1 Cài đặt cephadm

```bash
# Thêm Ceph repo
dnf install -y centos-release-ceph-squid 2>/dev/null || \
  dnf config-manager --add-repo https://download.ceph.com/rpm-squid/el9/x86_64/

# Cài cephadm và ceph-common
dnf install -y cephadm ceph-common

# Verify
cephadm version
```

> Với RHEL có subscription, dùng:
> ```bash
> subscription-manager repos --enable=rhceph-6-tools-for-rhel-9-x86_64-rpms
> dnf install -y cephadm
> ```

### 3.2 Bootstrap cluster

```bash
cephadm bootstrap \
  --mon-ip 192.168.225.202 \
  --cluster-network 192.168.147.0/24 \
  --initial-dashboard-user admin \
  --initial-dashboard-password Welcome123 \
  --allow-overwrite

# Output:
# Ceph Dashboard: https://192.168.225.202:8443
# Username: admin / Password: Welcome123
```

### 3.3 Cài ceph-common và verify

```bash
cephadm install ceph-common

ceph -v
# ceph version 19.x.x (squid)

ceph status
```

---

## 4. Thêm MON nodes

> Thực hiện trên **ceph-mon1**

### 4.1 Copy SSH key cephadm sang tất cả nodes

```bash
# Copy ceph public key
for node in ceph-mon2 ceph-mon3 ceph-osd1 ceph-osd2 ceph-osd3; do
  ssh-copy-id -f -i /etc/ceph/ceph.pub root@$node
done
```

### 4.2 Thêm MON hosts

```bash
# Thêm hosts vào cluster
ceph orch host add ceph-mon2 192.168.225.205
ceph orch host add ceph-mon3 192.168.225.206
ceph orch host add ceph-osd1 192.168.225.203
ceph orch host add ceph-osd2 192.168.225.204
ceph orch host add ceph-osd3 192.168.225.207

# Verify
ceph orch host ls
```

### 4.3 Deploy MON trên 3 nodes

```bash
# Chỉ định 3 nodes làm MON
ceph orch apply mon "ceph-mon1,ceph-mon2,ceph-mon3"

# Theo dõi
watch ceph orch ls
# Chờ: mon RUNNING 3/3

# Verify quorum
ceph mon stat
# Phải thấy: 3 mons at ..., quorum 0,1,2 ceph-mon1,ceph-mon2,ceph-mon3
```

### 4.4 Deploy MGR trên 3 nodes

```bash
# MGR active/standby trên 3 nodes
ceph orch apply mgr "ceph-mon1,ceph-mon2,ceph-mon3"

# Verify
ceph mgr stat
# Phải thấy: active: ceph-mon1, standbys: ceph-mon2, ceph-mon3
```

---

## 5. Thêm OSD nodes

> Thực hiện trên **ceph-mon1**

### 5.1 Thêm disk vào VM (VMware)

Với mỗi OSD VM (ceph-osd1, ceph-osd2, ceph-osd3):
```
VMware → VM Settings → Add → Hard Disk → SCSI → 50GB
```

### 5.2 Kiểm tra disk available

```bash
ceph orch device ls --refresh

# Phải thấy /dev/sdb trên ceph-osd1, ceph-osd2, ceph-osd3
# Status: Available=Yes
```

### 5.3 Wipe disk nếu cần

```bash
for node in ceph-osd1 ceph-osd2 ceph-osd3; do
  ssh root@$node "wipefs -a /dev/sdb && sgdisk --zap-all /dev/sdb"
done
```

### 5.4 Thêm OSD

```bash
# Thêm tất cả disk available
ceph orch apply osd --all-available-devices

# Theo dõi
watch ceph status
# Chờ: osd: 3 osds: 3 up, 3 in
```

---

## 6. Cấu hình HA và replication

> Thực hiện trên **ceph-mon1**

### 6.1 Set replication size = 3 (production HA)

```bash
# Với 3 OSD, dùng replication=3 (mỗi object có 3 bản sao)
ceph config set global osd_pool_default_size 3
ceph config set global osd_pool_default_min_size 2

# min_size=2: cluster vẫn accept write khi còn 2/3 OSD
# (mất 1 OSD vẫn hoạt động bình thường)

# Verify
ceph status
# Phải thấy: HEALTH_OK
```

### 6.2 Label nodes theo role

```bash
# Gán labels để dễ quản lý
ceph orch host label add ceph-mon1 mon
ceph orch host label add ceph-mon2 mon
ceph orch host label add ceph-mon3 mon
ceph orch host label add ceph-osd1 osd
ceph orch host label add ceph-osd2 osd
ceph orch host label add ceph-osd3 osd

# Verify
ceph orch host ls
```

### 6.3 Cấu hình CRUSH rule cho HA

```bash
# Verify CRUSH topology
ceph osd tree
# Phải thấy 3 hosts riêng biệt, mỗi host 1 OSD

# Rule mặc định đã đảm bảo replicas trên host khác nhau
ceph osd crush rule dump replicated_rule
# step chooseleaf firstn 0 type host → OK
```

### 6.4 Verify HA

```bash
ceph status
# Phải thấy:
#   health: HEALTH_OK
#   mon: 3 daemons, quorum ceph-mon1,ceph-mon2,ceph-mon3
#   mgr: ceph-mon1(active), standbys: ceph-mon2, ceph-mon3
#   osd: 3 osds: 3 up, 3 in

ceph osd tree
# Phải thấy 3 hosts, mỗi host 1 OSD
```

---

## 7. Tạo pools cho OpenStack

```bash
# Với 3 OSD, PG count phù hợp hơn
# Công thức: (OSDs × 100) / replication / pool_count
# = (3 × 100) / 3 / 4 = 25 → làm tròn lên 32

ceph osd pool create volumes 32
ceph osd pool create images  32
ceph osd pool create backups 32
ceph osd pool create vms     32

rbd pool init volumes
rbd pool init images
rbd pool init backups
rbd pool init vms

# Tạo users
ceph auth get-or-create client.glance \
  mon 'profile rbd' \
  osd 'profile rbd pool=images' \
  mgr 'profile rbd pool=images'

ceph auth get-or-create client.cinder \
  mon 'profile rbd' \
  osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd-read-only pool=images' \
  mgr 'profile rbd pool=volumes, profile rbd pool=vms'

ceph auth get-or-create client.nova \
  mon 'profile rbd' \
  osd 'profile rbd pool=vms, profile rbd-read-only pool=images' \
  mgr 'profile rbd pool=vms'

# Lưu keyring
ceph auth get-or-create client.glance > /etc/ceph/ceph.client.glance.keyring
ceph auth get-or-create client.cinder > /etc/ceph/ceph.client.cinder.keyring
ceph auth get-or-create client.nova   > /etc/ceph/ceph.client.nova.keyring

# Copy sang OpenStack nodes
for node in controller compute1; do
  ssh root@$node "mkdir -p /etc/ceph"
  scp /etc/ceph/ceph.conf root@$node:/etc/ceph/
done
scp /etc/ceph/ceph.client.glance.keyring root@controller:/etc/ceph/
scp /etc/ceph/ceph.client.cinder.keyring root@controller:/etc/ceph/
scp /etc/ceph/ceph.client.cinder.keyring root@compute1:/etc/ceph/
scp /etc/ceph/ceph.client.nova.keyring   root@compute1:/etc/ceph/
```

---

## 8. Kiểm tra HA

### 8.1 Test MON failure

```bash
# Stop MON trên ceph-mon2
ssh root@ceph-mon2 "systemctl stop ceph-mon@ceph-mon2 2>/dev/null || \
  podman stop \$(podman ps -q --filter name=ceph-mon)"

# Cluster vẫn hoạt động với 2/3 MON
ceph status
# mon: 2 daemons, quorum ceph-mon1,ceph-mon3 (ceph-mon2 down)
# health: HEALTH_WARN (bình thường)

# Khôi phục
ssh root@ceph-mon2 "systemctl start ceph-mon@ceph-mon2 2>/dev/null || \
  podman start \$(podman ps -aq --filter name=ceph-mon)"
watch ceph status
```

### 8.2 Test OSD failure

```bash
# Stop OSD trên ceph-osd1
ssh root@ceph-osd1 "systemctl stop ceph-osd@0 2>/dev/null || \
  podman stop \$(podman ps -q --filter name=ceph-osd)"

# Cluster degraded nhưng vẫn hoạt động (min_size=2)
ceph status
# osd: 2 osds: 2 up, 3 in
# health: HEALTH_WARN, degraded objects

# Ghi data trong khi OSD down
rados bench -p volumes 10 write --no-cleanup
# Phải thành công

# Khôi phục
ssh root@ceph-osd1 "systemctl start ceph-osd@0 2>/dev/null || \
  podman start \$(podman ps -aq --filter name=ceph-osd)"
watch ceph status
# Chờ recovery hoàn tất → HEALTH_OK
```

### 8.3 Verify replication

```bash
# Tạo test object
rados -p volumes put test-ha-object /etc/hostname

# Xem object nằm trên OSD nào
ceph osd map volumes test-ha-object
# up=[0,1,2] → 3 replicas trên 3 OSD khác nhau ✓

# Cleanup
rados -p volumes rm test-ha-object
```

---

## So sánh Lab vs HA

| Tiêu chí | Lab (3 VM) | HA (6 VM) |
|---|---|---|
| MON count | 1 | 3 |
| OSD count | 2 | 3 |
| Replication | 2 | 3 |
| Chịu lỗi MON | 0 | 1 |
| Chịu lỗi OSD | 0 | 1 |
| Usable capacity | 50% | 33% |
| Phù hợp | Lab/Dev | Production |

---

Trước: [01-ceph-cluster.md](01-ceph-cluster.md)
