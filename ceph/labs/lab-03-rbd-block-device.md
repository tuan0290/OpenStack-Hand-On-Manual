# Lab 03: RBD - Block Device

> Mục tiêu: Tạo, mount, snapshot và clone RBD images.

---

## 1. Tạo RBD Image

```bash
# Tạo image 1GB trong pool volumes
rbd create --size 1024 volumes/test-disk
# hoặc
rbd create volumes/test-disk --size 1G

# List images
rbd ls volumes
rbd ls -l volumes  # với details

# Xem thông tin image
rbd info volumes/test-disk
```

---

## 2. Map và Mount trên Linux

```bash
# Cài rbd kernel module (nếu chưa có)
modprobe rbd

# Map image thành block device
rbd map volumes/test-disk
# Output: /dev/rbd0

# Verify
rbd showmapped
lsblk | grep rbd

# Format và mount
mkfs.ext4 /dev/rbd0
mkdir -p /mnt/rbd-test
mount /dev/rbd0 /mnt/rbd-test

# Test ghi data
dd if=/dev/urandom of=/mnt/rbd-test/testfile bs=1M count=100
df -h /mnt/rbd-test
```

---

## 3. Resize Image

```bash
# Tăng size (online resize)
rbd resize volumes/test-disk --size 2G

# Verify
rbd info volumes/test-disk | grep size

# Resize filesystem (nếu đang mount)
resize2fs /dev/rbd0

df -h /mnt/rbd-test
```

---

## 4. Snapshot

```bash
# Tạo snapshot
rbd snap create volumes/test-disk@snap1

# List snapshots
rbd snap ls volumes/test-disk

# Ghi thêm data sau snapshot
echo "data after snap1" > /mnt/rbd-test/after-snap.txt

# Tạo snapshot thứ 2
rbd snap create volumes/test-disk@snap2

# Xem diff giữa 2 snapshots
rbd diff volumes/test-disk --snap snap1
```

---

## 5. Rollback Snapshot

```bash
# Unmount trước khi rollback
umount /mnt/rbd-test
rbd unmap /dev/rbd0

# Rollback về snap1
rbd snap rollback volumes/test-disk@snap1

# Map và mount lại
rbd map volumes/test-disk
mount /dev/rbd0 /mnt/rbd-test

# Verify - file after-snap.txt không còn
ls /mnt/rbd-test/
```

---

## 6. Clone từ Snapshot

```bash
# Protect snapshot trước khi clone (bắt buộc)
rbd snap protect volumes/test-disk@snap1

# Clone
rbd clone volumes/test-disk@snap1 volumes/test-disk-clone

# Verify
rbd info volumes/test-disk-clone
# parent: volumes/test-disk@snap1

# Flatten clone (tách khỏi parent, độc lập hoàn toàn)
rbd flatten volumes/test-disk-clone
rbd info volumes/test-disk-clone
# parent: (none)
```

---

## 7. Export và Import

```bash
# Export image ra file
rbd export volumes/test-disk /tmp/test-disk.img

# Import từ file
rbd import /tmp/test-disk.img volumes/test-disk-imported

# Export chỉ diff (incremental backup)
rbd export-diff volumes/test-disk@snap1 /tmp/snap1.diff
rbd export-diff --from-snap snap1 volumes/test-disk@snap2 /tmp/snap1-to-snap2.diff
```

---

## 8. Dọn dẹp

```bash
umount /mnt/rbd-test 2>/dev/null || true
rbd unmap /dev/rbd0 2>/dev/null || true

# Xóa snapshots
rbd snap unprotect volumes/test-disk@snap1
rbd snap rm volumes/test-disk@snap1
rbd snap rm volumes/test-disk@snap2
rbd snap purge volumes/test-disk  # xóa tất cả snapshots

# Xóa images
rbd rm volumes/test-disk
rbd rm volumes/test-disk-clone 2>/dev/null || true
rbd rm volumes/test-disk-imported 2>/dev/null || true
```

---

## Bài tập

1. Tạo RBD image 2GB, format ext4, mount vào `/mnt/lab`
2. Ghi 500MB data vào image
3. Tạo snapshot `before-change`
4. Xóa 200MB data, tạo snapshot `after-change`
5. Rollback về `before-change` và verify data còn đủ
6. Clone từ `before-change`, flatten clone
