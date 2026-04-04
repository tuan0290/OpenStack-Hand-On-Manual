# Cài đặt Load Balancer (Octavia)

> Octavia cung cấp **Load Balancing as a Service (LBaaS)** cho OpenStack.
> Phân phối traffic đến nhiều VM backend, hỗ trợ health check, SSL termination.

## Octavia là gì?

```
Không có Octavia:
Client → VM1 (overloaded)
         VM2 (idle)
         VM3 (idle)

Có Octavia:
Client → Load Balancer → VM1 (33%)
                      → VM2 (33%)
                      → VM3 (33%)
```

**Kiến trúc Octavia:**

```
User/CLI
    │ API (port 9876)
    ▼
octavia-api
    │ RabbitMQ
    ▼
octavia-worker ──────────────────────────────────────────┐
    │                                                     │
    │ tạo Amphora VM                                      │
    ▼                                                     │
Nova (tạo VM)                                            │
    │                                                     │
    ▼                                                     │
[Amphora VM]  ← VM chạy HAProxy, là load balancer thực   │
    │                                                     │
    │ heartbeat UDP 5555                                  │
    ▼                                                     │
octavia-health-manager ──────────────────────────────────┘
```

**Amphora**: VM được Octavia tạo ra để chạy HAProxy. Mỗi load balancer = 1 Amphora VM.

## Mục lục

1. [Chuẩn bị trên Controller](#1-chuẩn-bị-trên-controller)
2. [Cài đặt và cấu hình Octavia](#2-cài-đặt-và-cấu-hình-octavia)
3. [Kiểm tra](#3-kiểm-tra)
4. [Lab: Tạo Load Balancer](#4-lab-tạo-load-balancer)

---

## 1. Chuẩn bị trên Controller

> Thực hiện trên node **controller**

### 1.1 Tạo database

```bash
mysql -u root -pWelcome123
```

```sql
CREATE DATABASE octavia;
CREATE USER 'octavia'@'localhost' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'localhost';
CREATE USER 'octavia'@'%' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'%';
FLUSH PRIVILEGES;
EXIT;
```

### 1.2 Tạo user, service và endpoint

```bash
source ~/admin-openrc
```

```bash
openstack user create --domain default --password Welcome123 octavia
openstack role add --project service --user octavia admin
```

```bash
openstack service create --name octavia \
  --description "OpenStack Octavia" load-balancer
```

```bash
openstack endpoint create --region RegionOne load-balancer public http://controller:9876
openstack endpoint create --region RegionOne load-balancer internal http://controller:9876
openstack endpoint create --region RegionOne load-balancer admin http://controller:9876
```

Tạo file octavia-openrc:

```bash
cat > ~/octavia-openrc << 'EOF'
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=service
export OS_USERNAME=octavia
export OS_PASSWORD=Welcome123
export OS_AUTH_URL=http://controller:5000
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
export OS_VOLUME_API_VERSION=3
EOF
```

### 1.3 Cài đặt package

```bash
apt install -y octavia-api octavia-health-manager octavia-housekeeping \
  octavia-worker python3-octavia python3-octaviaclient
```

> Nếu được hỏi cấu hình, chọn **No**.

### 1.4 Tạo Amphora image

Amphora là image VM chạy HAProxy. Cần build từ source:

```bash
apt install -y debootstrap qemu-utils git kpartx python3-pip

git clone https://opendev.org/openstack/octavia.git /opt/octavia

# Cài diskimage-builder
apt install -y diskimage-builder 2>/dev/null || \
  python3 -m pip install diskimage-builder --break-system-packages

# Build amphora image (mất 10-20 phút)
cd /opt/octavia
./diskimage-create/diskimage-create.sh -i ubuntu-minimal -s 2 -o /tmp/amphora-x64-haproxy

# Kiểm tra file output (tự động thêm .qcow2)
ls -lh /tmp/amphora-x64-haproxy.qcow2
```

Upload image lên Glance:

```bash
source ~/octavia-openrc

openstack image create --disk-format qcow2 --container-format bare \
  --private --tag amphora \
  --file /tmp/amphora-x64-haproxy.qcow2 amphora-x64-haproxy
```

Tạo flavor cho Amphora và gán cho project service:

```bash
source ~/admin-openrc

openstack flavor create --id 200 --vcpus 1 --ram 1024 \
  --disk 2 "amphora" --private

# Bắt buộc: gán flavor cho project service
# Nếu không, Nova sẽ báo "No valid host was found" khi tạo Amphora VM
SERVICE_PROJECT_ID=$(openstack project show service -f value -c id)
openstack flavor set 200 --project $SERVICE_PROJECT_ID

# Verify - access_project_ids phải có giá trị, KHÔNG được rỗng []
openstack flavor show 200 | grep access_project_ids
```

> **Lưu ý quan trọng**: Nếu `access_project_ids` vẫn hiển thị `[]` sau khi chạy lệnh trên, dùng Nova API trực tiếp:
>
> ```bash
> # Lấy token và gán flavor access qua Nova API
> SERVICE_PROJECT_ID=$(openstack project show service -f value -c id)
> nova flavor-access-add 200 $SERVICE_PROJECT_ID
>
> # Verify lại
> nova flavor-access-list --flavor 200
> # Phải thấy project service trong danh sách
> ```

### 1.5 Tạo certificates

```bash
cd /opt/octavia/bin/
source create_dual_intermediate_CA.sh

sudo mkdir -p /etc/octavia/certs/private
sudo chmod 755 /etc/octavia -R
sudo cp -p etc/octavia/certs/server_ca.cert.pem /etc/octavia/certs
sudo cp -p etc/octavia/certs/server_ca-chain.cert.pem /etc/octavia/certs
sudo cp -p etc/octavia/certs/server_ca.key.pem /etc/octavia/certs/private
sudo cp -p etc/octavia/certs/client_ca.cert.pem /etc/octavia/certs
sudo cp -p etc/octavia/certs/client.cert-and-key.pem /etc/octavia/certs/private
```

### 1.6 Tạo security groups và management network

```bash
source ~/octavia-openrc

# Security groups
openstack security group create lb-mgmt-sec-grp
openstack security group rule create --protocol icmp lb-mgmt-sec-grp
openstack security group rule create --protocol tcp --dst-port 22 lb-mgmt-sec-grp
openstack security group rule create --protocol tcp --dst-port 9443 lb-mgmt-sec-grp

openstack security group create lb-health-mgr-sec-grp
openstack security group rule create --protocol udp --dst-port 5555 lb-health-mgr-sec-grp

# Key pair
# Tạo SSH key nếu chưa có
[ -f ~/.ssh/id_rsa.pub ] || ssh-keygen -q -N "" -f ~/.ssh/id_rsa
openstack keypair create --public-key ~/.ssh/id_rsa.pub mykey
```

Tạo management network cho Amphora:

```bash
OCTAVIA_MGMT_SUBNET=172.16.0.0/12
OCTAVIA_MGMT_SUBNET_START=172.16.0.100
OCTAVIA_MGMT_SUBNET_END=172.16.31.254
OCTAVIA_MGMT_PORT_IP=172.16.0.2

openstack network create lb-mgmt-net
openstack subnet create --subnet-range $OCTAVIA_MGMT_SUBNET \
  --allocation-pool start=$OCTAVIA_MGMT_SUBNET_START,end=$OCTAVIA_MGMT_SUBNET_END \
  --network lb-mgmt-net lb-mgmt-subnet

SUBNET_ID=$(openstack subnet show lb-mgmt-subnet -f value -c id)
PORT_FIXED_IP="--fixed-ip subnet=$SUBNET_ID,ip-address=$OCTAVIA_MGMT_PORT_IP"

MGMT_PORT_ID=$(openstack port create --security-group \
  lb-health-mgr-sec-grp --device-owner Octavia:health-mgr \
  --host=$(hostname) -c id -f value --network lb-mgmt-net \
  $PORT_FIXED_IP octavia-health-manager-listen-port)

MGMT_PORT_MAC=$(openstack port show -c mac_address -f value $MGMT_PORT_ID)

# Tạo veth pair để health manager kết nối vào management network
apt install -y bridge-utils
sudo ip link add o-hm0 type veth peer name o-bhm0
NETID=$(openstack network show lb-mgmt-net -c id -f value)
# Lab này dùng OVN → dùng br-int thay vì brq* (linuxbridge)
BRNAME=br-int
sudo ovs-vsctl add-port $BRNAME o-bhm0
sudo ip link set o-bhm0 up
sudo ip link set dev o-hm0 address $MGMT_PORT_MAC
sudo iptables -I INPUT -i o-hm0 -p udp --dport 5555 -j ACCEPT

# Với OVN, dùng IP tĩnh thay vì DHCP vì o-bhm0 kết nối vào br-int
# không qua DHCP agent thông thường
sudo ip addr add 172.16.0.2/12 dev o-hm0
sudo ip link set o-hm0 up

# Quan trọng: set iface-id để OVN nhận diện port và forward traffic đúng
PORT_ID=$(openstack port show octavia-health-manager-listen-port -f value -c id)
ovs-vsctl set Interface o-bhm0 external-ids:iface-id=$PORT_ID

# Verify kết nối (sau khi tạo LB, Amphora VM sẽ có IP trong 172.16.x.x)
# ping -c 2 <amphora-ip>

echo "MGMT_PORT_MAC=$MGMT_PORT_MAC"
echo "BRNAME=$BRNAME"
# Lưu lại 2 giá trị này để dùng ở bước tiếp theo
```

Tạo systemd service để persistent veth pair qua reboot:

```bash
# Tạo file network config cho o-hm0
cat > /etc/systemd/network/o-hm0.network << 'EOF'
[Match]
Name=o-hm0

[Network]
DHCP=yes
EOF
```

```bash
# Thay $MGMT_PORT_MAC và $BRNAME bằng giá trị thực tế ở trên
cat > /opt/octavia-interface.sh << EOF
#!/bin/bash
set -ex
MAC=$MGMT_PORT_MAC
BRNAME=$BRNAME
if [ "\$1" == "start" ]; then
  ip link add o-hm0 type veth peer name o-bhm0
  ovs-vsctl add-port \$BRNAME o-bhm0
  ip link set o-bhm0 up
  ip link set dev o-hm0 address \$MAC
  ip link set o-hm0 up
  ip addr add 172.16.0.2/12 dev o-hm0
  iptables -I INPUT -i o-hm0 -p udp --dport 5555 -j ACCEPT
elif [ "\$1" == "stop" ]; then
  ovs-vsctl del-port \$BRNAME o-bhm0 2>/dev/null || true
  ip link del o-hm0
fi
EOF
chmod +x /opt/octavia-interface.sh
```

```bash
# Tạo systemd service
# Lưu ý: dùng ovn-controller thay vì neutron-linuxbridge-agent vì lab này dùng OVN
cat > /etc/systemd/system/octavia-interface.service << 'EOF'
[Unit]
Description=Octavia Interface Creator
After=ovn-controller.service
Wants=ovn-controller.service

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/opt/octavia-interface.sh start
ExecStop=/opt/octavia-interface.sh stop

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable octavia-interface
```

---

## 2. Cài đặt và cấu hình Octavia

### 2.1 Cấu hình octavia.conf

Lấy các ID cần thiết:

```bash
source ~/admin-openrc
SERVICE_PROJECT_ID=$(openstack project show service -f value -c id)
LB_MGMT_SEC_GRP_ID=$(openstack security group show lb-mgmt-sec-grp -f value -c id)
LB_MGMT_NET_ID=$(openstack network show lb-mgmt-net -f value -c id)

echo "SERVICE_PROJECT_ID=$SERVICE_PROJECT_ID"
echo "LB_MGMT_SEC_GRP_ID=$LB_MGMT_SEC_GRP_ID"
echo "LB_MGMT_NET_ID=$LB_MGMT_NET_ID"
# Lưu lại 3 giá trị này để điền vào octavia.conf
```

Sửa file `/etc/octavia/octavia.conf`:

Trong section `[database]`:

```ini
[database]
connection = mysql+pymysql://octavia:Welcome123@controller/octavia
```

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller
```

Trong section `[oslo_messaging]`:

```ini
[oslo_messaging]
topic = octavia_prov
```

Trong section `[api_settings]`:

```ini
[api_settings]
bind_host = 0.0.0.0
bind_port = 9876
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
username = octavia
password = Welcome123
```

Trong section `[service_auth]`:

```ini
[service_auth]
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = octavia
password = Welcome123
```

Trong section `[certificates]`:

```ini
[certificates]
server_certs_key_passphrase = insecure-key-do-not-use-this-key
ca_private_key_passphrase = not-secure-passphrase
ca_private_key = /etc/octavia/certs/private/server_ca.key.pem
ca_certificate = /etc/octavia/certs/server_ca.cert.pem
```

Trong section `[haproxy_amphora]`:

```ini
[haproxy_amphora]
server_ca = /etc/octavia/certs/server_ca-chain.cert.pem
client_cert = /etc/octavia/certs/private/client.cert-and-key.pem
```

Trong section `[health_manager]`:

```ini
[health_manager]
bind_port = 5555
bind_ip = 172.16.0.2
controller_ip_port_list = 172.16.0.2:5555
```

Trong section `[controller_worker]`:

```ini
[controller_worker]
amp_image_owner_id = <SERVICE_PROJECT_ID>
amp_image_tag = amphora
amp_ssh_key_name = mykey
amp_secgroup_list = <LB_MGMT_SEC_GRP_ID>
amp_boot_network_list = <LB_MGMT_NET_ID>
amp_flavor_id = 200
network_driver = allowed_address_pairs_driver
compute_driver = compute_nova_driver
amphora_driver = amphora_haproxy_rest_driver
client_ca = /etc/octavia/certs/client_ca.cert.pem
```

> Thay `<SERVICE_PROJECT_ID>`, `<LB_MGMT_SEC_GRP_ID>`, `<LB_MGMT_NET_ID>` bằng giá trị thực tế lấy ở bước trên.

### 2.2 Đồng bộ database

```bash
octavia-db-manage --config-file /etc/octavia/octavia.conf upgrade head
```

### 2.3 Phân quyền certificates

```bash
# Octavia user cần đọc được certificates
chown -R octavia:octavia /etc/octavia/certs/
```

### 2.3 Khởi động service

```bash
systemctl restart octavia-api octavia-health-manager \
  octavia-housekeeping octavia-worker
systemctl enable octavia-api octavia-health-manager \
  octavia-housekeeping octavia-worker
```

---

## 3. Kiểm tra

```bash
source ~/admin-openrc

openstack loadbalancer list
# Phải không có lỗi

openstack loadbalancer provider list
# Phải thấy: amphora
```

---

## 4. Lab: Tạo Load Balancer

Lab này tạo 1 VM backend chạy web server đơn giản, sau đó đặt Load Balancer phía trước.

### 4.1 Tạo VM backend

```bash
source ~/demo-openrc

# Tạo VM backend chạy cirros
NET_ID=$(openstack network show selfservice-net -f value -c id)
openstack server create --flavor m1.tiny --image cirros \
  --nic net-id=$NET_ID --security-group my-sg lb-backend-vm1

# Chờ VM ACTIVE
openstack server show lb-backend-vm1 -f value -c status

# Lấy IP
VM1_IP=$(openstack server show lb-backend-vm1 -f value -c addresses | grep -oP '192\.168\.100\.\d+')
echo "VM1 IP: $VM1_IP"
```

### 4.2 Tạo Load Balancer

```bash
# Tạo LB - Octavia sẽ tạo Amphora VM (mất 1-2 phút)
openstack loadbalancer create \
  --name lb1 \
  --vip-subnet-id selfservice-subnet

# Chờ ACTIVE (theo dõi realtime)
watch openstack loadbalancer show lb1 -f value -c provisioning_status
# Khi thấy ACTIVE → Ctrl+C
```

### 4.3 Tạo Listener, Pool và Member

```bash
# Tạo listener HTTP port 80
openstack loadbalancer listener create \
  --name listener1 \
  --protocol HTTP \
  --protocol-port 80 \
  lb1

# Chờ listener ACTIVE
openstack loadbalancer listener show listener1 -f value -c provisioning_status

# Tạo pool
openstack loadbalancer pool create \
  --name pool1 \
  --lb-algorithm ROUND_ROBIN \
  --listener listener1 \
  --protocol HTTP

# Thêm VM vào pool
openstack loadbalancer member create \
  --subnet-id selfservice-subnet \
  --address $VM1_IP \
  --protocol-port 80 \
  pool1

# Tạo health monitor
openstack loadbalancer healthmonitor create \
  --delay 5 \
  --max-retries 3 \
  --timeout 5 \
  --type HTTP \
  --url-path / \
  pool1
```

### 4.4 Gán Floating IP

```bash
VIP_PORT=$(openstack loadbalancer show lb1 -f value -c vip_port_id)
FIP=$(openstack floating ip create provider-net -f value -c floating_ip_address)
openstack floating ip set --port $VIP_PORT $FIP

echo "Load Balancer VIP: $FIP"
```

### 4.5 Test

```bash
# Gửi request đến LB
curl -s http://$FIP/
```

### 4.6 Dọn dẹp

```bash
openstack loadbalancer delete --cascade lb1
openstack server delete lb-backend-vm1
openstack floating ip delete $FIP
```

---

Trước: [11-heat.md](11-heat.md) | Tiếp theo: [13-ceilometer.md](13-ceilometer.md)

---

## Hỏi & Đáp

### Tại sao o-hm0 không kết nối được Amphora VM dù đã add vào br-int?

Đây là vấn đề thực tế gặp phải khi dùng OVN thay vì linuxbridge.

**Vấn đề:**

```
Controller
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  o-hm0 (172.16.0.2) ←→ o-bhm0                         │
│                              │                          │
│                    ovs-vsctl add-port br-int o-bhm0     │
│                              │                          │
│                         ┌────┴────┐                     │
│                         │ br-int  │  ← OVN managed      │
│                         └────┬────┘                     │
│                              │                          │
│                    ⚠ OVN không biết o-bhm0              │
│                      thuộc network nào!                 │
│                      → không forward traffic            │
└─────────────────────────────────────────────────────────┘

Amphora VM (172.16.1.9) ← không reachable
```

**Nguyên nhân gốc rễ:**

OVN quản lý forwarding dựa trên **Logical Switch Port** trong NB DB. Khi `ovs-vsctl add-port br-int o-bhm0`, OVS biết port này tồn tại nhưng OVN không biết port này map với Neutron port nào → không tạo flow để forward traffic.

**Giải pháp:**

```
Controller
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  o-hm0 (172.16.0.2) ←→ o-bhm0                         │
│                              │                          │
│                    ovs-vsctl set Interface o-bhm0 \     │
│                      external-ids:iface-id=<PORT_ID>   │
│                              │                          │
│                         ┌────┴────┐                     │
│                         │ br-int  │                     │
│                         └────┬────┘                     │
│                              │                          │
│                    ✓ OVN biết o-bhm0 = Neutron port     │
│                      octavia-health-manager-listen-port │
│                      → tạo flow forward traffic         │
└─────────────────────────────────────────────────────────┘

Amphora VM (172.16.1.9) ← reachable ✓
```

**Cơ chế hoạt động:**

```
ovs-vsctl set Interface o-bhm0 external-ids:iface-id=<PORT_ID>
                │
                │ OVN controller đọc external-ids
                ▼
OVN SB DB: binding port <PORT_ID> → chassis controller, interface o-bhm0
                │
                │ ovn-controller push flows
                ▼
br-int flows: traffic đến/từ 172.16.0.2 ↔ lb-mgmt-net được forward đúng
```

**Lệnh fix:**

```bash
PORT_ID=$(openstack port show octavia-health-manager-listen-port -f value -c id)
ovs-vsctl set Interface o-bhm0 external-ids:iface-id=$PORT_ID
```

Đây là bước **bắt buộc** khi dùng OVN. Với linuxbridge (docs cũ), bước này không cần vì linuxbridge dùng cơ chế khác.

---

### Nova báo "No valid host was found" khi tạo Amphora VM

Đây là lỗi phổ biến nhất khi cài Octavia. Nova scheduler từ chối tạo VM cho Amphora.

**Sơ đồ luồng lỗi:**

```
octavia-worker
    │ yêu cầu tạo Amphora VM
    ▼
Nova API → Nova Conductor → Nova Scheduler
                                  │
                          kiểm tra từng filter
                                  │
                    ┌─────────────┼─────────────┐
                    ▼             ▼             ▼
             FlavorFilter  ResourceFilter  AggregateFilter
                    │             │             │
              flavor 200    VCPU/RAM/Disk   host aggregate
              accessible?   đủ không?       match không?
                    │
              ⚠ FAILED ← access_project_ids = [] (rỗng)
                    │
                    ▼
        NoValidHost exception → octavia-worker nhận lỗi
```

**Nguyên nhân #1 (phổ biến nhất): Flavor chưa được gán đúng cho project service**

```bash
# Kiểm tra
openstack flavor show 200 | grep access_project_ids
# Nếu thấy: access_project_ids | []  ← ĐÂY LÀ VẤN ĐỀ
```

`openstack flavor set 200 --project $SERVICE_PROJECT_ID` đôi khi không hoạt động đúng. Dùng nova CLI thay thế:

```bash
source ~/admin-openrc
SERVICE_PROJECT_ID=$(openstack project show service -f value -c id)

# Dùng nova CLI (đáng tin cậy hơn)
nova flavor-access-add 200 $SERVICE_PROJECT_ID

# Verify
nova flavor-access-list --flavor 200
# Phải thấy project service trong danh sách
```

**Nguyên nhân #2: Placement không có đủ inventory**

```bash
# Lấy UUID của compute1
COMPUTE_UUID=$(openstack resource provider list -f value -c uuid --name compute1)

# Kiểm tra inventory
openstack resource provider inventory list $COMPUTE_UUID

# Kiểm tra usage hiện tại
openstack resource provider usage show $COMPUTE_UUID
```

Nếu `VCPU`, `MEMORY_MB`, hoặc `DISK_GB` đã dùng hết → cần giải phóng tài nguyên hoặc tăng capacity.

**Nguyên nhân #3: IDs trong octavia.conf không còn hợp lệ**

```bash
source ~/admin-openrc

# So sánh với giá trị trong /etc/octavia/octavia.conf
echo "=== amp_image_owner_id ==="
openstack project show service -f value -c id

echo "=== amp_secgroup_list ==="
openstack security group show lb-mgmt-sec-grp -f value -c id

echo "=== amp_boot_network_list ==="
openstack network show lb-mgmt-net -f value -c id
```

Nếu có ID nào khác với trong `octavia.conf` → cập nhật file và restart:

```bash
systemctl restart octavia-worker
```

**Nguyên nhân #4: Amphora image không accessible với octavia user**

```bash
source ~/octavia-openrc
openstack image list | grep amphora
# Nếu không thấy → image chưa được tag hoặc owner sai
```

**Quy trình debug nhanh:**

```bash
# 1. Kiểm tra Nova scheduler log
tail -50 /var/log/nova/nova-scheduler.log | grep -i "filter\|NoValid\|reject"

# 2. Kiểm tra flavor access
nova flavor-access-list --flavor 200

# 3. Kiểm tra compute node up
openstack hypervisor list

# 4. Kiểm tra Placement
openstack resource provider list
```
