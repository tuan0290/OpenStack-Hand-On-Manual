# Placement - Deep Dive

## Placement là gì?

Placement là Resource Tracking Service - theo dõi **inventory** (tài nguyên có sẵn) và **allocation** (tài nguyên đã dùng) của các resource provider trong OpenStack.

Tách ra từ Nova thành service độc lập từ OpenStack Rocky (2018).

## Các khái niệm cốt lõi

### Resource Provider

Bất kỳ thực thể nào cung cấp tài nguyên:

```
Resource Provider Tree:
compute1 (root provider)
├── VCPU:        total=8, reserved=0, min_unit=1, max_unit=8, step_size=1, allocation_ratio=4.0
├── MEMORY_MB:   total=16384, reserved=512, min_unit=1, max_unit=15872, step_size=1, allocation_ratio=1.5
├── DISK_GB:     total=100, reserved=0, min_unit=1, max_unit=100, step_size=1, allocation_ratio=1.0
└── NUMA_TOPOLOGY (nested provider - nếu có NUMA)
    ├── NUMA_CELL:0
    │   ├── VCPU: 4
    │   └── MEMORY_MB: 8192
    └── NUMA_CELL:1
        ├── VCPU: 4
        └── MEMORY_MB: 8192
```

### Resource Class

Loại tài nguyên. Có sẵn (standard) và tùy chỉnh (custom):

**Standard resource classes:**

| Class | Mô tả |
|---|---|
| `VCPU` | Virtual CPU |
| `MEMORY_MB` | RAM (MB) |
| `DISK_GB` | Disk (GB) |
| `VGPU` | Virtual GPU |
| `NET_BW_EGR_KILOBIT_PER_SEC` | Network bandwidth egress |
| `NET_BW_IGR_KILOBIT_PER_SEC` | Network bandwidth ingress |
| `PCI_DEVICE` | PCI passthrough device |
| `SRIOV_NET_VF` | SR-IOV Virtual Function |

**Custom resource class** (prefix `CUSTOM_`):

```bash
# Tạo custom resource class
openstack resource class create CUSTOM_GPU_A100
```

### Inventory

Mô tả tài nguyên của 1 resource provider:

```
total         = tổng tài nguyên vật lý
reserved      = dành riêng cho host OS, không cấp cho VM
min_unit      = đơn vị tối thiểu có thể cấp
max_unit      = đơn vị tối đa có thể cấp trong 1 lần
step_size     = bước nhảy (phải là bội số)
allocation_ratio = hệ số overcommit
```

**Ví dụ VCPU với allocation_ratio=4.0:**
```
total=8, allocation_ratio=4.0
→ capacity = 8 * 4.0 = 32 VCPU có thể cấp
→ Có thể tạo 32 VM mỗi VM 1 VCPU (overcommit 4:1)
```

### Allocation

Ghi nhận tài nguyên đã được cấp cho 1 consumer (thường là VM):

```
Consumer: instance-uuid-abc123
Allocations:
  compute1: {VCPU: 2, MEMORY_MB: 2048, DISK_GB: 20}
```

### Trait

Đặc tính của resource provider (không phải số lượng):

```bash
# Xem traits của compute node
openstack resource provider trait list <provider-uuid>

# Ví dụ traits:
COMPUTE_NODE
HW_CPU_X86_AVX2
HW_CPU_X86_SSE4_2
STORAGE_DISK_SSD
COMPUTE_VOLUME_MULTI_ATTACH
```

Nova scheduler dùng traits để filter: "chỉ đặt VM trên node có SSD".

## Luồng Nova - Placement

```
1. nova-compute khởi động:
   → Resource Tracker báo cáo inventory lên Placement
   → Placement lưu: compute1 có 8 VCPU, 16GB RAM, 100GB disk

2. User tạo VM (flavor: 2 VCPU, 4GB RAM, 20GB disk):
   nova-api → nova-scheduler

3. nova-scheduler hỏi Placement:
   GET /allocation_candidates?resources=VCPU:2,MEMORY_MB:4096,DISK_GB:20
   → Placement trả về: [compute1, compute2] (đủ tài nguyên)

4. nova-scheduler chọn compute1 (theo filter/weight)

5. nova-conductor claim allocation:
   POST /allocations/{instance-uuid}
   Body: {compute1: {VCPU:2, MEMORY_MB:4096, DISK_GB:20}}
   → Placement ghi nhận allocation

6. nova-compute tạo VM

7. Khi xóa VM:
   nova-compute → DELETE /allocations/{instance-uuid}
   → Placement giải phóng tài nguyên
```

## Nested Resource Providers

Cho phép mô hình hóa tài nguyên phức tạp:

```
compute1 (root)
├── VCPU, MEMORY_MB, DISK_GB
├── pci_dev_0 (nested - GPU)
│   └── VGPU: 4
└── pci_dev_1 (nested - SR-IOV NIC)
    └── SRIOV_NET_VF: 8
```

## Debug và quản trị

```bash
source ~/admin-openrc

# Xem tất cả resource provider
openstack resource provider list

# Xem inventory của 1 provider
openstack resource provider inventory list <uuid>

# Xem allocation của 1 provider
openstack resource provider allocation list <uuid>

# Xem allocation của 1 instance
openstack resource provider allocation show <instance-uuid>

# Xem usage tổng
openstack resource provider usage show <uuid>

# Kiểm tra allocation candidates
openstack allocation candidate list \
  --resource VCPU=2 --resource MEMORY_MB=4096

# Kiểm tra upgrade
placement-status upgrade check

# Xem log
tail -f /var/log/apache2/placement-api.log
```

## Vấn đề thường gặp

**"No valid host was found"** - Nova không tìm được node phù hợp:

```bash
# Kiểm tra inventory có đủ không
openstack resource provider inventory list <compute-uuid>

# Kiểm tra allocation hiện tại
openstack resource provider allocation list <compute-uuid>

# Tính free resources
# free = (total - reserved) * allocation_ratio - used

# Nếu inventory không cập nhật → restart nova-compute
systemctl restart nova-compute
```
