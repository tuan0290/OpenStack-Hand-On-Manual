# Ceph Architecture - Kiến trúc vật lý và logic

## 1. Tổng quan

Ceph là hệ thống storage phân tán, tự quản lý, tự phục hồi. Không có single point of failure.

```
Client (OpenStack/App)
        │
        │ librados / librbd / libcephfs
        ▼
┌───────────────────────────────────────────────────────┐
│                    RADOS                               │
│  (Reliable Autonomic Distributed Object Store)        │
│                                                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ │
│  │   MON    │  │   MGR    │  │        OSD           │ │
│  │ (quorum) │  │(metrics) │  │  (data storage)      │ │
│  └──────────┘  └──────────┘  └──────────────────────┘ │
└───────────────────────────────────────────────────────┘
```

---

## 2. Kiến trúc vật lý

### 2.1 Các node trong cluster

```
Physical Layout:

┌─────────────────────────────────────────────────────────────┐
│                     Ceph Cluster                            │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  ceph-mon1   │  │  ceph-osd1   │  │  ceph-osd2   │      │
│  │              │  │              │  │              │      │
│  │  RAM: 4GB    │  │  RAM: 4GB    │  │  RAM: 4GB    │      │
│  │  Disk: 20GB  │  │  Disk OS:    │  │  Disk OS:    │      │
│  │  (OS only)   │  │    20GB      │  │    20GB      │      │
│  │              │  │  Disk Data:  │  │  Disk Data:  │      │
│  │  Services:   │  │    50GB      │  │    50GB      │      │
│  │  - ceph-mon  │  │              │  │              │      │
│  │  - ceph-mgr  │  │  Services:   │  │  Services:   │      │
│  │  - ceph-crash│  │  - ceph-osd  │  │  - ceph-osd  │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                                                             │
│  Networks:                                                  │
│  ens37 (192.168.225.x) ← Management / Public network       │
│  ens38 (192.168.147.x) ← Cluster network (replication)     │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Hai loại network trong Ceph

```
Public Network (ens37):
  Client → OSD (read/write requests)
  Client → MON (cluster map, auth)
  Admin → MGR (dashboard, API)

Cluster Network (ens38):
  OSD ↔ OSD (data replication)
  OSD ↔ OSD (recovery, backfill)
  → Tách biệt để không ảnh hưởng client traffic
```

---

## 3. Kiến trúc logic - CRUSH Map

### 3.1 CRUSH (Controlled Replication Under Scalable Hashing)

CRUSH là thuật toán quyết định **data đặt ở đâu** mà không cần lookup table trung tâm.

```
CRUSH Hierarchy (mặc định):

root (default)
└── datacenter
    └── rack
        └── host (ceph-osd1)
            └── osd.0 (weight: 0.049)
        └── host (ceph-osd2)
            └── osd.1 (weight: 0.049)
```

### 3.2 Luồng ghi data

```
Client muốn ghi object "foo" vào pool "volumes":

1. Client tính: PG = hash("foo") % num_PGs
   → PG 23

2. Client hỏi MON: PG 23 nằm ở OSD nào?
   MON trả về: Primary=osd.0, Replica=osd.1

3. Client ghi trực tiếp vào osd.0 (Primary)
   osd.0 replicate sang osd.1

4. Khi cả 2 OSD xác nhận → Client nhận ACK

┌────────┐    ┌─────┐    ┌───────┐    ┌───────┐
│ Client │───►│ MON │    │ osd.0 │───►│ osd.1 │
│        │◄───│     │    │(prim) │    │(repl) │
│        │         │    │       │    │       │
│        │─────────────►│       │    │       │
└────────┘              └───────┘    └───────┘
```

### 3.3 Placement Groups (PG)

```
Pool "volumes" (32 PGs, replication=2):

PG 0  → osd.0 (primary), osd.1 (replica)
PG 1  → osd.1 (primary), osd.0 (replica)
PG 2  → osd.0 (primary), osd.1 (replica)
...
PG 31 → osd.1 (primary), osd.0 (replica)

Objects trong pool:
  volume-abc → PG 7  → osd.0, osd.1
  volume-def → PG 15 → osd.1, osd.0
  volume-xyz → PG 3  → osd.0, osd.1
```

---

## 4. Các service/process của Ceph

### 4.1 MON (ceph-mon)

```
Vai trò:
  - Duy trì cluster map (OSD map, PG map, CRUSH map, MON map)
  - Quorum: cần đa số MON online (1/1, 2/3, 3/5)
  - Authentication (CephX)
  - Không lưu data thực tế

Process: ceph-mon
Config:  /etc/ceph/ceph.conf
Data:    /var/lib/ceph/mon/ceph-<hostname>/
Log:     /var/log/ceph/ceph-mon.<hostname>.log

Port:    3300 (v2 msgr), 6789 (v1 legacy)
```

### 4.2 OSD (ceph-osd)

```
Vai trò:
  - Lưu data thực tế (objects)
  - Replication: primary OSD nhận write, replicate sang replica OSDs
  - Recovery: tự phục hồi khi OSD fail
  - Heartbeat: ping các OSD khác, báo cáo lên MON

Mỗi disk = 1 OSD daemon
Process: ceph-osd
Config:  /etc/ceph/ceph.conf
Data:    /var/lib/ceph/osd/ceph-<id>/
Log:     /var/log/ceph/ceph-osd.<id>.log

Ports:   6800-7300 (dynamic range)

OSD States:
  up   = daemon đang chạy
  in   = đang tham gia cluster, chứa data
  down = daemon không chạy
  out  = bị loại khỏi cluster (sau 10 phút down)
```

### 4.3 MGR (ceph-mgr)

```
Vai trò:
  - Dashboard web UI (port 8443)
  - Metrics (Prometheus endpoint port 9283)
  - Orchestration (cephadm)
  - RESTful API
  - Modules: balancer, pg_autoscaler, telemetry...

Process: ceph-mgr
Config:  /etc/ceph/ceph.conf
Data:    /var/lib/ceph/mgr/ceph-<hostname>/
Log:     /var/log/ceph/ceph-mgr.<hostname>.log

Ports:   8443 (dashboard HTTPS), 8080 (dashboard HTTP), 9283 (Prometheus)
```

### 4.4 MDS (ceph-mds) - chỉ cho CephFS

```
Vai trò:
  - Quản lý metadata của CephFS (directory, inode, permissions)
  - Không lưu file data (data vẫn qua OSD)

Process: ceph-mds
Ports:   6800+ (dynamic)
```

### 4.5 RGW (ceph-radosgw) - Object Storage Gateway

```
Vai trò:
  - S3-compatible API
  - Swift-compatible API
  - Thay thế OpenStack Swift

Process: ceph-radosgw (hoặc radosgw)
Ports:   7480 (HTTP), 443 (HTTPS)
```

### 4.6 cephadm (Orchestrator)

```
Vai trò:
  - Deploy và manage Ceph daemons bằng container (podman/docker)
  - Bootstrap cluster
  - Add/remove hosts, OSDs, services

Không phải daemon thường trực - chạy khi cần
Binary: /usr/sbin/cephadm
```

---

## 5. Luồng hoạt động chi tiết

### 5.1 Client Authentication (CephX)

```
1. Client có keyring: /etc/ceph/ceph.client.glance.keyring
   [client.glance]
       key = AQB...==

2. Client gửi auth request đến MON
3. MON verify key, cấp session ticket
4. Client dùng ticket để giao tiếp với OSD trực tiếp
   (không qua MON cho mỗi request)
```

### 5.2 Write Path (RBD)

```
Nova/Cinder muốn ghi 4MB vào volume:

1. librbd chia thành objects (mặc định 4MB/object)
2. Tính PG cho mỗi object: pg_id = hash(object_name) % pg_num
3. Hỏi MON: PG này map đến OSD nào? (OSD map)
4. Ghi trực tiếp đến Primary OSD
5. Primary OSD ghi local + replicate đến Replica OSD(s)
6. Khi tất cả replicas xác nhận → trả ACK về client

Write amplification = replication_size (mặc định 2x)
```

### 5.3 Recovery khi OSD fail

```
osd.1 bị down:

1. osd.0 và osd.2 detect heartbeat timeout → báo MON
2. MON đánh dấu osd.1 = down
3. Sau 10 phút → osd.1 = out
4. CRUSH recalculate: PGs của osd.1 → redistribute
5. Remaining OSDs bắt đầu replicate data để đủ replication count
6. Cluster ở trạng thái HEALTH_WARN trong quá trình recovery

Khi osd.1 up lại:
1. MON đánh dấu osd.1 = up, in
2. Backfill: sync data mới nhất về osd.1
3. Cluster → HEALTH_OK
```

---

## 6. Pool và Replication

### 6.1 Pool types

```
Replicated pool (mặc định):
  - Mỗi object được copy N lần (default: 2)
  - Usable capacity = total / replication_size
  - 2 OSD × 50GB, replication=2 → usable = 50GB

Erasure Coded pool:
  - Dùng thuật toán EC (k+m chunks)
  - Tiết kiệm space hơn nhưng CPU cao hơn
  - Không phù hợp cho RBD (block device)
```

### 6.2 Pool parameters quan trọng

```bash
# Xem thông tin pool
ceph osd pool get volumes all

# Các parameter quan trọng:
size = 2              # số replicas
min_size = 1          # min replicas để accept write
pg_num = 32           # số Placement Groups
pgp_num = 32          # số PG for placement (= pg_num)
crush_rule = replicated_rule
application = rbd
```

---

## 7. Cluster States

```
HEALTH_OK    → Mọi thứ bình thường
HEALTH_WARN  → Có vấn đề nhưng cluster vẫn hoạt động
               Ví dụ: OSD down, PG degraded, clock skew
HEALTH_ERR   → Nghiêm trọng, có thể mất data
               Ví dụ: quá nhiều OSD down, không đủ replicas

PG States:
  active+clean      → Bình thường
  active+degraded   → Thiếu replica (OSD down)
  active+recovering → Đang recovery
  active+backfilling→ Đang backfill
  stale             → PG không có primary OSD
  peering           → OSDs đang thương lượng về PG state
```

---

## 8. Monitoring commands

```bash
# Tổng quan cluster
ceph status
ceph health detail

# OSD
ceph osd tree
ceph osd stat
ceph osd df                    # disk usage per OSD
ceph osd perf                  # latency per OSD

# PG
ceph pg stat
ceph pg dump | head -20

# Pool
ceph df                        # usage per pool
ceph osd pool stats

# MON
ceph mon stat
ceph quorum_status

# MGR
ceph mgr stat
ceph mgr module ls

# Realtime
watch ceph status
ceph -w                        # event log realtime
```
