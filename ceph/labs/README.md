# Ceph Storage Administrator Labs

Series lab thực hành từ cơ bản đến nâng cao để trở thành Ceph Storage Administrator.

## Lộ trình học

```
Level 1 - Fundamentals
  Lab 01: Khám phá cluster - status, health, topology
  Lab 02: Pool management - tạo, cấu hình, xóa pool
  Lab 03: RBD - tạo, mount, snapshot, clone block device

Level 2 - Operations
  Lab 04: OSD management - add, remove, reweight OSD
  Lab 05: CRUSH map - hiểu và tùy chỉnh data placement
  Lab 06: Monitoring - dashboard, Prometheus, alerts

Level 3 - Advanced
  Lab 07: Failure simulation - OSD down, recovery, backfill
  Lab 08: Performance tuning - cache, pg_autoscaler, benchmarks
  Lab 09: Snapshot & backup - RBD snapshot, export, import
  Lab 10: OpenStack integration - Glance, Cinder, Nova với Ceph
```

## Yêu cầu

- Ceph cluster đang chạy (theo `01-ceph-cluster.md`)
- SSH access vào ceph-mon1 từ bastion
- `ceph-common` đã cài trên ceph-mon1
