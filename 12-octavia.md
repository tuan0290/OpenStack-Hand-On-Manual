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

Tạo flavor cho Amphora:

```bash
source ~/admin-openrc

openstack flavor create --id 200 --vcpus 1 --ram 1024 \
  --disk 2 "amphora" --private
```

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

### 4.1 Kiểm tra instance đã có sẵn

```bash
source ~/demo-openrc

# Xem các instance đang chạy
openstack server list

# Lấy IP của 2 instance (dùng instance đã tạo từ lab trước)
# Thay tên instance cho phù hợp với lab của bạn
VM1_IP=$(openstack server show my-first-instance -f value -c addresses | grep -oP '192\.168\.100\.\d+' | head -1)
echo "VM1 IP: $VM1_IP"

# Nếu chỉ có 1 instance, tạo thêm 1 cái nữa
NET_ID=$(openstack network list --name selfservice-net -f value -c ID)
openstack server create --flavor m1.tiny --image cirros \
  --nic net-id=$NET_ID --security-group my-sg lb-backend-vm2

VM2_IP=$(openstack server show heat-test-vm -f value -c addresses | grep -oP '192\.168\.100\.\d+' | head -1)
echo "VM2 IP: $VM2_IP"
```

### 4.2 Tạo Load Balancer

```bash
# Tạo LB trên selfservice-net
openstack loadbalancer create \
  --name lb1 \
  --vip-subnet-id selfservice-subnet

# Chờ ACTIVE
watch openstack loadbalancer show lb1 -f value -c provisioning_status

# Tạo listener (port 80)
openstack loadbalancer listener create \
  --name listener1 \
  --protocol HTTP \
  --protocol-port 80 \
  lb1

# Tạo pool (round-robin)
openstack loadbalancer pool create \
  --name pool1 \
  --lb-algorithm ROUND_ROBIN \
  --listener listener1 \
  --protocol HTTP

# Thêm member vào pool (dùng IP của 2 VM đã có)
openstack loadbalancer member create \
  --subnet-id selfservice-subnet \
  --address $VM1_IP \
  --protocol-port 80 \
  pool1

openstack loadbalancer member create \
  --subnet-id selfservice-subnet \
  --address $VM2_IP \
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

### 4.3 Gán Floating IP cho Load Balancer

```bash
# Lấy VIP port của LB
VIP_PORT=$(openstack loadbalancer show lb1 -f value -c vip_port_id)

# Tạo và gán floating IP
FIP=$(openstack floating ip create provider-net -f value -c floating_ip_address)
openstack floating ip set --port $VIP_PORT $FIP

echo "Load Balancer accessible at: $FIP"
```

### 4.4 Test

```bash
# Test từ controller
for i in {1..6}; do
  curl -s http://$FIP/ | head -1
done
# Sẽ thấy response luân phiên từ web1 và web2
```

### 4.5 Dọn dẹp

```bash
openstack loadbalancer delete --cascade lb1
# Chỉ xóa VM tạo thêm cho lab này, giữ lại instance cũ
openstack server delete lb-backend-vm2 2>/dev/null || true
openstack floating ip delete $FIP
```

---

Trước: [11-heat.md](11-heat.md) | Tiếp theo: [13-ceilometer.md](13-ceilometer.md)
