# Ceph Storage cho OpenStack

Tài liệu cài đặt và tích hợp **Ceph** làm storage backend cho OpenStack Flamingo (2025.2).

## Tại sao dùng Ceph thay LVM/Swift?

| | LVM (Cinder) | Swift | Ceph RBD |
|---|---|---|---|
| Block storage | ✓ | ✗ | ✓ |
| Object storage | ✗ | ✓ | ✓ (RGW) |
| Shared filesystem | ✗ | ✗ | ✓ (CephFS) |
| Live migration | ✗ | ✗ | ✓ |
| Snapshot | Limited | ✗ | ✓ |
| Scale out | Khó | ✓ | ✓ |
| HA | ✗ | ✓ | ✓ |

## Thứ tự cài đặt

| File | Nội dung |
|---|---|
| [01-ceph-cluster.md](01-ceph-cluster.md) | Cài đặt Ceph cluster (MON + OSD) bằng cephadm |
| [02-ceph-openstack-integration.md](02-ceph-openstack-integration.md) | Tích hợp Ceph với Glance, Cinder, Nova |

## IP Planning Ceph nodes

| Node | Management (ens37) | Cluster (ens38) | Vai trò |
|---|---|---|---|
| ceph-mon1 | 192.168.225.202 | 192.168.147.202 | MON + MGR |
| ceph-osd1 | 192.168.225.203 | 192.168.147.203 | OSD |
| ceph-osd2 | 192.168.225.204 | 192.168.147.204 | OSD |
