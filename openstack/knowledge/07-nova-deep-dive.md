# Nova - Deep Dive

## Nova là gì?

Nova là Compute Service của OpenStack - quản lý toàn bộ vòng đời của VM: tạo, xóa, resize, migrate, snapshot...

## Kiến trúc các thành phần

```
                    User / CLI / Horizon
                           │ REST API
                           ▼
                    nova-api (Apache/WSGI)
                    nova-api-metadata
                           │ oslo.messaging (RabbitMQ)
              ┌────────────┼────────────┐
              ▼            ▼            ▼
       nova-scheduler  nova-conductor  nova-novncproxy
              │            │                │
              │            │ DB access      │ WebSocket
              │            ▼                ▼
              │         MariaDB          Browser
              │
              │ oslo.messaging
              ▼
       nova-compute (compute node)
              │
              ▼
         libvirt/KVM
```

### nova-api

- Nhận HTTP request từ user
- Validate token với Keystone
- Validate request parameters
- Đẩy job vào RabbitMQ queue
- Trên Ubuntu 24.04: chạy qua Apache WSGI (không có systemd service riêng)

### nova-scheduler

- Nhận "create instance" request từ queue
- Hỏi Placement: node nào còn đủ tài nguyên
- Áp dụng **filters** để loại bỏ node không phù hợp
- Áp dụng **weights** để chọn node tốt nhất
- Gửi request đến nova-conductor

**Các filter phổ biến:**

| Filter | Mô tả |
|---|---|
| `ComputeFilter` | Node phải đang up |
| `RamFilter` | Đủ RAM (theo allocation_ratio) |
| `DiskFilter` | Đủ disk |
| `CoreFilter` | Đủ VCPU |
| `AvailabilityZoneFilter` | Đúng AZ |
| `ComputeCapabilitiesFilter` | Match extra specs của flavor |
| `ImagePropertiesFilter` | Match properties của image |
| `SameHostFilter` | Cùng host với instance khác |
| `DifferentHostFilter` | Khác host với instance khác |

### nova-conductor

- Trung gian giữa nova-compute và database
- nova-compute **không** được phép truy cập DB trực tiếp
- Lý do bảo mật: nếu compute node bị compromise, attacker không có DB credentials
- Xử lý các tác vụ phức tạp: live migration, resize

### nova-compute

- Chạy trên mỗi compute node
- Giao tiếp với hypervisor qua **libvirt** driver
- Báo cáo tài nguyên lên Placement (resource tracker)
- Quản lý vòng đời VM: spawn, reboot, terminate, resize

**Hypervisor drivers:**

| Driver | Hypervisor |
|---|---|
| `libvirt.LibvirtDriver` | KVM, QEMU, LXC (mặc định) |
| `vmwareapi.VMwareVCDriver` | VMware vCenter |
| `ironic.IronicDriver` | Bare metal (Ironic) |
| `zvm.ZVMDriver` | IBM z/VM |

### nova-novncproxy

- Web proxy cho VNC console
- User mở browser → novncproxy (port 6080) → nova-compute → VM VNC
- Dùng WebSocket protocol

## Cell v2

Từ OpenStack Queens, cell v2 là bắt buộc:

```
nova-api (global)          ← xử lý API request
nova-scheduler (global)    ← chọn compute node
        │
        ├── cell0 (đặc biệt)
        │   └── DB: nova_cell0
        │       Lưu instance bị lỗi scheduling
        │
        └── cell1 (thông thường)
            ├── DB: nova (nova_cell1)
            ├── RabbitMQ: queue riêng
            └── compute1, compute2, ...
```

**Tại sao cần cell0?**

Khi nova-scheduler không tìm được host phù hợp, instance vẫn cần được lưu vào DB với trạng thái ERROR. Cell0 là nơi lưu các instance này - nó không có compute node, chỉ có DB.

## Vòng đời Instance

```
QUEUED → SCHEDULING → BUILDING → SPAWNING → ACTIVE
                                              │
                              ┌───────────────┼───────────────┐
                              ▼               ▼               ▼
                           PAUSED         STOPPED         SUSPENDED
                              │               │               │
                              └───────────────┴───────────────┘
                                              │
                                           DELETED
```

**Các trạng thái task:**

```
scheduling    → đang tìm host
block_device_mapping → đang chuẩn bị volume
networking    → đang tạo network port
spawning      → đang tạo VM
rebooting     → đang reboot
resize_prep   → đang chuẩn bị resize
migrating     → đang migrate
deleting      → đang xóa
```

## Service User Token

Từ Flamingo, Nova dùng service user token để gọi các service khác:

```ini
[service_user]
send_service_user_token = true
auth_url = http://controller:5000/
auth_type = password
username = nova
password = Welcome123
```

Khi Nova gọi Neutron để tạo port, nó gửi cả user token lẫn service token. Neutron có thể verify cả 2 để tăng bảo mật.

## VNC Console

```
Browser → novncproxy:6080 → nova-compute:5900 (VNC port của VM)

Cấu hình trên compute node:
[vnc]
server_listen = 0.0.0.0          ← VNC listen trên tất cả interface
server_proxyclient_address = $my_ip  ← IP mà novncproxy kết nối vào
novncproxy_base_url = http://controller:6080/vnc_auto.html
```

## Debug

```bash
# Xem service status
openstack compute service list

# Xem hypervisor
openstack hypervisor list
openstack hypervisor show compute1

# Xem instance detail
openstack server show <id>
openstack server show <id> -f value -c fault

# Xem console log
openstack console log show <id>

# Xem VNC URL
openstack console url show <id>

# Log files
tail -f /var/log/nova/nova-scheduler.log
tail -f /var/log/nova/nova-conductor.log
tail -f /var/log/nova/nova-compute.log  # trên compute node

# nova-manage
nova-manage cell_v2 list_cells
nova-manage cell_v2 discover_hosts --verbose
nova-status upgrade check
```

## Scheduler Filters và Weights

```bash
# Xem cấu hình scheduler hiện tại
grep -i filter /etc/nova/nova.conf

# Cấu hình custom filter
[filter_scheduler]
enabled_filters = ComputeFilter,RamFilter,DiskFilter,CoreFilter,AvailabilityZoneFilter
weight_classes = nova.scheduler.weights.ram.RAMWeigher
ram_weight_multiplier = 1.0  # dương = ưu tiên node nhiều RAM hơn
                              # âm = ưu tiên node ít RAM hơn (pack instances)
```

---

## Lab: Quan sát Nova hoạt động thực tế

### 1. Theo dõi luồng tạo instance theo thời gian thực

Mở 3 terminal song song:

**Terminal 1 - theo dõi nova-scheduler:**
```bash
tail -f /var/log/nova/nova-scheduler.log | grep -v "^$"
```

**Terminal 2 - theo dõi nova-conductor:**
```bash
tail -f /var/log/nova/nova-conductor.log | grep -v "^$"
```

**Terminal 3 - theo dõi nova-compute (trên compute1):**
```bash
tail -f /var/log/nova/nova-compute.log | grep -v "^$"
```

**Terminal 4 - tạo instance và watch status:**
```bash
source ~/demo-openrc
NET_ID=$(openstack network list --name selfservice-net -f value -c ID)

openstack server create \
  --flavor m1.tiny \
  --image cirros \
  --nic net-id=$NET_ID \
  --security-group my-sg \
  --key-name demo-key \
  lab-test-vm

# Watch trạng thái thay đổi
watch -n 1 openstack server show lab-test-vm -f value -c status -c OS-EXT-STS:task_state
```

**Quan sát:** Bạn sẽ thấy log xuất hiện theo thứ tự:
1. `nova-scheduler.log`: chọn compute node
2. `nova-conductor.log`: claim allocation, chuẩn bị build
3. `nova-compute.log`: download image, tạo VM

---

### 2. Xem chi tiết quá trình scheduling

```bash
source ~/admin-openrc

# Xem instance đang ở đâu
openstack server show lab-test-vm -f value -c OS-EXT-SRV-ATTR:host
openstack server show lab-test-vm -f value -c OS-EXT-SRV-ATTR:hypervisor_hostname

# Xem tất cả thông tin scheduling
openstack server show lab-test-vm | grep -E "host|node|zone|status|task"
```

---

### 3. Quan sát Placement allocation

```bash
source ~/admin-openrc

# Lấy UUID của instance
INSTANCE_ID=$(openstack server show lab-test-vm -f value -c id)
echo "Instance UUID: $INSTANCE_ID"

# Xem allocation của instance này trong Placement
openstack resource provider allocation show $INSTANCE_ID
```

Kết quả mong đợi:
```
+--------------------------------------+------------+------+
| resource_provider                    | class      | used |
+--------------------------------------+------------+------+
| ecec5472-bad5-4303-9cf0-2b4ab9873bd5 | VCPU       |    1 |
| ecec5472-bad5-4303-9cf0-2b4ab9873bd5 | MEMORY_MB  |  512 |
| ecec5472-bad5-4303-9cf0-2b4ab9873bd5 | DISK_GB    |    1 |
+--------------------------------------+------------+------+
```

```bash
# Xem inventory còn lại của compute node
PROVIDER_UUID=$(openstack resource provider list -f value -c uuid)
openstack resource provider inventory list $PROVIDER_UUID

# Xem usage hiện tại
openstack resource provider usage show $PROVIDER_UUID
```

---

### 4. Debug instance bị lỗi

Tạo instance với flavor quá lớn để xem lỗi:

```bash
# Tạo flavor lớn hơn tài nguyên có sẵn
openstack flavor create --id 99 --vcpus 100 --ram 999999 --disk 999 m1.impossible

openstack server create \
  --flavor m1.impossible \
  --image cirros \
  --nic net-id=$NET_ID \
  fail-test-vm

# Xem lỗi
openstack server show fail-test-vm -f value -c status
openstack server show fail-test-vm -f value -c fault
```

Kết quả:
```
ERROR
{'code': 500, 'message': 'No valid host was found...'}
```

```bash
# Xem trong log scheduler
grep "No valid host" /var/log/nova/nova-scheduler.log | tail -5

# Xem instance bị lưu vào cell0
nova-manage cell_v2 list_cells
# cell0 chứa instance này

# Dọn dẹp
openstack server delete fail-test-vm
openstack flavor delete 99
```

---

### 5. Xem RabbitMQ queue khi tạo instance

```bash
# Trước khi tạo instance - xem queue hiện tại
rabbitmqctl list_queues name messages consumers | grep nova

# Tạo instance
openstack server create --flavor m1.tiny --image cirros \
  --nic net-id=$NET_ID queue-test-vm

# Ngay sau khi tạo (trong vài giây đầu) - xem message trong queue
rabbitmqctl list_queues name messages consumers | grep nova
# messages > 0 nghĩa là đang xử lý

# Sau khi ACTIVE - queue trống
rabbitmqctl list_queues name messages consumers | grep nova
```

---

### 6. Xem libvirt domain trên compute node

SSH vào compute1 và xem VM được tạo:

```bash
# Trên compute1
virsh list --all
```

Kết quả:
```
 Id   Name                                State
-------------------------------------------------
 1    instance-00000001                   running
```

```bash
# Xem chi tiết VM
virsh dominfo instance-00000001

# Xem XML config của VM
virsh dumpxml instance-00000001

# Xem disk của VM
virsh domblklist instance-00000001

# Xem network interface
virsh domiflist instance-00000001

# Xem console output
virsh console instance-00000001
# Ctrl+] để thoát
```

---

### 7. Xem file disk của instance

```bash
# Trên compute1
ls -lh /var/lib/nova/instances/

# Xem instance directory
INSTANCE_DIR=$(ls /var/lib/nova/instances/ | grep -v _base | head -1)
ls -lh /var/lib/nova/instances/$INSTANCE_DIR/

# Kết quả:
# console.log  ← console output
# disk         ← ephemeral disk (qcow2, backed by base image)
# disk.config  ← cloud-init config drive

# Xem base image cache
ls -lh /var/lib/nova/instances/_base/
# File ở đây là image gốc download từ Glance
# disk của VM là qcow2 overlay trên base image này

# Xem backing file
qemu-img info /var/lib/nova/instances/$INSTANCE_DIR/disk
```

Kết quả `qemu-img info`:
```
image: disk
file format: qcow2
virtual size: 1 GiB
disk size: 200 KiB
backing file: /var/lib/nova/instances/_base/abc123...  ← base image
```

---

### 8. Simulate live migration (nếu có 2 compute node)

```bash
# Trên controller
source ~/admin-openrc

# Xem instance đang ở compute nào
openstack server show lab-test-vm -f value -c OS-EXT-SRV-ATTR:host

# Live migrate sang compute khác
openstack server migrate --live-migration lab-test-vm

# Theo dõi
watch openstack server show lab-test-vm -f value -c status -c OS-EXT-STS:task_state

# Sau khi xong
openstack server show lab-test-vm -f value -c OS-EXT-SRV-ATTR:host
```

---

### 9. Xem nova-compute resource tracker

```bash
# Trên compute1 - xem resource tracker report
grep "resource_tracker" /var/log/nova/nova-compute.log | tail -10

# Xem periodic task chạy
grep "periodic" /var/log/nova/nova-compute.log | tail -10

# Force update resource (debug)
# nova-compute tự động update mỗi 60 giây
# Để force: restart nova-compute
systemctl restart nova-compute

# Sau đó xem Placement đã cập nhật chưa
openstack resource provider inventory list $PROVIDER_UUID
```

---

### 10. Dọn dẹp sau lab

```bash
source ~/demo-openrc
openstack server delete lab-test-vm queue-test-vm 2>/dev/null || true

source ~/admin-openrc
openstack flavor delete 99 2>/dev/null || true
```

---

## Troubleshooting: Các lỗi phổ biến với Nova

### Cách đọc lỗi nhanh

```bash
# Bước 1: xem fault message của instance
openstack server show <id> -f value -c fault

# Bước 2: xem log theo thứ tự
# scheduler → conductor → compute
grep <instance-uuid> /var/log/nova/nova-scheduler.log | tail -20
grep <instance-uuid> /var/log/nova/nova-conductor.log | tail -20
grep <instance-uuid> /var/log/nova/nova-compute.log | tail -20  # trên compute node
```

---

### Lỗi 1: "No valid host was found"

**Triệu chứng:**
```
{'code': 500, 'message': 'No valid host was found. There are not enough hosts available.'}
```

**Nguyên nhân và cách kiểm tra:**

```bash
# A. Compute service có up không?
openstack compute service list
# → State phải là "up", Status phải là "enabled"
# Fix: systemctl restart nova-compute (trên compute node)

# B. Tài nguyên có đủ không?
openstack resource provider inventory list <provider-uuid>
openstack resource provider usage show <provider-uuid>
# Tính: free = (total - reserved) * allocation_ratio - used
# Nếu free < flavor yêu cầu → không đủ tài nguyên

# C. Placement có nhận diện compute node không?
openstack resource provider list
# Nếu không có → nova-compute chưa register
# Fix: nova-manage cell_v2 discover_hosts --verbose

# D. Filter nào đang block?
grep "Filter.*rejected\|does not pass" /var/log/nova/nova-scheduler.log | tail -20

# E. Flavor có extra_specs không match?
openstack flavor show <flavor> | grep properties
# Nếu có extra_specs như hw:cpu_policy=dedicated → compute node phải có trait tương ứng
```

---

### Lỗi 2: "Exceeded maximum number of retries"

**Triệu chứng:**
```
Exceeded maximum number of retries. Exhausted all hosts available for retrying build failures for instance xxx
```

**Ý nghĩa:** Nova scheduler đã tìm được host, nhưng nova-compute thất bại nhiều lần và hết số lần retry.

```bash
# Xem lỗi thực sự trên compute node
grep <instance-uuid> /var/log/nova/nova-compute.log | grep -i "error\|exception\|fail"

# Các nguyên nhân phổ biến:
# 1. OVS/Neutron lỗi khi plug VIF
grep "plug\|vif\|network" /var/log/nova/nova-compute.log | tail -20

# 2. libvirt lỗi khi tạo VM
grep "libvirt\|spawn\|domain" /var/log/nova/nova-compute.log | tail -20

# 3. Image download lỗi
grep "image\|download\|glance" /var/log/nova/nova-compute.log | tail -20
```

---

### Lỗi 3: "Failed to plug VIF / Could not retrieve schema from tcp:127.0.0.1:6640"

**Triệu chứng:**
```
Exception: Could not retrieve schema from tcp:127.0.0.1:6640
Failed to plug VIF VIFOpenVSwitch(...)
```

**Nguyên nhân:** OVSDB không listen trên TCP port 6640.

```bash
# Kiểm tra
ss -tlnp | grep 6640

# Fix (trên compute node)
ovs-vsctl set-manager ptcp:6640:127.0.0.1

# Verify
ss -tlnp | grep 6640
# Phải thấy: LISTEN 0 10 127.0.0.1:6640
```

---

### Lỗi 4: "Failed to allocate the network(s)"

**Triệu chứng:**
```
Build of instance xxx aborted: Failed to allocate the network(s), not rescheduling.
```

**Nguyên nhân:** Neutron không tạo được port cho instance.

```bash
# Xem log Neutron
grep <instance-uuid> /var/log/neutron/neutron-rpc-server.log | tail -20

# Kiểm tra Neutron agent
openstack network agent list
# Tất cả phải Alive=True, State=UP

# Kiểm tra OVN chassis
ovn-sbctl show
# Phải thấy cả controller và compute1

# Kiểm tra quota network
openstack quota show --network <project-id>
# Nếu đã đạt quota ports → tăng quota hoặc xóa port cũ

# Xem port bị orphan (không gắn với instance nào)
openstack port list --device-owner compute:nova | grep -v ACTIVE
```

---

### Lỗi 5: "AMQP server on controller:5672 is unreachable"

**Triệu chứng:**
```
AMQP server on controller:5672 is unreachable: [Errno 111] ECONNREFUSED
```

**Nguyên nhân:** nova-compute không kết nối được RabbitMQ.

```bash
# Kiểm tra RabbitMQ đang chạy
systemctl status rabbitmq-server

# Kiểm tra port
ss -tlnp | grep 5672

# Kiểm tra từ compute node
nc -zv controller 5672

# Kiểm tra credentials
rabbitmqctl list_users
rabbitmqctl list_permissions

# Nếu password sai → đổi lại
rabbitmqctl change_password openstack Welcome123

# Kiểm tra transport_url trong nova.conf
grep transport_url /etc/nova/nova.conf
```

---

### Lỗi 6: Instance stuck ở trạng thái BUILD/SPAWNING

**Triệu chứng:** Instance không chuyển sang ACTIVE sau vài phút.

```bash
# Xem task state hiện tại
openstack server show <id> -f value -c OS-EXT-STS:task_state

# Xem log compute theo thời gian thực
tail -f /var/log/nova/nova-compute.log | grep <instance-uuid>

# Nếu stuck ở "spawning" → libvirt đang tạo VM
virsh list --all  # trên compute node
# Nếu VM đang running nhưng Nova không biết → nova-compute bị crash giữa chừng

# Reset instance về ERROR để tạo lại
openstack server reset-state --active <id>  # hoặc
openstack server reset-state <id>           # reset về ERROR

# Xóa và tạo lại
openstack server delete <id>
```

---

### Lỗi 7: nova-compute không start được

**Triệu chứng:**
```
systemctl status nova-compute → failed
```

```bash
# Xem log chi tiết
journalctl -u nova-compute -n 50 --no-pager
tail -50 /var/log/nova/nova-compute.log

# Nguyên nhân phổ biến:
# 1. Không kết nối được RabbitMQ → xem lỗi 5
# 2. Không kết nối được Keystone
curl http://controller:5000/v3

# 3. nova.conf có lỗi syntax
nova-compute --config-file /etc/nova/nova.conf --version
# Nếu báo lỗi parse → sửa nova.conf

# 4. libvirt không chạy
systemctl status libvirtd
systemctl start libvirtd

# 5. Không kết nối được Placement
curl -H "X-Auth-Token: $(openstack token issue -f value -c id)" \
  http://controller:8778/
```

---

### Lỗi 8: "No OVN chassis for host"

**Triệu chứng:**
```
Exceeded maximum number of retries... no OVN chassis for host compute1
```

**Nguyên nhân:** OVN không nhận diện được compute node.

```bash
# Kiểm tra chassis
ovn-sbctl show
# Phải thấy compute1 trong danh sách chassis

# Nếu không thấy → ovn-controller trên compute1 chưa kết nối
systemctl status ovn-controller  # trên compute1

# Kiểm tra kết nối đến OVN SB DB
ovs-vsctl get open . external-ids:ovn-remote
# Phải là: tcp:192.168.225.195:6642

# Kiểm tra port 6642 từ compute1
nc -zv 192.168.225.195 6642

# Restart ovn-controller
systemctl restart ovn-controller
```

---

### Quick Diagnostic Script

```bash
#!/bin/bash
# Chạy trên controller để kiểm tra nhanh trạng thái Nova

echo "=== Nova Services ==="
openstack compute service list

echo ""
echo "=== Hypervisors ==="
openstack hypervisor list

echo ""
echo "=== Resource Providers ==="
openstack resource provider list

echo ""
echo "=== Placement Usage ==="
for uuid in $(openstack resource provider list -f value -c uuid); do
  echo "Provider: $uuid"
  openstack resource provider usage show $uuid
done

echo ""
echo "=== Neutron Agents ==="
openstack network agent list

echo ""
echo "=== Recent ERROR instances ==="
openstack server list --all-projects --status ERROR
```
