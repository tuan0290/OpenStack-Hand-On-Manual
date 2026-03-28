# Cài đặt dịch vụ Networking (Neutron) với OVN

> Hướng dẫn này sử dụng **OVN (Open Virtual Network)** - cơ chế networking được khuyến nghị cho OpenStack Flamingo

## Mục lục

1. [Cài đặt trên node Controller](#1-cài-đặt-trên-node-controller)
2. [Cài đặt trên node Compute](#2-cài-đặt-trên-node-compute)
3. [Kiểm tra kết quả cài đặt](#3-kiểm-tra-kết-quả-cài-đặt)

---

## Lưu ý quan trọng về br-provider và netplan

> Đây là điểm dễ gây lỗi nhất khi cài OVN trên Ubuntu 24.04.

**Vấn đề:** OVS và netplan không thể cùng quản lý một interface/bridge.

- Nếu netplan tạo `br-provider` (Linux bridge) → OVS không thể gán `ens33` vào OVS bridge cùng tên → lỗi "Device or resource busy"
- Nếu OVS tạo `br-provider` trước → netplan không biết bridge này → IP không được gán

**Giải pháp đúng:**
- Netplan chỉ quản lý `ens37` và `ens38` (có IP tĩnh)
- `ens33` để trống trong netplan (`dhcp4: false`, không có IP)
- OVS tự tạo `br-provider`, gán `ens33` vào, sau đó dùng `ip` command gán IP cho `br-provider`
- Để persistent qua reboot, dùng script hoặc systemd service

---

## 1. Cài đặt trên node Controller

> Thực hiện trên node **controller**

### 1.1 Tạo database cho Neutron

```bash
mysql -u root -pWelcome123
```

```sql
CREATE DATABASE neutron;
CREATE USER 'neutron'@'localhost' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost';
CREATE USER 'neutron'@'%' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%';
FLUSH PRIVILEGES;
EXIT;
```

### 1.2 Tạo user, service và endpoint API

```bash
source ~/admin-openrc
```

```bash
openstack user create --domain default --password Welcome123 neutron
openstack role add --project service --user neutron admin
openstack service create --name neutron --description "OpenStack Networking" network
openstack endpoint create --region RegionOne network public http://controller:9696
openstack endpoint create --region RegionOne network internal http://controller:9696
openstack endpoint create --region RegionOne network admin http://controller:9696
```

### 1.3 Cài đặt OVN và Neutron

```bash
apt install -y neutron-server neutron-plugin-ml2 \
  ovn-central ovn-host openvswitch-switch \
  neutron-ovn-metadata-agent
```

> `ovn-central` chứa ovn-northd và OVN DB. `ovn-host` chứa ovn-controller cần thiết để controller làm gateway chassis.

### 1.4 Cấu hình netplan - chỉ quản lý ens37 và ens38

Sửa file `/etc/netplan/50-cloud-init.yaml`:

```yaml
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      dhcp6: false
    ens37:
      addresses:
        - 192.168.225.195/24
    ens38:
      addresses:
        - 192.168.147.195/24
```

```bash
chmod 600 /etc/netplan/50-cloud-init.yaml
netplan apply
```

### 1.5 Khởi động OVS và OVN Central

```bash
systemctl start openvswitch-switch
systemctl enable openvswitch-switch
systemctl start ovn-central
systemctl enable ovn-central
```

Mở TCP port 6640 cho OVSDB (cần thiết để nova-compute kết nối):

```bash
ovs-vsctl set-manager ptcp:6640:127.0.0.1
```

Cho phép kết nối từ xa đến OVN database:

```bash
ovn-nbctl set-connection ptcp:6641:192.168.225.195 -- \
  set connection . inactivity_probe=60000

ovn-sbctl set-connection ptcp:6642:192.168.225.195 -- \
  set connection . inactivity_probe=60000
```

### 1.6 Cấu hình OVS bridge cho provider network

Tạo bridge và gán `ens33` vào OVS:

```bash
ovs-vsctl add-br br-provider
ovs-vsctl add-port br-provider ens33
```

Gán IP cho `br-provider` và cấu hình routing:

```bash
ip addr add 192.168.182.195/24 dev br-provider
ip link set br-provider up
ip route add default via 192.168.182.2 dev br-provider
```

Kiểm tra kết nối:

```bash
ping -c 2 192.168.182.2
ping -c 2 8.8.8.8
```

Để IP và route tồn tại sau reboot, tạo systemd service:

```bash
cat > /etc/systemd/system/ovs-br-provider.service << 'EOF'
[Unit]
Description=OVS br-provider IP configuration
After=openvswitch-switch.service
Wants=openvswitch-switch.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  ovs-vsctl --may-exist add-br br-provider && \
  ovs-vsctl --may-exist add-port br-provider ens33 && \
  ip addr replace 192.168.182.195/24 dev br-provider && \
  ip link set br-provider up && \
  ip route replace default via 192.168.182.2 dev br-provider'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ovs-br-provider
```

### 1.7 Cấu hình OVS external-ids và khởi động ovn-controller

```bash
ovs-vsctl set open . external-ids:ovn-remote=tcp:192.168.225.195:6642
ovs-vsctl set open . external-ids:ovn-encap-type=geneve
ovs-vsctl set open . external-ids:ovn-encap-ip=192.168.147.195
ovs-vsctl set open . external-ids:ovn-bridge-mappings=provider:br-provider
ovs-vsctl set open . external-ids:ovn-cms-options=enable-chassis-as-gw
```

```bash
systemctl start ovn-controller
systemctl enable ovn-controller
```

### 1.8 Cấu hình Neutron Server

Sao lưu file cấu hình gốc:

```bash
cp /etc/neutron/neutron.conf /etc/neutron/neutron.conf.orig
```

Sửa file `/etc/neutron/neutron.conf`:

Trong section `[database]`:

```ini
[database]
connection = mysql+pymysql://neutron:Welcome123@controller/neutron
```

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
core_plugin = ml2
service_plugins = ovn-router
transport_url = rabbit://openstack:Welcome123@controller
auth_strategy = keystone
notify_nova_on_port_status_changes = true
notify_nova_on_port_data_changes = true
```

Trong section `[keystone_authtoken]`:

```ini
[keystone_authtoken]
www_authenticate_uri = http://controller:5000
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = neutron
password = Welcome123
```

Trong section `[nova]`:

```ini
[nova]
auth_url = http://controller:5000
auth_type = password
project_domain_name = Default
user_domain_name = Default
region_name = RegionOne
project_name = service
username = nova
password = Welcome123
```

Trong section `[oslo_concurrency]`:

```ini
[oslo_concurrency]
lock_path = /var/lib/neutron/tmp
```

### 1.9 Cấu hình ML2 Plugin cho OVN

Sao lưu file cấu hình gốc:

```bash
cp /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugins/ml2/ml2_conf.ini.orig
```

Sửa file `/etc/neutron/plugins/ml2/ml2_conf.ini`:

Trong section `[ml2]`:

```ini
[ml2]
mechanism_drivers = ovn
type_drivers = local,flat,vlan,geneve
tenant_network_types = geneve
extension_drivers = port_security
overlay_ip_version = 4
```

Trong section `[ml2_type_flat]`:

```ini
[ml2_type_flat]
flat_networks = provider
```

Trong section `[ml2_type_geneve]`:

```ini
[ml2_type_geneve]
vni_ranges = 1:65536
max_header_size = 38
```

Trong section `[securitygroup]`:

```ini
[securitygroup]
enable_security_group = true
```

Trong section `[ovn]`:

```ini
[ovn]
ovn_nb_connection = tcp:192.168.225.195:6641
ovn_sb_connection = tcp:192.168.225.195:6642
ovn_l3_scheduler = leastloaded
ovn_bridge_mappings = provider:br-provider
```

### 1.10 Cấu hình Metadata Agent

Sao lưu file cấu hình gốc:

```bash
cp /etc/neutron/neutron_ovn_metadata_agent.ini \
   /etc/neutron/neutron_ovn_metadata_agent.ini.orig
```

Sửa file `/etc/neutron/neutron_ovn_metadata_agent.ini`:

```ini
[DEFAULT]
nova_metadata_host = controller
metadata_proxy_shared_secret = Welcome123

[ovn]
ovn_sb_connection = tcp:192.168.225.195:6642
```

### 1.11 Cấu hình Nova sử dụng Neutron

Sửa file `/etc/nova/nova.conf`, thêm section `[neutron]`:

```ini
[neutron]
auth_url = http://controller:5000
auth_type = password
project_domain_name = Default
user_domain_name = Default
region_name = RegionOne
project_name = service
username = neutron
password = Welcome123
service_metadata_proxy = true
metadata_proxy_shared_secret = Welcome123
```

### 1.12 Đồng bộ database cho Neutron

```bash
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
```

### 1.13 Khởi động các dịch vụ

> Trên Ubuntu 24.04, neutron-server chạy qua Apache. Các service neutron được tách riêng.

```bash
systemctl restart apache2
systemctl restart neutron-rpc-server neutron-periodic-workers neutron-ovn-metadata-agent
systemctl enable neutron-rpc-server neutron-periodic-workers neutron-ovn-metadata-agent
```

---

## 2. Cài đặt trên node Compute

> Thực hiện trên node **compute1**

### 2.1 Cài đặt OVN

```bash
apt install -y ovn-host openvswitch-switch neutron-ovn-metadata-agent
```

### 2.2 Khởi động OVS

```bash
systemctl start openvswitch-switch
systemctl enable openvswitch-switch
```

Mở TCP port 6640 cho OVSDB (nova-compute cần kết nối vào đây để plug VIF):

```bash
ovs-vsctl set-manager ptcp:6640:127.0.0.1
```

Kiểm tra port đã listen:

```bash
ss -tlnp | grep 6640
```

Kết quả mong đợi:

```
LISTEN  0  10  127.0.0.1:6640  0.0.0.0:*  users:(("ovsdb-server",...))
```

### 2.3 Cấu hình netplan - chỉ quản lý ens37 và ens38

Sửa file `/etc/netplan/50-cloud-init.yaml`:

```yaml
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      dhcp6: false
    ens37:
      addresses:
        - 192.168.225.196/24
    ens38:
      addresses:
        - 192.168.147.196/24
```

```bash
chmod 600 /etc/netplan/50-cloud-init.yaml
netplan apply
```

### 2.4 Cấu hình OVS bridge cho provider network

```bash
# Xóa bridge cũ nếu có xung đột
ovs-vsctl del-br br-provider 2>/dev/null
ip link delete br-provider 2>/dev/null

# Tạo bridge và gán ens33
ovs-vsctl add-br br-provider
ovs-vsctl add-port br-provider ens33

# Gán IP và routing
ip addr add 192.168.182.196/24 dev br-provider
ip link set br-provider up
ip route add default via 192.168.182.2 dev br-provider
```

Kiểm tra:

```bash
ovs-vsctl show | grep -i error
ping -c 2 192.168.182.2
```

Tạo systemd service để persistent qua reboot:

```bash
cat > /etc/systemd/system/ovs-br-provider.service << 'EOF'
[Unit]
Description=OVS br-provider IP configuration
After=openvswitch-switch.service
Wants=openvswitch-switch.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  ovs-vsctl --may-exist add-br br-provider && \
  ovs-vsctl --may-exist add-port br-provider ens33 && \
  ip addr replace 192.168.182.196/24 dev br-provider && \
  ip link set br-provider up && \
  ip route replace default via 192.168.182.2 dev br-provider'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ovs-br-provider
```

### 2.5 Cấu hình OVS kết nối về Controller

```bash
ovs-vsctl set open . external-ids:ovn-remote=tcp:192.168.225.195:6642
ovs-vsctl set open . external-ids:ovn-encap-type=geneve
ovs-vsctl set open . external-ids:ovn-encap-ip=192.168.147.196
ovs-vsctl set open . external-ids:ovn-bridge-mappings=provider:br-provider
```

### 2.6 Cấu hình Neutron

Sửa file `/etc/neutron/neutron.conf`:

Trong section `[database]`:

```ini
[database]
# connection =
```

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller
auth_strategy = keystone
```

Trong section `[keystone_authtoken]`:

```ini
[keystone_authtoken]
www_authenticate_uri = http://controller:5000
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = neutron
password = Welcome123
```

Trong section `[oslo_concurrency]`:

```ini
[oslo_concurrency]
lock_path = /var/lib/neutron/tmp
```

### 2.7 Cấu hình Metadata Agent

Sửa file `/etc/neutron/neutron_ovn_metadata_agent.ini`:

```ini
[DEFAULT]
nova_metadata_host = controller
metadata_proxy_shared_secret = Welcome123

[ovn]
ovn_sb_connection = tcp:192.168.225.195:6642
```

### 2.8 Cấu hình Nova sử dụng Neutron

Sửa file `/etc/nova/nova.conf`, thêm section `[neutron]`:

```ini
[neutron]
auth_url = http://controller:5000
auth_type = password
project_domain_name = Default
user_domain_name = Default
region_name = RegionOne
project_name = service
username = neutron
password = Welcome123
```

### 2.9 Khởi động dịch vụ

```bash
systemctl start ovn-controller
systemctl enable ovn-controller
systemctl restart nova-compute
systemctl restart neutron-ovn-metadata-agent
systemctl enable neutron-ovn-metadata-agent
```

---

## 3. Kiểm tra kết quả cài đặt

> Thực hiện trên node **controller**

```bash
source ~/admin-openrc
```

Kiểm tra OVN chassis:

```bash
ovn-sbctl show
```

Kiểm tra Neutron agent - phải có đủ 3 agent:

```bash
openstack network agent list
```

Kết quả mong đợi:

```
+------+------------------------------+------------+-------+-------+----------------------------+
| ID   | Agent Type                   | Host       | Alive | State | Binary                     |
+------+------------------------------+------------+-------+-------+----------------------------+
| ...  | OVN Controller Gateway agent | controller | :-)   | UP    | ovn-controller             |
| ...  | OVN Controller agent         | compute1   | :-)   | UP    | ovn-controller             |
| ...  | OVN Metadata agent           | compute1   | :-)   | UP    | neutron-ovn-metadata-agent |
+------+------------------------------+------------+-------+-------+----------------------------+
```

> Controller phải là **OVN Controller Gateway agent** (có `enable-chassis-as-gw`), compute1 là **OVN Controller agent** thông thường.

---

Trước: [05-nova.md](05-nova.md) | Tiếp theo: [07-launch-instance.md](07-launch-instance.md)

---

## Hỏi & Đáp

### Tại sao cần `ovs-vsctl set-manager ptcp:6640:127.0.0.1`?

Đây là vấn đề thực tế gặp phải khi cài OVN trên Ubuntu 24.04.

`nova-compute` dùng thư viện `vif_plug_ovs` để gắn network interface vào VM. Thư viện này kết nối đến OVSDB qua TCP port 6640 để thực hiện các thao tác OVS.

Mặc định `ovsdb-server` chỉ listen trên Unix socket (`/var/run/openvswitch/db.sock`), không mở TCP port. Kết quả là `vif_plug_ovs` không kết nối được và VM bị lỗi:

```
Exception: Could not retrieve schema from tcp:127.0.0.1:6640
```

Lệnh `ovs-vsctl set-manager ptcp:6640:127.0.0.1` yêu cầu ovsdb-server mở thêm TCP port 6640 trên localhost. Lệnh này persistent qua reboot vì được lưu vào OVS database.

Cần chạy trên **cả controller và compute node**.

---

### Tại sao không dùng netplan bridge mà phải dùng OVS bridge?

Đây là vấn đề thực tế gặp phải khi cài đặt. Có 2 loại bridge:

```
Linux bridge (netplan quản lý):        OVS bridge (OVN/OVS quản lý):
─────────────────────────────          ──────────────────────────────
Kernel tạo và quản lý                  OVS daemon tạo và quản lý
Netplan biết và cấu hình được          Netplan không biết bridge này
Dùng cho VM thông thường               Dùng cho OVN/OVS networking
```

Khi cả 2 cùng tạo bridge tên `br-provider`:
- Netplan tạo Linux bridge `br-provider` → gán `ens33` vào Linux bridge
- OVS cố gán `ens33` vào OVS bridge → lỗi "Device or resource busy"
  vì `ens33` đã là slave của Linux bridge

**Giải pháp:** Để netplan quản lý `ens37` và `ens38` (có IP tĩnh cần persistent). Để OVS tự quản lý `br-provider` và `ens33`. Dùng systemd service để gán IP cho `br-provider` sau mỗi lần reboot.

---

### Tại sao controller cần chạy ovn-controller?

Controller cần `ovn-controller` để đóng vai trò **Gateway Chassis** - node chịu trách nhiệm định tuyến traffic giữa self-service network và provider network (internet).

```
VM (self-service) → OVN router → Gateway Chassis (controller) → br-provider → internet
```

Nếu không có Gateway Chassis, VM có thể giao tiếp nội bộ nhưng không ra được internet và không có floating IP.

Dấu hiệu nhận biết: agent type là `OVN Controller Gateway agent` thay vì `OVN Controller agent` thông thường.

---

### Linuxbridge vs OVS vs OVN - khi nào dùng cái nào?

```
Linuxbridge          OVS                  OVN
────────────         ────────────         ────────────────────
Đơn giản             Phức tạp hơn         Phức tạp nhất
Dễ debug             Nhiều tính năng      Nhiều tính năng nhất
Lab nhỏ              Production           Production hiện đại
VXLAN, VLAN          VXLAN, GRE, Geneve   Geneve, VXLAN
Không cần thêm gì    Cần OVS package      Cần OVN + OVS package
```

OVN là evolution của OVS, được khuyến nghị cho deployment mới từ OpenStack Ussuri trở đi. OVN xử lý L2/L3 trực tiếp trong kernel thay vì dùng Linux network namespace như linuxbridge/OVS truyền thống, giúp hiệu năng tốt hơn và scale dễ hơn.

---

### Mô hình quản lý mạng OVN/OVS với Nova và Neutron

```
═══════════════════════════════════════════════════════════════════════
                         CONTROLLER NODE
═══════════════════════════════════════════════════════════════════════

  neutron-server
       │
       │ ML2/OVN driver
       ▼
  OVN Northbound DB (port 6641)    ← lưu logical network (intent)
       │                              network, subnet, router, port...
       │ ovn-northd
       ▼
  OVN Southbound DB (port 6642)    ← lưu physical binding
       │                              chassis, datapath, flows...
       │
  ovn-controller (Gateway Chassis) ← đọc SB DB, xử lý L3 routing
       │                              floating IP, SNAT ra internet
       │
  ovsdb-server (port 6640 local)   ← nova-compute kết nối để plug VIF
       │
  ┌────┴────────────────────────┐
  │         br-int              │  ← OVS integration bridge
  └────┬────────────────────────┘
       │
  ┌────┴────────────────────────┐
  │        br-provider          │  ← OVS external bridge
  │  (ens33 gán vào OVS)        │    IP: 192.168.182.195
  └────┬────────────────────────┘
       │
     ens33 (VMnet8/NAT - internet)


═══════════════════════════════════════════════════════════════════════
                          COMPUTE NODE
═══════════════════════════════════════════════════════════════════════

  nova-compute
       │ tạo VM → libvirt/KVM
       │
       │ plug VIF → kết nối tcp:127.0.0.1:6640
       ▼
  ovsdb-server (port 6640 local)   ← PHẢI mở TCP, không chỉ Unix socket
       │                              ovs-vsctl set-manager ptcp:6640:127.0.0.1
       ▼
  ┌─────────────────────────────┐
  │  VM1  │  VM2  │  VM3  │... │
  └──┬────┴──┬────┴──┬──────────┘
     │       │       │  tap interface (mỗi VM 1 tap)
     ▼       ▼       ▼
  ┌────────────────────────────┐
  │          br-int            │  ← OVS integration bridge
  │   (ovn-controller quản lý) │     apply security group rules
  │                            │     apply L2/L3 forwarding rules
  └────────────┬───────────────┘
               │
        ┌──────┴──────┐
        │             │
  ┌─────┴──────┐  ┌───┴────────────┐
  │ br-provider│  │  tunnel port   │
  │ (ens33)    │  │  (ens38/Geneve)│
  │ IP:.182.196│  │  IP:.147.196   │
  └─────┬──────┘  └───┬────────────┘
        │             │
      ens33          ens38
   (VMnet8/NAT)  (VMnet2/Tunnel)
   Provider net   Overlay traffic
                  đến compute khác


═══════════════════════════════════════════════════════════════════════
                    LUỒNG KẾT NỐI GIỮA 2 NODE
═══════════════════════════════════════════════════════════════════════

Controller                                    Compute1
──────────                                    ────────
OVN NB/SB DB (6641/6642)
    │
    │ ovn-controller đọc SB DB
    │ sync flows xuống br-int
    ▼
ovn-controller ←──── TCP 6642 ──────────→ ovn-controller
(Gateway Chassis)                              │
    │                                          │ apply flows vào br-int
    │                                          ▼
    │                                     br-int (compute)
    │                                          │
    │◄──── Geneve tunnel (ens38) ──────────────┤
    │      192.168.147.195              192.168.147.196
    │
    │  Floating IP / SNAT traffic:
    │  VM → Geneve → controller → br-provider → internet
    │
ovsdb-server                          ovsdb-server
(tcp:127.0.0.1:6640)                  (tcp:127.0.0.1:6640)
    ↑                                      ↑
nova-compute                          nova-compute
plug VIF khi tạo VM                   plug VIF khi tạo VM


═══════════════════════════════════════════════════════════════════════
                    VAI TRÒ TỪNG THÀNH PHẦN
═══════════════════════════════════════════════════════════════════════

neutron-server    → nhận API request, ghi vào OVN NB DB
ovn-northd        → dịch NB DB → SB DB (logical → physical)
ovn-controller    → chạy trên MỌI node, đọc SB DB, push flows vào OVS
                    controller: Gateway Chassis (L3, floating IP, SNAT)
                    compute:    L2 forwarding, security group
ovsdb-server      → database của OVS, PHẢI mở TCP 6640 cho nova-compute
br-int            → OVS bridge nội bộ, nơi VM kết nối vào
br-provider       → OVS bridge kết nối ra physical network
Geneve tunnel     → đường hầm giữa các node (qua ens38)
```

---

### SR-IOV là gì và khi nào dùng?

SR-IOV (Single Root I/O Virtualization) cho phép VM kết nối thẳng vào card mạng vật lý, bypass toàn bộ OVS/OVN stack.

```
Virtio (thông thường):
VM → tap interface → br-int (OVS) → physical NIC
     software path, có overhead của kernel networking

SR-IOV:
VM → Virtual Function (VF) → physical NIC
     hardware path, bypass kernel → latency thấp, throughput cao
```

**Yêu cầu:**
- NIC vật lý hỗ trợ SR-IOV: Intel X710, X550, Mellanox ConnectX-4/5/6...
- CPU/BIOS enable VT-d (Intel) hoặc AMD-Vi
- Kernel enable IOMMU: thêm `intel_iommu=on` vào GRUB
- Không dùng được trong VMware (môi trường ảo hóa)

**Use case thực tế:**
- NFV, High-frequency trading, Database latency thấp, HPC, 5G core

---

### Mô hình SR-IOV theo kiến trúc Controller - Compute

```
═══════════════════════════════════════════════════════════════════════
                          COMPUTE NODE (SR-IOV hybrid)
═══════════════════════════════════════════════════════════════════════

  nova-compute
       │
       ├── VM-A (virtio)              ├── VM-B (SR-IOV)
       │ tap                          │ VF0
       ▼                              ▼
  ┌──────────────────────┐    ┌──────────────────────────────────┐
  │       br-int         │    │     Physical NIC (SR-IOV)        │
  │  (OVN flows)         │    │  PF → VF0 ←── VM-B              │
  └──────────┬───────────┘    │       VF1, VF2 (available)      │
             │                └────────────┬─────────────────────┘
      ┌──────┴──────┐                      │
  ┌───┴────────┐ ┌──┴──────┐               │
  │ br-provider│ │ tunnel  │               │
  │  (ens33)   │ │ (ens38) │               │
  └─────┬──────┘ └────┬────┘               │
        └─────────────┴────────────────────┘
                         │
                 Physical Switch → INTERNET
```

---

### SR-IOV VM giao tiếp nội bộ với VM khác như thế nào?

```
Virtio ↔ Virtio (cùng compute):   VM-A → br-int → OVN → br-int → VM-C
Virtio ↔ Virtio (khác compute):   VM-A → br-int → Geneve(ens38) → br-int → VM-C
SR-IOV ↔ SR-IOV:                  VM-B → VF0 → Physical Switch → VF1 → VM-D
Virtio ↔ SR-IOV (hairpin):        VM-A → br-int → br-provider → Switch → VF0 → VM-B
                                   ⚠ Phải ra physical switch dù cùng host
```
