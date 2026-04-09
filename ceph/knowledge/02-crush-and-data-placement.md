# CRUSH Map và Data Placement

> Hiểu cách Ceph quyết định data đặt ở đâu - không cần lookup table trung tâm.

## 1. CRUSH là gì?

CRUSH (Controlled Replication Under Scalable Hashing) là thuật toán **tính toán** vị trí data thay vì **tra cứu** từ bảng trung tâm.

```
Hệ thống truyền thống:          Ceph CRUSH:
Client → Lookup Table → OSD     Client → Tính toán → OSD
         (bottleneck)                    (distributed)
```

**Lợi ích:**
- Không có single point of failure
- Client tự tính được OSD nào chứa data
- Thêm/xóa OSD không cần rebuild toàn bộ bảng

---

## 2. CRUSH Hierarchy

CRUSH tổ chức cluster theo cây phân cấp:

```
root (default)
├── rack (rack1)
│   ├── host (ceph-osd1)
│   │   └── osd.0  weight=0.049
│   └── host (ceph-osd2)
│       └── osd.1  weight=0.049
└── rack (rack2)
    └── host (ceph-osd3)
        └── osd.2  weight=0.049
```

**Các bucket types (từ thấp đến cao):**

| Type | Ý nghĩa |
|---|---|
| osd | Disk vật lý |
| host | Server |
| chassis | Blade chassis |
| rack | Tủ rack |
| row | Hàng rack |
| room | Phòng máy chủ |
| datacenter | Datacenter |
| root | Gốc của cây |

---

## 3. CRUSH Rule

Rule quyết định **cách chọn OSD** khi ghi data:

```bash
# Xem rules hiện tại
ceph osd crush rule ls
ceph osd crush rule dump replicated_rule
```

Rule mặc định:
```
rule replicated_rule {
    id 0
    type replicated
    step take default          # bắt đầu từ root "default"
    step chooseleaf firstn 0 type host   # chọn N host khác nhau
    step emit
}
```

`chooseleaf firstn 0 type host` nghĩa là:
- Chọn số lượng host = replication_size (0 = dùng pool size)
- Mỗi replica phải nằm trên **host khác nhau**
- Đảm bảo: nếu 1 host chết, data vẫn còn trên host khác

---

## 4. Placement Groups (PG) - Chi tiết

### 4.1 PG là gì?

PG là **đơn vị phân phối** data. Thay vì map từng object → OSD, Ceph map:
```
Object → PG → OSD(s)
```

```
Không có PG:                    Có PG:
1 triệu objects → 1 triệu       1 triệu objects → 32 PGs → 2 OSDs
entries trong map               (quản lý đơn giản hơn nhiều)
```

### 4.2 Tính PG từ object name

```python
# Pseudo code
pg_id = hash(object_name) % pg_num
# Ví dụ:
# hash("volume-abc123") % 32 = 7
# → object này thuộc PG 7
```

### 4.3 Tính số PG phù hợp

```
Công thức: PG = (OSDs × 100) / replication_size

Lab 2 OSD, replication=2:
PG = (2 × 100) / 2 = 100 → làm tròn xuống 2^n = 64

Với 4 pools chia đều:
PG/pool = 64 / 4 = 16 → dùng 32 (làm tròn lên)

Giới hạn an toàn: 100-200 PG/OSD
Tổng PG = 32 × 4 pools = 128 / 2 OSD = 64 PG/OSD ✓
```

### 4.4 PG States

```
active+clean        → Bình thường, đủ replicas
active+degraded     → Thiếu replica (OSD down nhưng cluster vẫn hoạt động)
active+recovering   → Đang tạo lại replica bị mất
active+backfilling  → Đang sync data về OSD mới join
active+remapped     → PG đã được assign sang OSD mới, chưa migrate xong
peering             → OSDs đang thương lượng về trạng thái PG
stale               → Không có primary OSD nào báo cáo về PG này
```

---

## 5. Ví dụ thực tế: Ghi 1 volume Cinder

```
1. Cinder tạo volume 1GB trong pool "volumes"
   → librbd tạo RBD image: volumes/volume-abc123

2. Nova boot VM, ghi 4MB vào volume
   → librbd chia thành 1 object: volumes/volume-abc123.0000000000000000

3. CRUSH tính:
   pg_id = hash("volume-abc123.0000000000000000") % 32 = 15
   PG 15 → osd.0 (primary), osd.1 (replica)

4. librbd ghi đến osd.0
   osd.0 ghi local → replicate sang osd.1
   Cả 2 xác nhận → ACK về Nova

5. Verify:
   ceph osd map volumes volume-abc123.0000000000000000
   # osdmap e24 pool 'volumes' (1) object 'volume-abc123.0000000000000000'
   # → pg 1.f (1.f) -> up ([0,1], p0) acting ([0,1], p0)
   # up=[0,1] → osd.0 và osd.1
   # p0 → primary là osd.0
```

---

## 6. Device Classes

Ceph hỗ trợ phân loại OSD theo loại disk:

```bash
# Xem class của từng OSD
ceph osd tree
# CLASS: hdd, ssd, nvme

# Tạo rule chỉ dùng SSD
ceph osd crush rule create-replicated ssd-rule default host ssd

# Tạo pool dùng SSD
ceph osd pool create fast-pool 32 32 replicated ssd-rule
```

**Use case:**
- Pool `vms` → SSD (VM boot nhanh)
- Pool `backups` → HDD (tiết kiệm chi phí)
- Pool `images` → SSD (Glance image load nhanh)
