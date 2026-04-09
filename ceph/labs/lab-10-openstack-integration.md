# Lab 10: OpenStack + Ceph Integration

> Mục tiêu: Tích hợp Ceph với Glance, Cinder, Nova và verify end-to-end.

---

## 1. Verify Ceph Pools và Users

```bash
# Trên ceph-mon1
ceph df
# Phải thấy: volumes, images, vms, backups pools

ceph auth ls | grep -E "client\.(glance|cinder|nova)"
# Phải thấy 3 users đã tạo
```

---

## 2. Test Glance → Ceph

```bash
# Trên controller
source ~/admin-openrc

# Upload image
wget -q http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img -O /tmp/cirros.img
openstack image create \
  --disk-format qcow2 \
  --container-format bare \
  --public \
  --file /tmp/cirros.img \
  cirros-ceph

# Verify image lưu trong Ceph
IMAGE_ID=$(openstack image show cirros-ceph -f value -c id)
echo "Image ID: $IMAGE_ID"

# Kiểm tra trong Ceph pool
ssh root@ceph-mon1 "rbd ls images"
# Phải thấy: $IMAGE_ID

ssh root@ceph-mon1 "rbd info images/$IMAGE_ID"
```

---

## 3. Test Cinder → Ceph

```bash
# Tạo volume type Ceph
openstack volume type create ceph-rbd \
  --property volume_backend_name=ceph

# Tạo volume
openstack volume create \
  --size 1 \
  --type ceph-rbd \
  test-ceph-volume

# Chờ available
watch openstack volume show test-ceph-volume -f value -c status

# Verify trong Ceph
VOLUME_ID=$(openstack volume show test-ceph-volume -f value -c id)
ssh root@ceph-mon1 "rbd ls volumes | grep $VOLUME_ID"
ssh root@ceph-mon1 "rbd info volumes/volume-$VOLUME_ID"
```

---

## 4. Test Nova → Ceph (Boot from Volume)

```bash
# Tạo VM boot từ Ceph volume
NET_ID=$(openstack network show selfservice-net -f value -c id)

openstack server create \
  --flavor m1.tiny \
  --image cirros-ceph \
  --boot-from-volume 5 \
  --nic net-id=$NET_ID \
  ceph-test-vm

# Chờ ACTIVE
watch openstack server show ceph-test-vm -f value -c status

# Verify ephemeral disk trong Ceph vms pool
SERVER_ID=$(openstack server show ceph-test-vm -f value -c id)
ssh root@ceph-mon1 "rbd ls vms | grep $SERVER_ID"
```

---

## 5. Attach Ceph Volume vào VM

```bash
# Attach volume vào VM
openstack server add volume ceph-test-vm test-ceph-volume

# Verify attachment
openstack volume show test-ceph-volume -f value -c attachments

# Vào VM console và format/mount volume
openstack console url show ceph-test-vm
# Truy cập console, login cirros/gocubsgo
# fdisk -l → thấy /dev/vdb
# mkfs.ext4 /dev/vdb
# mount /dev/vdb /mnt
# df -h
```

---

## 6. Ceph Volume Snapshot từ OpenStack

```bash
# Tạo snapshot của Ceph volume
openstack volume snapshot create \
  --volume test-ceph-volume \
  ceph-vol-snap1

# Verify snapshot trong Ceph
SNAP_ID=$(openstack volume snapshot show ceph-vol-snap1 -f value -c id)
ssh root@ceph-mon1 "rbd snap ls volumes/volume-$VOLUME_ID"
# Phải thấy snapshot-$SNAP_ID

# Tạo volume mới từ snapshot
openstack volume create \
  --snapshot ceph-vol-snap1 \
  --size 1 \
  test-ceph-volume-from-snap
```

---

## 7. Live Migration với Ceph

```bash
# Ceph cho phép live migration vì disk ở shared storage
# (Cần có compute2 để test thực sự)

# Xem VM đang ở host nào
openstack server show ceph-test-vm -f value -c OS-EXT-SRV-ATTR:host

# Live migrate (nếu có compute2)
# openstack server migrate --live-migration ceph-test-vm
# watch openstack server show ceph-test-vm -f value -c OS-EXT-SRV-ATTR:host
```

---

## 8. Monitoring Ceph từ OpenStack

```bash
# Xem Ceph usage qua OpenStack
openstack volume service list
openstack volume backend pool list

# Capacity từ Ceph perspective
ssh root@ceph-mon1 "ceph df"
ssh root@ceph-mon1 "ceph osd pool stats volumes"
```

---

## 9. Dọn dẹp

```bash
openstack server delete ceph-test-vm
openstack volume snapshot delete ceph-vol-snap1
openstack volume delete test-ceph-volume
openstack volume delete test-ceph-volume-from-snap
openstack image delete cirros-ceph
```

---

## Bài tập

1. Upload Ubuntu image lên Glance, verify lưu trong Ceph `images` pool
2. Tạo 3 Ceph volumes, verify tất cả xuất hiện trong `volumes` pool
3. Boot VM từ Ceph volume, attach thêm 1 volume, ghi data
4. Tạo snapshot của volume đang attached, restore sang volume mới
5. So sánh performance: boot từ local disk vs boot từ Ceph volume
