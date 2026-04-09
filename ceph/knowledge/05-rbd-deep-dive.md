# RBD Deep Dive - RADOS Block Device

> Hiểu sâu về RBD - storage backend cho Cinder volumes và Nova ephemeral disks.

## 1. RBD là gì?

RBD (RADOS Block Device) là **block device ảo** được lưu phân tán trên Ceph cluster.

```
Từ góc nhìn của VM/OS:          Thực tế trong Ceph:
/dev/vda (1GB block device)     → 256 objects × 4MB/object
                                   phân tán trên nhiều OSD
```

---

## 2. Cấu trúc RBD Image

```
RBD Image: volumes/volume-abc123 (1GB)
│
├── Object: volumes/volume-abc123.0000000000000000 (4MB) → PG 7 → osd.0, osd.1
├── Object: volumes/volume-abc123.0000000000000001 (4MB) → PG 15 → osd.1, osd.0
├── Object: volumes/volume-abc123.0000000000000002 (4MB) → PG 3 → osd.0, osd.1
│   ...
└── Object: volumes/volume-abc123.00000000000000ff (4MB) → PG 22 → osd.1, osd.0

Tổng: 256 objects × 4MB = 1GB
```

**Object size mặc định:** 4MB (có thể thay đổi khi tạo image)

---

## 3. RBD Thin Provisioning

RBD dùng **thin provisioning** - chỉ tốn space khi thực sự ghi data:

```bash
# Tạo image 100GB
rbd create volumes/big-volume --size 100G

# Kiểm tra space thực tế dùng
rbd info volumes/big-volume
# disk_usage: 0 B  ← chưa ghi gì, không tốn space

# Sau khi ghi 1GB data
rbd info volumes/big-volume
# disk_usage: 1.0 GiB  ← chỉ tốn 1GB thực tế
```

---

## 4. RBD Snapshot

Snapshot là **point-in-time copy** của RBD image, dùng Copy-on-Write:

```
Trước snapshot:
Image: [A][B][C][D]

Tạo snapshot @snap1:
Image: [A][B][C][D]
Snap1: [A][B][C][D]  ← trỏ đến cùng objects

Ghi data mới vào Image (block B thay đổi):
Image: [A][B'][C][D]  ← B' là object mới
Snap1: [A][B][C][D]   ← B cũ vẫn còn cho snapshot
```

**Copy-on-Write:** Chỉ copy block khi có thay đổi → snapshot nhanh, tiết kiệm space.

```bash
# Tạo snapshot
rbd snap create volumes/my-volume@snap1

# List snapshots
rbd snap ls volumes/my-volume

# Rollback về snapshot
rbd snap rollback volumes/my-volume@snap1

# Xóa snapshot
rbd snap rm volumes/my-volume@snap1
```

---

## 5. RBD Clone

Clone tạo **writable copy** từ snapshot:

```
volumes/base-image@snap1 (protected)
    │
    ├── clone1 (writable) → VM1
    ├── clone2 (writable) → VM2
    └── clone3 (writable) → VM3

Tất cả clone share data với parent snapshot
→ Tạo 100 VM từ 1 image: không tốn 100x space
```

```bash
# Protect snapshot trước khi clone
rbd snap protect volumes/base-image@snap1

# Tạo clone
rbd clone volumes/base-image@snap1 volumes/vm1-disk

# Flatten clone (tách khỏi parent, độc lập hoàn toàn)
rbd flatten volumes/vm1-disk
```

**Glance + Cinder dùng clone:**
- Glance lưu image → tạo snapshot
- Cinder tạo volume từ image → clone snapshot
- Không cần copy toàn bộ image data

---

## 6. RBD Mirroring

RBD Mirroring replicate data sang cluster khác (DR):

```
Primary Cluster          Secondary Cluster
volumes/prod-vol ──────► volumes/prod-vol (mirror)
    │                         │
    │ write                   │ replicated
    ▼                         ▼
  osd.0, osd.1             osd.0, osd.1
```

```bash
# Enable mirroring trên pool
rbd mirror pool enable volumes image

# Add peer cluster
rbd mirror pool peer add volumes client.admin@secondary-cluster

# Xem mirror status
rbd mirror pool status volumes
```

---

## 7. Performance Tuning RBD

```bash
# Tăng concurrent requests (mặc định 64)
rbd config image set volumes/my-volume rbd_cache_max_dirty 67108864  # 64MB

# Enable RBD cache (client-side cache)
# Trong /etc/ceph/ceph.conf:
[client]
rbd_cache = true
rbd_cache_size = 67108864        # 64MB
rbd_cache_max_dirty = 50331648   # 48MB
rbd_cache_target_dirty = 33554432 # 32MB

# Discard support (thin provisioning reclaim)
# Trong nova.conf [libvirt]:
hw_disk_discard = unmap
```

---

## 8. Troubleshooting RBD

```bash
# Xem watchers (clients đang dùng image)
rbd status volumes/my-volume
# Nếu có watcher → image đang được mount

# Force remove image đang có watcher (nguy hiểm)
rbd rm --no-progress volumes/my-volume

# Kiểm tra image bị corrupt
rbd info volumes/my-volume
rados -p volumes ls | grep my-volume

# Export image để backup
rbd export volumes/my-volume /tmp/backup.img

# Import từ backup
rbd import /tmp/backup.img volumes/my-volume-restored
```
