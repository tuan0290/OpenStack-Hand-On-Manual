# Neutron và OVN - Deep Dive

## Neutron là gì?

Neutron là Networking Service của OpenStack - cung cấp Network-as-a-Service. Neutron không tự implement networking mà dùng **plugin** để delegate xuống backend thực tế.

## Kiến trúc Neutron + OVN

```
User/Nova
    │ REST API (port 9696)
    ▼
neutron-server (Apache WSGI)
    │
    ├── ML2 Plugin (Modular Layer 2)
    │   └── OVN Mechanism Driver
    │       │
    │       │ ghi vào OVN NB DB
    │       ▼
    │   OVN Northbound DB (port 6641)   ← logical network intent
    │       │
    │       │ ovn-northd dịch
    │       ▼
    │   OVN Southbound DB (port 6642)   ← physical binding
    │       │
    │       │ ovn-controller đọc và sync
    │       ▼
    │   OVS flows trên mỗi node
    │
    └── neutron-rpc-server
        neutron-periodic-workers
```

## ML2 Plugin

ML2 (Modular Layer 2) là plugin framework cho phép kết hợp nhiều mechanism driver:

```ini
[ml2]
mechanism_drivers = ovn          # driver xử lý L2/L3
type_drivers = local,flat,vlan,geneve
tenant_network_types = geneve    # loại network mặc định cho tenant
extension_drivers = port_security
```

**Type drivers** - loại network:
- `flat`: không có VLAN tag, map thẳng vào physical network
- `vlan`: dùng VLAN tag (802.1Q)
- `geneve`: overlay tunnel (OVN dùng)
- `vxlan`: overlay tunnel (linuxbridge dùng)
- `gre`: overlay tunnel (ít dùng)

## OVN Architecture

### Northbound Database (NB DB)

Lưu **logical network** - ý định của người dùng:

```
Logical Switch (= Neutron Network)
├── Logical Switch Port (= Neutron Port)
│   ├── MAC address
│   ├── IP address
│   └── Security Group rules (ACL)
│
Logical Router (= Neutron Router)
├── Logical Router Port (= Router interface)
│   ├── Gateway port (external)
│   └── Internal port
│
NAT rules (= Floating IP, SNAT)
Load Balancer rules
```

### Southbound Database (SB DB)

Lưu **physical binding** - ánh xạ logical → physical:

```
Chassis (= compute/gateway node)
├── compute1: encap IP = 192.168.147.196, type = geneve
└── controller: encap IP = 192.168.147.195, type = geneve

Binding (= port → chassis mapping)
├── port-uuid-abc → compute1
└── port-uuid-def → compute1

Datapath (= forwarding table)
└── OVN flows được compile từ NB DB
```

### ovn-northd

Daemon chạy trên controller, dịch NB DB → SB DB:

```
NB DB: "Logical Switch ls1 có port p1 (MAC: fa:16:3e:xx, IP: 192.168.100.5)"
                    │
                    │ ovn-northd compile
                    ▼
SB DB: "Datapath flows: nếu packet đến MAC fa:16:3e:xx → forward đến chassis compute1"
```

### ovn-controller

Chạy trên **mỗi node** (controller và compute):

```
1. Kết nối đến SB DB (port 6642)
2. Đọc flows liên quan đến node này
3. Push flows vào OVS (br-int)
4. Báo cáo chassis info lên SB DB
```

## OVS Bridge Architecture

```
COMPUTE NODE:
                    VM1        VM2
                     │          │
                  tap port   tap port
                     │          │
              ┌──────┴──────────┴──────┐
              │         br-int         │  ← OVN managed
              │   (integration bridge) │
              └──────────┬─────────────┘
                         │
              ┌──────────┴─────────────┐
              │                        │
    ┌─────────┴──────┐    ┌────────────┴───────┐
    │   br-provider  │    │   tunnel port       │
    │   (ens33)      │    │   (Geneve/ens38)    │
    └────────────────┘    └────────────────────┘
           │                        │
      Provider network         Tunnel network
      (internet/floating IP)   (VM-to-VM traffic)
```

**br-int**: OVS bridge nội bộ, nơi tất cả VM kết nối vào. OVN push flows vào đây.

**br-provider**: OVS bridge kết nối ra physical network. Map với `provider` physical network.

**Tunnel port**: Geneve tunnel tự động tạo bởi ovn-controller khi cần giao tiếp với node khác.

## Gateway Chassis

Controller node được đánh dấu là Gateway Chassis:

```bash
ovs-vsctl set open . external-ids:ovn-cms-options=enable-chassis-as-gw
```

Gateway Chassis chịu trách nhiệm:
- **SNAT**: VM private IP → router external IP khi ra internet
- **Floating IP**: DNAT external IP → VM private IP
- **North-South routing**: traffic giữa tenant network và provider network

```
VM (192.168.100.5) → ping 8.8.8.8

Flow:
compute1: VM → br-int → Geneve tunnel → controller
controller: br-int → OVN router → SNAT (192.168.182.103) → br-provider → internet
```

## Self-service Network Flow

```
Tạo VM với floating IP:

1. Tạo provider network (admin):
   openstack network create --external --provider-network-type flat provider-net

2. Tạo self-service network (user):
   openstack network create selfservice-net
   openstack subnet create --subnet-range 192.168.100.0/24 selfservice-subnet

3. Tạo router:
   openstack router create router1
   openstack router add subnet router1 selfservice-subnet
   openstack router set router1 --external-gateway provider-net
   → OVN tạo: Logical Router + NAT rule (SNAT)

4. Tạo VM:
   → OVN tạo: Logical Switch Port, binding đến compute1

5. Gán floating IP:
   openstack floating ip create provider-net
   openstack server add floating ip vm1 192.168.182.105
   → OVN tạo: DNAT rule (192.168.182.105 → 192.168.100.5)
```

## Security Groups

OVN implement security group bằng **ACL** (Access Control List) trong NB DB:

```
Logical Switch Port p1
└── ACL rules:
    ├── ingress: allow tcp port 22 from 0.0.0.0/0
    ├── ingress: allow icmp from 0.0.0.0/0
    ├── ingress: allow related/established
    └── egress: allow all
```

OVN compile ACL thành OVS flows trực tiếp - không cần iptables như linuxbridge.

## OVSDB Port 6640

nova-compute dùng thư viện `vif_plug_ovs` để gắn tap interface vào br-int khi tạo VM. Thư viện này kết nối OVSDB qua TCP port 6640:

```bash
# Bắt buộc phải chạy trên cả controller và compute
ovs-vsctl set-manager ptcp:6640:127.0.0.1
```

Nếu thiếu bước này → VM bị lỗi:
```
Exception: Could not retrieve schema from tcp:127.0.0.1:6640
```

## Debug

```bash
# Xem OVN topology
ovn-nbctl show
ovn-sbctl show

# Xem chassis
ovn-sbctl list chassis

# Xem flows trên br-int
ovs-ofctl dump-flows br-int

# Xem OVS bridges
ovs-vsctl show

# Neutron agents
openstack network agent list

# Log
tail -f /var/log/neutron/neutron-rpc-server.log
tail -f /var/log/ovn/ovn-northd.log
tail -f /var/log/ovn/ovn-controller.log

# Trace packet (debug)
ovn-trace <datapath> 'inport=="<port-name>" && eth.src==<mac> && ip4.dst==<dst-ip>'
```

---

## Lab: Quan sát OVN hoạt động thực tế

### 1. Theo dõi OVN khi tạo network và instance

Mở 2 terminal song song:

**Terminal 1 - watch OVN NB DB:**
```bash
# Xem NB DB thay đổi theo thời gian thực
watch -n 2 ovn-nbctl show
```

**Terminal 2 - tạo network và instance:**
```bash
source ~/demo-openrc

# Tạo network
openstack network create lab-net
openstack subnet create --network lab-net \
  --subnet-range 10.10.10.0/24 lab-subnet

# Quan sát NB DB: xuất hiện Logical Switch mới

# Tạo router
openstack router create lab-router
openstack router add subnet lab-router lab-subnet
openstack router set lab-router --external-gateway provider-net

# Quan sát NB DB: xuất hiện Logical Router + NAT rule

# Tạo instance
NET_ID=$(openstack network list --name lab-net -f value -c ID)
openstack server create --flavor m1.tiny --image cirros \
  --nic net-id=$NET_ID lab-vm

# Quan sát NB DB: xuất hiện Logical Switch Port mới
```

---

### 2. Xem OVN flows trên br-int

```bash
# Trên compute1 - xem flows sau khi VM được tạo
ovs-ofctl dump-flows br-int | head -30

# Xem flows theo table
ovs-ofctl dump-flows br-int table=0   # ingress classification
ovs-ofctl dump-flows br-int table=8   # output
ovs-ofctl dump-flows br-int table=65  # output to local port

# Xem port list trên br-int
ovs-vsctl list-ports br-int
# Sẽ thấy: tap<port-uuid> của VM
```

---

### 3. Trace packet với ovn-trace

```bash
# Lấy thông tin cần thiết
source ~/admin-openrc

# Lấy port name của VM
PORT_ID=$(openstack port list --server lab-vm -f value -c ID | head -1)
PORT_NAME=$(openstack port show $PORT_ID -f value -c name)
VM_MAC=$(openstack port show $PORT_ID -f value -c mac_address)
VM_IP=$(openstack port show $PORT_ID -f value -c fixed_ips | grep -o '192\.168\.[0-9.]*')

# Lấy datapath của network
NETWORK_ID=$(openstack network list --name lab-net -f value -c ID)

# Trace packet từ VM ra internet
ovn-nbctl --ovs lsp-get-ls $PORT_ID
# Lấy datapath UUID từ output trên

# Trace ICMP từ VM đến 8.8.8.8
ovn-trace neutron-$NETWORK_ID \
  "inport==\"$PORT_ID\" && eth.src==$VM_MAC && ip4.src==$VM_IP && ip4.dst==8.8.8.8 && ip.ttl==64 && icmp4"
```

---

### 4. Xem Geneve tunnel giữa các node

```bash
# Trên compute1 - xem tunnel port
ovs-vsctl show | grep -A3 geneve

# Xem tunnel traffic (cần tcpdump)
tcpdump -i ens38 -n port 6081 -c 10
# Port 6081 là Geneve default port

# Khi có VM traffic giữa 2 node, sẽ thấy Geneve packets
```

---

### 5. Kiểm tra Security Group hoạt động

```bash
source ~/demo-openrc

# Xem ACL trong OVN NB DB
PORT_ID=$(openstack port list --server lab-vm -f value -c ID | head -1)
ovn-nbctl list ACL | grep -A5 $PORT_ID

# Test: ping từ VM (qua VNC console)
openstack console url show lab-vm
# Login: cirros / gocubsgo
# ping 8.8.8.8 → phải được (security group cho phép ICMP)

# Xóa rule ICMP và test lại
SG_ID=$(openstack security group list --project demo -f value -c ID | head -1)
RULE_ID=$(openstack security group rule list $SG_ID --protocol icmp -f value -c ID)
openstack security group rule delete $RULE_ID

# ping 8.8.8.8 từ VM → không được nữa

# Thêm lại
openstack security group rule create --proto icmp $SG_ID
```

---

### 6. Xem floating IP flow trong OVN

```bash
source ~/demo-openrc

# Tạo floating IP
FIP=$(openstack floating ip create provider-net -f value -c floating_ip_address)
openstack server add floating ip lab-vm $FIP

# Xem NAT rule trong OVN
ovn-nbctl list NAT
# Sẽ thấy: type=dnat_and_snat, external_ip=$FIP, logical_ip=<VM_IP>

# Xem từ admin
source ~/admin-openrc
openstack floating ip list
```

---

## Troubleshooting: Các lỗi phổ biến với Neutron/OVN

### Cách đọc lỗi nhanh

```bash
# Bước 1: kiểm tra agent status
openstack network agent list

# Bước 2: kiểm tra OVN chassis
ovn-sbctl show

# Bước 3: xem log
tail -50 /var/log/neutron/neutron-rpc-server.log | grep -i error
tail -50 /var/log/ovn/ovn-controller.log | grep -i error
```

---

### Lỗi 1: OVN agent DOWN / Duplicated agents

**Triệu chứng:**
```
openstack network agent list
→ OVN Controller agent | compute1 | XXX | DOWN
```

Hoặc thấy 2 agent cùng hostname, 1 UP 1 DOWN.

**Nguyên nhân:** OVS system-id thay đổi (sau upgrade hoặc reboot), tạo ra Chassis record mới nhưng record cũ chưa bị xóa.

```bash
# Kiểm tra chassis trong SB DB
ovn-sbctl list Chassis | grep -E "hostname|name"

# Nếu thấy 2 record cùng hostname → xóa record cũ (DOWN)
# Lấy UUID của record cũ từ agent list
STALE_UUID="ce9a1471-79c1-4472-adfc-9e5ce86eba07"

ovn-sbctl destroy Chassis $STALE_UUID
ovn-sbctl destroy Chassis_Private $STALE_UUID

# Verify
openstack network agent list
```

**Fix nhanh nếu agent DOWN:**
```bash
# Trên node bị DOWN
systemctl restart ovn-controller
# Chờ 30 giây
openstack network agent list
```

---

### Lỗi 2: VM không có network / không ping được gateway

**Triệu chứng:** VM boot lên nhưng không có IP, hoặc có IP nhưng không ping được `192.168.100.1`.

```bash
# Kiểm tra port binding
source ~/admin-openrc
PORT_ID=$(openstack port list --server <vm-name> -f value -c ID)
openstack port show $PORT_ID | grep -E "binding|status|device"

# Nếu binding:vif_type = binding_failed → OVN không bind được port
# Nguyên nhân: ovn-controller trên compute node không chạy

# Kiểm tra trên compute node
systemctl status ovn-controller
ovs-vsctl show | grep -i error

# Nếu có lỗi "Device or resource busy" → br-provider conflict
# Fix: xem phần br-provider trong 06-neutron.md

# Kiểm tra flows trên br-int
ovs-ofctl dump-flows br-int | grep <port-uuid-prefix>
# Nếu không có flows → ovn-controller chưa push flows
```

---

### Lỗi 3: Floating IP không hoạt động (không ping được từ ngoài)

**Triệu chứng:** Gán floating IP thành công nhưng không SSH/ping được vào VM.

```bash
# Bước 1: kiểm tra security group
openstack security group rule list <sg-name>
# Phải có rule: ingress tcp port 22 và ingress icmp

# Bước 2: kiểm tra NAT rule trong OVN
ovn-nbctl list NAT | grep <floating-ip>
# Phải thấy: type=dnat_and_snat

# Bước 3: kiểm tra Gateway Chassis
ovn-sbctl show | grep -A5 "Gateway_Chassis"
# Controller phải là gateway chassis

# Bước 4: kiểm tra br-provider trên controller
ovs-vsctl show | grep -i error
# Nếu có lỗi → br-provider không hoạt động đúng

# Bước 5: kiểm tra SNAT
# Từ VM (qua VNC), ping 8.8.8.8
# Nếu ping được 8.8.8.8 nhưng không ping được từ ngoài vào
# → vấn đề ở DNAT/floating IP

# Bước 6: trace packet
ovn-trace neutron-<provider-net-id> \
  "inport==\"provnet-xxx\" && eth.dst==<router-mac> && ip4.dst==<floating-ip>"
```

---

### Lỗi 4: VM ping được gateway nhưng không ra internet

**Triệu chứng:** `ping 192.168.100.1` OK nhưng `ping 8.8.8.8` fail.

```bash
# Kiểm tra SNAT rule
ovn-nbctl list NAT | grep snat
# Phải thấy: type=snat, external_ip=<router-external-ip>

# Kiểm tra router có external gateway không
openstack router show router1 | grep external_gateway_info

# Kiểm tra br-provider trên controller có forward được không
# Trên controller:
ping -I br-provider 8.8.8.8
# Nếu không ping được → br-provider không có route ra internet

ip route show dev br-provider
# Phải có: default via 192.168.182.2

# Kiểm tra DNS
cat /etc/resolv.conf
# Nếu trống → echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

---

### Lỗi 5: MTU issue - packet loss với large packets

**Triệu chứng:** ping nhỏ OK, nhưng download/upload chậm hoặc fail. `ping -s 1400 8.8.8.8` fail.

**Nguyên nhân:** Geneve header thêm overhead (~50 bytes), nếu MTU không được cấu hình đúng → packet bị drop.

```bash
# Kiểm tra MTU của network
openstack network show selfservice-net | grep mtu
# Mặc định: 1442 (1500 - 58 bytes Geneve overhead)

# Kiểm tra MTU trong VM (qua VNC)
ip link show eth0
# Phải thấy mtu 1442 (được set qua DHCP)

# Nếu VM dùng static IP và MTU sai:
ip link set eth0 mtu 1442

# Cấu hình MTU cho network
openstack network set --mtu 1442 selfservice-net
```

---

### Lỗi 6: neutron-server không start

**Triệu chứng:**
```
systemctl status neutron-rpc-server → failed
```

```bash
# Xem log chi tiết
journalctl -u neutron-rpc-server -n 50 --no-pager
tail -50 /var/log/neutron/neutron-rpc-server.log

# Nguyên nhân phổ biến:
# 1. Không kết nối được MariaDB
mysql -u neutron -pWelcome123 neutron -e "SELECT 1"

# 2. Không kết nối được RabbitMQ
nc -zv controller 5672

# 3. Không kết nối được OVN NB DB
nc -zv 192.168.225.195 6641

# 4. neutron.conf có lỗi syntax
python3 -c "import configparser; c=configparser.ConfigParser(); c.read('/etc/neutron/neutron.conf')"

# 5. ml2_conf.ini lỗi
python3 -c "import configparser; c=configparser.ConfigParser(); c.read('/etc/neutron/plugins/ml2/ml2_conf.ini')"
```

---

### Lỗi 7: "No OVN chassis for host" khi tạo VM

**Triệu chứng:**
```
Exceeded maximum number of retries... no OVN chassis for host compute1
```

```bash
# Kiểm tra chassis
ovn-sbctl show
# Nếu không thấy compute1 → ovn-controller chưa register

# Trên compute1
systemctl status ovn-controller

# Kiểm tra kết nối đến SB DB
ovs-vsctl get open . external-ids:ovn-remote
# Phải là: tcp:192.168.225.195:6642

nc -zv 192.168.225.195 6642
# Nếu fail → firewall hoặc OVN SB DB chưa listen

# Trên controller - kiểm tra SB DB đang listen
ss -tlnp | grep 6642

# Nếu không listen → set lại
ovn-sbctl set-connection ptcp:6642:192.168.225.195 -- \
  set connection . inactivity_probe=60000

# Restart ovn-controller trên compute1
systemctl restart ovn-controller
# Chờ 10 giây
ovn-sbctl show  # trên controller
```

---

### Quick Diagnostic Script cho Neutron/OVN

```bash
#!/bin/bash
# Chạy trên controller

echo "=== Neutron Agents ==="
openstack network agent list

echo ""
echo "=== OVN Chassis ==="
ovn-sbctl show

echo ""
echo "=== OVS Bridges ==="
ovs-vsctl show | grep -E "Bridge|Port|error"

echo ""
echo "=== OVN NB Summary ==="
ovn-nbctl show | head -40

echo ""
echo "=== Port 6640/6641/6642 ==="
ss -tlnp | grep -E "6640|6641|6642"

echo ""
echo "=== Recent Neutron Errors ==="
grep -i "error\|exception" /var/log/neutron/neutron-rpc-server.log | tail -10

echo ""
echo "=== Recent OVN Controller Errors ==="
grep -i "error\|warn" /var/log/ovn/ovn-controller.log | tail -10
```
