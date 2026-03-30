# OpenStack Flamingo (2025.2) - Hướng dẫn cài đặt Lab

Tài liệu hướng dẫn cài đặt OpenStack **Flamingo (2025.2)** trên **Ubuntu 24.04 LTS** với mô hình 2 node chạy trên **VMware Workstation**.

---

## Môi trường Lab

**Core nodes:**

| Node | Role | vCPU | RAM | Disk |
|---|---|---|---|---|
| controller | Keystone, Glance, Placement, Nova API, Neutron, Horizon | 4 | 4 GB | 40 GB + 30 GB |
| compute1 | Nova Compute, OVN agent | 4 | 4 GB | 50 GB |

**Extended nodes (Cinder/Swift):**

| Node | Role | vCPU | RAM | Disk |
|---|---|---|---|---|
| storage1 | Cinder Volume (LVM) | 2 | 2 GB | 20 GB OS + 50 GB data |
| object1 | Swift Account/Container/Object | 2 | 2 GB | 20 GB OS + 20 GB + 20 GB data |
| object2 | Swift Account/Container/Object | 2 | 2 GB | 20 GB OS + 20 GB + 20 GB data |

**Network:**

| VMware | Interface | Dải IP | Vai trò |
|---|---|---|---|
| VMnet8 (NAT) | ens33 | 192.168.182.0/24 | Provider / Internet / Floating IP |
| VMnet1 (Host-only) | ens37 | 192.168.225.0/24 | Management |
| VMnet2 (Host-only) | ens38 | 192.168.147.0/24 | Tunnel (Geneve/OVN) - chỉ controller và compute1 |

**IP Summary:**

| Node | ens33 (NAT) | ens37 (Mgmt) | ens38 (Tunnel) |
|---|---|---|---|
| controller | 192.168.182.195 | 192.168.225.195 | 192.168.147.195 |
| compute1 | 192.168.182.196 | 192.168.225.196 | 192.168.147.196 |
| storage1 | 192.168.182.197 | 192.168.225.197 | - |
| object1 | 192.168.182.198 | 192.168.225.198 | - |
| object2 | 192.168.182.199 | 192.168.225.199 | - |

**Networking backend:** OVN (Open Virtual Network)

---

## Thứ tự cài đặt

```
OpenStack-Manual/
├── README.md
├── 01-environment-prepare.md   → Controller + Compute
├── 02-keystone.md              → Controller
├── 03-glance.md                → Controller
├── 04-placement.md             → Controller
├── 05-nova.md                  → Controller + Compute
├── 06-neutron.md               → Controller + Compute
├── 07-launch-instance.md       → Controller
├── 08-horizon.md               → Controller
├── 09-cinder.md                → Controller + Storage1
├── 10-swift.md                 → Controller + Object1 + Object2
├── 11-heat.md                  → Controller
├── 12-octavia.md               → Controller
├── 13-ceilometer.md            → Controller + Compute
├── scripts/
│   ├── controller-ovn-setup.sh
│   └── compute-ovn-setup.sh
└── knowledge/
    ├── README.md
    ├── 01-mariadb.md
    ├── 02-rabbitmq.md
    ├── 03-memcached.md
    ├── 04-keystone-deep-dive.md
    ├── 05-glance-deep-dive.md
    ├── 06-placement-deep-dive.md
    ├── 07-nova-deep-dive.md
    ├── 08-neutron-ovn-deep-dive.md
    └── 09-horizon-deep-dive.md
```

| File | Service | Node |
|---|---|---|
| [01-environment-prepare.md](01-environment-prepare.md) | Chuẩn bị môi trường, MariaDB, RabbitMQ, Memcached | Controller + Compute |
| [02-keystone.md](02-keystone.md) | Identity Service | Controller |
| [03-glance.md](03-glance.md) | Image Service | Controller |
| [04-placement.md](04-placement.md) | Placement API | Controller |
| [05-nova.md](05-nova.md) | Compute Service | Controller + Compute |
| [06-neutron.md](06-neutron.md) | Networking Service (OVN) | Controller + Compute |
| [07-launch-instance.md](07-launch-instance.md) | Tạo instance đầu tiên | Controller |
| [08-horizon.md](08-horizon.md) | Dashboard | Controller |
| [09-cinder.md](09-cinder.md) | Block Storage (LVM) | Controller + Storage1 |
| [10-swift.md](10-swift.md) | Object Storage | Controller + Object1 + Object2 |
| [11-heat.md](11-heat.md) | Orchestration | Controller |
| [12-octavia.md](12-octavia.md) | Load Balancer (LBaaS) | Controller |
| [13-ceilometer.md](13-ceilometer.md) | Telemetry (Ceilometer + Gnocchi + Aodh) | Controller + Compute |

---

## Lưu ý quan trọng

**Password thống nhất:** `Welcome123`

**Thứ tự cấu hình network trên `ens33`:**
- Bước 01→05: `ens33` có IP `192.168.182.x` để download packages
- Bước 06 (Neutron): `ens33` được chuyển vào OVS bridge `br-provider`, IP chuyển sang `br-provider`

**Các vấn đề thực tế đã gặp trên Ubuntu 24.04:**
- `nova-api` và `neutron-server` chạy qua Apache, không có systemd service riêng
- OVS và netplan không thể cùng quản lý `br-provider` → phải để OVS tự quản lý
- `ovsdb-server` phải mở TCP port 6640: `ovs-vsctl set-manager ptcp:6640:127.0.0.1`
- Controller cần `ovn-host` + `ovn-controller` để làm Gateway Chassis cho floating IP
- Keystone 28 không ship file wsgi script → phải tạo thủ công

---

## Truy cập sau khi cài xong

| Service | URL |
|---|---|
| Horizon Dashboard | `http://192.168.182.195/horizon` |
| Keystone API | `http://192.168.182.195:5000/v3` |
| noVNC Console | `http://192.168.182.195:6080` |

> Truy cập từ máy Windows host hoặc qua VPN đến host.
> Nếu truy cập qua VPN, cần forward port từ VMware NAT Settings.
