# Ceph Knowledge Base

Series tài liệu kiến thức chuyên sâu về Ceph, dành cho người mới bắt đầu đến nâng cao.

## Danh sách tài liệu

| File | Nội dung |
|---|---|
| [01-ceph-architecture.md](01-ceph-architecture.md) | Kiến trúc tổng quan: vật lý, logic, services, monitoring |
| [02-crush-and-data-placement.md](02-crush-and-data-placement.md) | CRUSH map, PG, cách data được phân phối |
| [03-bluestore-storage-engine.md](03-bluestore-storage-engine.md) | BlueStore internals, cache, compression, tuning |
| [04-cephx-authentication.md](04-cephx-authentication.md) | CephX auth, keyring, capabilities, libvirt secrets |
| [05-rbd-deep-dive.md](05-rbd-deep-dive.md) | RBD internals, snapshot, clone, mirroring, tuning |
| [06-troubleshooting.md](06-troubleshooting.md) | Debug, fix lỗi thường gặp, OpenStack integration issues |

## Lộ trình đọc

```
Mới bắt đầu:
  01 → 02 → 04 → 06

Muốn hiểu sâu storage:
  03 → 05

Đang gặp vấn đề:
  06 (troubleshooting)
```
