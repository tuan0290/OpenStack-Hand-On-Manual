# Tích hợp Ceph với OpenStack

> Tài liệu này hướng dẫn tích hợp Ceph làm storage backend cho OpenStack, thay thế:
> - LVM (Cinder) → Ceph RBD
> - Filesystem (Glance) → Ceph RBD
> - Nova ephemeral disk → Ceph RBD
> - Swift (tùy chọn) → Ceph RGW

## Yêu cầu

- Ceph cluster đang chạy (xem [ceph/01-ceph-cluster.md](../ceph/01-ceph-cluster.md))
- OpenStack đã cài đặt đầy đủ (01-14)
- Ceph pools đã tạo: `images`, `volumes`, `vms`, `backups`

## Kiến trúc sau tích hợp

```
OpenStack                          Ceph Cluster
┌──────────────────────┐          ┌─────────────────────────┐
│ controller           │          │ ceph-mon1 (.202)         │
│  ├─ Glance ──────────┼──RBD────►│  pool: images            │
│  └─ Cinder ──────────┼──RBD────►│  pool: volumes           │
├──────────────────────┤          │  pool: backups           │
│ compute1             │          │  pool: vms               │
│  └─ Nova ────────────┼──RBD────►│                          │
└──────────────────────┘          │ ceph-osd1 (.203)         │
                                  │ ceph-osd2 (.204)         │
                                  └─────────────────────────┘
```

## Mục lục

1. [Chuẩn bị trên Ceph cluster](#1-chuẩn-bị-trên-ceph-cluster)
2. [Tích hợp Glance](#2-tích-hợp-glance)
3. [Tích hợp Cinder](#3-tích-hợp-cinder)
4. [Tích hợp Nova](#4-tích-hợp-nova)
5. [Tích hợp RGW thay Swift (tùy chọn)](#5-tích-hợp-rgw-thay-swift-tùy-chọn)
6. [Kiểm tra end-to-end](#6-kiểm-tra-end-to-end)

---

## 1. Chuẩn bị trên Ceph cluster

> Thực hiện trên **ceph-mon1**

```bash
# Tạo pools nếu chưa có
ceph osd pool create images  32
ceph osd pool create volumes 32
ceph osd pool create backups 32
ceph osd pool create vms     32

rbd pool init images
rbd pool init volumes
rbd pool init backups
rbd pool init vms

# Tạo users cho từng service
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

## 2. Tích hợp Glance

> Thực hiện trên **controller**

```bash
apt install -y python3-rbd ceph-common
chown glance:glance /etc/ceph/ceph.client.glance.keyring
chmod 640 /etc/ceph/ceph.client.glance.keyring
```

Sửa `/etc/glance/glance-api.conf`:

**Section `[DEFAULT]`:**
```ini
[DEFAULT]
enabled_backends = ceph:rbd
default_backend = ceph
```

**Section `[glance_store]`:**
```ini
[glance_store]
default_backend = ceph
```

**Thêm section `[ceph]` vào cuối file:**
```ini
[ceph]
rbd_store_pool = images
rbd_store_user = glance
rbd_store_ceph_conf = /etc/ceph/ceph.conf
rbd_store_chunk_size = 8
```

```bash
systemctl restart glance-api

# Verify: upload image và check trong Ceph
source ~/admin-openrc
wget -q http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img -O /tmp/cirros.img
openstack image create --disk-format qcow2 --container-format bare \
  --public --file /tmp/cirros.img cirros-ceph-test

IMAGE_ID=$(openstack image show cirros-ceph-test -f value -c id)
ssh root@ceph-mon1 "rbd ls images | grep $IMAGE_ID"
# Phải thấy image ID → Glance đang dùng Ceph

openstack image delete cirros-ceph-test
```

---

## 3. Tích hợp Cinder

> Thực hiện trên **controller**

```bash
apt install -y python3-rbd ceph-common cinder-volume
chown cinder:cinder /etc/ceph/ceph.client.cinder.keyring
chmod 640 /etc/ceph/ceph.client.cinder.keyring
```

Sửa `/etc/cinder/cinder.conf`:

**Section `[DEFAULT]`** - đổi `enabled_backends`:
```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller
auth_strategy = keystone
my_ip = 192.168.225.195
enabled_backends = ceph
glance_api_servers = http://controller:9292
```

**Thêm section `[ceph]`:**
```ini
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
rbd_secret_uuid = <CINDER_UUID>
```

> `rbd_secret_uuid` điền sau bước 4 (tạo libvirt secret).

```bash
systemctl restart cinder-volume cinder-scheduler apache2
systemctl enable cinder-volume
```

---

## 4. Tích hợp Nova

> Thực hiện trên **compute1**

### 4.1 Tạo libvirt secrets

```bash
apt install -y python3-rbd ceph-common

# Thêm ceph nodes vào /etc/hosts nếu chưa có
echo "192.168.225.202   ceph-mon1" >> /etc/hosts
echo "192.168.225.203   ceph-osd1" >> /etc/hosts
echo "192.168.225.204   ceph-osd2" >> /etc/hosts

# Tạo secret cho client.cinder
CINDER_UUID=$(uuidgen)
CINDER_KEY=$(ssh root@ceph-mon1 "ceph auth get-key client.cinder")

cat > /tmp/cinder-secret.xml << EOF
<secret ephemeral='no' private='no'>
  <uuid>$CINDER_UUID</uuid>
  <usage type='ceph'>
    <name>client.cinder secret</name>
  </usage>
</secret>
EOF
virsh secret-define --file /tmp/cinder-secret.xml
virsh secret-set-value $CINDER_UUID --base64 $CINDER_KEY
echo "CINDER_UUID=$CINDER_UUID"

# Tạo secret cho client.nova
NOVA_UUID=$(uuidgen)
NOVA_KEY=$(ssh root@ceph-mon1 "ceph auth get-key client.nova")

cat > /tmp/nova-secret.xml << EOF
<secret ephemeral='no' private='no'>
  <uuid>$NOVA_UUID</uuid>
  <usage type='ceph'>
    <name>client.nova secret</name>
  </usage>
</secret>
EOF
virsh secret-define --file /tmp/nova-secret.xml
virsh secret-set-value $NOVA_UUID --base64 $NOVA_KEY
echo "NOVA_UUID=$NOVA_UUID"

# Verify cả 2 secrets có value
virsh secret-get-value $CINDER_UUID
virsh secret-get-value $NOVA_UUID
```

### 4.2 Cập nhật cinder.conf trên controller

```bash
# Trên controller - điền CINDER_UUID vào cinder.conf
sed -i "s/rbd_secret_uuid = <CINDER_UUID>/rbd_secret_uuid = $CINDER_UUID/" \
  /etc/cinder/cinder.conf
systemctl restart cinder-volume
```

### 4.3 Cấu hình Nova

```bash
# Trên compute1
chown nova:nova /etc/ceph/ceph.client.nova.keyring
chmod 640 /etc/ceph/ceph.client.nova.keyring
```

Sửa `/etc/nova/nova.conf` - thêm section `[libvirt]`:
```ini
[libvirt]
virt_type = qemu
images_type = rbd
images_rbd_pool = vms
images_rbd_ceph_conf = /etc/ceph/ceph.conf
rbd_user = nova
rbd_secret_uuid = <NOVA_UUID>
disk_cachemodes = network=writeback
hw_disk_discard = unmap
```

```bash
systemctl restart nova-compute
```

---

## 5. Tích hợp RGW thay Swift (tùy chọn)

> Thực hiện trên **ceph-mon1**

```bash
# Deploy RGW
ceph orch apply rgw default --placement="1 ceph-mon1" --port=7480

# Cấu hình Keystone auth
ceph config set client.rgw.default rgw_keystone_url http://controller:5000
ceph config set client.rgw.default rgw_keystone_api_version 3
ceph config set client.rgw.default rgw_keystone_admin_user swift
ceph config set client.rgw.default rgw_keystone_admin_password Welcome123
ceph config set client.rgw.default rgw_keystone_admin_project service
ceph config set client.rgw.default rgw_keystone_admin_domain Default
ceph config set client.rgw.default rgw_keystone_accepted_roles "member,admin,user"
ceph config set client.rgw.default rgw_swift_account_in_url true
ceph config set client.rgw.default rgw_swift_url_prefix swift
ceph orch restart rgw.default
```

Trên **controller** - đổi endpoint Swift sang RGW:

```bash
source ~/admin-openrc

# Xóa endpoint Swift cũ
openstack endpoint list --service object-store -f value -c ID | \
  xargs -I{} openstack endpoint delete {}

# Tạo endpoint mới trỏ về RGW
openstack endpoint create --region RegionOne \
  object-store public "http://192.168.225.202:7480/swift/v1/AUTH_%(project_id)s"
openstack endpoint create --region RegionOne \
  object-store internal "http://192.168.225.202:7480/swift/v1/AUTH_%(project_id)s"
openstack endpoint create --region RegionOne \
  object-store admin "http://192.168.225.202:7480/swift/v1"
```

---

## 6. Kiểm tra end-to-end

```bash
source ~/admin-openrc

# 1. Glance - upload image
openstack image create --disk-format qcow2 --container-format bare \
  --public --file /tmp/cirros.img cirros-ceph
IMAGE_ID=$(openstack image show cirros-ceph -f value -c id)
ssh root@ceph-mon1 "rbd ls images | grep $IMAGE_ID" && echo "✓ Glance → Ceph OK"

# 2. Cinder - tạo volume type và volume
openstack volume type create ceph-rbd --property volume_backend_name=ceph
openstack volume create --size 1 --type ceph-rbd test-vol
sleep 10
VOL_ID=$(openstack volume show test-vol -f value -c id)
ssh root@ceph-mon1 "rbd ls volumes | grep $VOL_ID" && echo "✓ Cinder → Ceph OK"

# 3. Nova - tạo VM
NET_ID=$(openstack network show selfservice-net -f value -c id)
openstack server create --flavor m1.tiny --image cirros-ceph \
  --nic net-id=$NET_ID ceph-test-vm
sleep 30
SERVER_ID=$(openstack server show ceph-test-vm -f value -c id)
ssh root@ceph-mon1 "rbd ls vms | grep $SERVER_ID" && echo "✓ Nova → Ceph OK"

# 4. Attach volume vào VM
openstack server add volume ceph-test-vm test-vol
sleep 5
openstack volume show test-vol -f value -c status  # phải là in-use

# Cleanup
openstack server remove volume ceph-test-vm test-vol
openstack server delete ceph-test-vm
openstack volume delete test-vol
openstack image delete cirros-ceph
```

---

Trước: [14-ceilometer.md](14-ceilometer.md)

---

## Hỏi & Đáp

### Tại sao cần 2 libvirt secrets (cinder và nova)?

QEMU cần biết key nào dùng cho pool nào:
- `client.cinder` → pool `volumes` (Cinder volumes)
- `client.nova` → pool `vms` (Nova ephemeral disks)

Nếu dùng chung 1 secret → QEMU không phân biệt được → Permission denied.

### Migrate images cũ từ filesystem sang Ceph?

```bash
# List images đang lưu trên filesystem
ls /var/lib/glance/images/

# Với mỗi image, export rồi re-import qua Glance API
# (Glance sẽ tự lưu vào Ceph backend mới)
for img_id in $(openstack image list -f value -c ID); do
  openstack image save $img_id --file /tmp/img-$img_id.raw
  openstack image delete $img_id
  openstack image create --file /tmp/img-$img_id.raw \
    --disk-format raw --container-format bare img-$img_id
  rm /tmp/img-$img_id.raw
done
```

### Ceph cluster down thì OpenStack có bị ảnh hưởng không?

Có - nếu Ceph down:
- Glance không upload/download được image
- Cinder không tạo/attach được volume
- Nova không boot được VM mới (ephemeral disk)
- VM đang chạy vẫn OK nếu data đã được cache

→ Đây là lý do production cần ít nhất 3 OSD và 3 MON.
