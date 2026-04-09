# Lab 02: Pool Management

> Mục tiêu: Tạo, cấu hình, và quản lý Ceph pools.

---

## 1. Tạo Pool

```bash
# Tạo replicated pool (mặc định)
ceph osd pool create test-pool 32

# Verify
ceph osd pool ls
ceph osd pool get test-pool all
```

---

## 2. Cấu hình Pool

```bash
# Set replication size
ceph osd pool set test-pool size 2
ceph osd pool set test-pool min_size 1

# Enable RBD application
rbd pool init test-pool

# Set quota
ceph osd pool set-quota test-pool max_bytes $((10 * 1024 * 1024 * 1024))  # 10GB
ceph osd pool set-quota test-pool max_objects 1000

# Xem quota
ceph osd pool get-quota test-pool
```

---

## 3. Pool Statistics

```bash
# Usage
ceph df detail | grep test-pool

# Objects trong pool
rados -p test-pool ls

# Tạo test object
rados -p test-pool put test-object /etc/hostname
rados -p test-pool ls
rados -p test-pool stat test-object

# Đọc object
rados -p test-pool get test-object /tmp/test-output
cat /tmp/test-output
```

---

## 4. PG Autoscaler

```bash
# Bật pg_autoscaler module
ceph mgr module enable pg_autoscaler

# Xem recommendation
ceph osd pool autoscale-status

# Set mode cho pool
ceph osd pool set test-pool pg_autoscale_mode on
# Modes: on (tự động), warn (chỉ cảnh báo), off (tắt)
```

---

## 5. Snapshot Pool

```bash
# Tạo pool snapshot
ceph osd pool mksnap test-pool snap1

# List snapshots
ceph osd pool lssnap test-pool

# Xóa snapshot
ceph osd pool rmsnap test-pool snap1
```

---

## 6. Rename và Delete Pool

```bash
# Rename pool
ceph osd pool rename test-pool test-pool-renamed

# Xóa pool (cần enable deletion trước)
ceph config set mon mon_allow_pool_delete true
ceph osd pool delete test-pool-renamed test-pool-renamed --yes-i-really-really-mean-it

# Tắt lại sau khi xóa
ceph config set mon mon_allow_pool_delete false
```

---

## Bài tập

1. Tạo pool `lab-rbd` với 32 PG, replication=2, enable RBD application
2. Set quota 5GB cho pool đó
3. Tạo 3 objects bất kỳ vào pool
4. Xem PG autoscale recommendation
5. Xóa pool sau khi hoàn thành
