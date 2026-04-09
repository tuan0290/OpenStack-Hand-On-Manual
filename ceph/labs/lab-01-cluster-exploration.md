# Lab 01: Khám phá Ceph Cluster

> Mục tiêu: Hiểu cách đọc trạng thái cluster, topology, và các thành phần đang chạy.

---

## 1. Cluster Status

```bash
# Tổng quan nhanh
ceph status

# Chỉ xem health
ceph health
ceph health detail

# Realtime event log
ceph -w
# Ctrl+C để thoát
```

Đọc output `ceph status`:
```
cluster:
  id:     <uuid>           ← cluster ID duy nhất
  health: HEALTH_OK        ← trạng thái tổng thể

services:
  mon: 1 daemons           ← số MON đang chạy
  mgr: ceph-mon1(active)   ← MGR active
  osd: 2 osds: 2 up, 2 in ← 2 OSD up và tham gia cluster

data:
  pools: 4 pools           ← số pool
  objects: 10 objects      ← số objects
  usage: 100 MiB used      ← dung lượng đã dùng
  avail: 99 GiB            ← dung lượng còn trống
```

---

## 2. Topology - OSD Tree

```bash
# Xem cây topology
ceph osd tree

# Output:
# ID  CLASS  WEIGHT   TYPE NAME        STATUS  REWEIGHT  PRI-AFF
# -1         0.09769  root default
# -3         0.04880      host ceph-osd1
#  0    hdd  0.04880          osd.0        up   1.00000  1.00000
# -5         0.04880      host ceph-osd2
#  1    hdd  0.04880          osd.1        up   1.00000  1.00000

# Xem dạng JSON
ceph osd tree --format json | python3 -m json.tool
```

Giải thích:
- `WEIGHT` = dung lượng disk (TB), ảnh hưởng đến lượng data được phân phối
- `REWEIGHT` = điều chỉnh thủ công (1.0 = bình thường, 0 = không nhận data)
- `STATUS` = up/down

---

## 3. MON và MGR

```bash
# MON status
ceph mon stat
ceph mon dump

# Quorum status
ceph quorum_status | python3 -m json.tool

# MGR status
ceph mgr stat
ceph mgr module ls | grep -E "on|off"
```

---

## 4. OSD Details

```bash
# Thống kê OSD
ceph osd stat

# Disk usage từng OSD
ceph osd df
# Cột quan trọng: SIZE, USE, AVAIL, %USE, VAR (variance)

# Performance metrics
ceph osd perf
# Cột: commit_latency(ms), apply_latency(ms)

# Dump toàn bộ OSD map
ceph osd dump | head -30
```

---

## 5. Pool Information

```bash
# List pools
ceph osd pool ls
ceph osd pool ls detail

# Stats từng pool
ceph df detail

# Xem config của pool cụ thể
ceph osd pool get volumes all
```

---

## 6. PG (Placement Groups)

```bash
# Tổng quan PG
ceph pg stat

# List PG và trạng thái
ceph pg dump | head -20

# PG nào đang có vấn đề
ceph pg dump_stuck
ceph pg dump_stuck inactive
ceph pg dump_stuck unclean
```

---

## 7. Capacity Planning

```bash
# Tổng dung lượng cluster
ceph df

# Raw vs usable capacity
# Raw = tổng disk
# Usable = Raw / replication_size
# Ví dụ: 2 OSD × 50GB = 100GB raw, replication=2 → 50GB usable

# Xem replication config
ceph config get osd osd_pool_default_size
```

---

## Câu hỏi kiểm tra

1. Cluster của bạn đang có bao nhiêu OSD? Bao nhiêu cái đang `up` và `in`?
2. Tổng dung lượng raw và usable là bao nhiêu?
3. `REWEIGHT` khác `WEIGHT` ở điểm nào?
4. Chạy `ceph pg stat` - có PG nào không ở trạng thái `active+clean` không?
