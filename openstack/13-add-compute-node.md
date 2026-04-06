# Thêm Compute Node mới vào OpenStack

> Hướng dẫn này mô tả cách thêm node **compute2** (hoặc bất kỳ compute node mới nào) vào cluster OpenStack đang chạy mà không cần downtime.

## Mục lục

1. [Chuẩn bị VM mới](#1-chuẩn-bị-vm-mới)
2. [Cấu hình môi trường trên compute2](#2-cấu-hình-môi-trường-trên-compute2)
3. [Cài đặt Nova Compute](#3-cài-đặt-nova-compute)
4. [Cài đặt Neutron OVN](#4-cài-đặt-neutron-ovn)
5. [Cài đặt Ceilometer (tùy chọn)](#5-cài-đặt-ceilometer-tùy-chọn)
6. [Đăng ký node với Controller](#6-đăng-ký-node-với-controller)
7. [Kiểm tra](#7-kiểm-tra)

---

## 1. Chuẩn bị VM mới

### 1.1 Tạo VM trong VMware

Tạo VM mới với cấu hình tương tự compute1:

| Thông số | Giá trị |
|---|---|
| OS | Ubuntu 24.04 LTS Server |
| vCPU | 4 |
| RAM | 4 GB |
| Disk | 50 GB |
| Network 1 | VMnet8 (NAT) - ens33 |
| Network 2 | VMnet1 (Host-only) - ens37 |
| Network 3 | VMnet2 (Host-only) - ens38 |

### 1.2 IP Planning cho compute2

| Interface | Network | IP | Mục đích |
|---|---|---|---|
| ens33 | VMnet8 (NAT) | 192.168.182.201 | Provider |
| ens37 | VMnet1 (Host-only) | 192.168.225.201 | Management |
| ens38 | VMnet2 (Host-only) | 192.168.147.201 | Tunnel |

> Thay đổi IP theo thực tế nếu dùng địa chỉ khác.

---

## 2. Cấu hình môi trường trên compute2

> Thực hiện trên node **compute2**

### 2.1 Cấu hình hostname và hosts

```bash
hostnamectl set-hostname compute2

cat > /etc/hosts << 'EOF'
127.0.0.1   localhost
192.168.225.195   controller
192.168.225.196   compute1
192.168.225.201   compute2
192.168.225.197   storage1
192.168.225.198   object1
192.168.225.199   object2
EOF
```

> Lưu ý: `/etc/hosts` dùng Management IP (192.168.225.x), không dùng Provider IP.

### 2.2 Cấu hình network interfaces

```bash
cat > /etc/netplan/00-installer-config.yaml << 'EOF'
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - 192.168.182.201/24
      routes:
        - to: default
          via: 192.168.182.2
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
    ens37:
      addresses:
        - 192.168.225.201/24
    ens38:
      addresses:
        - 192.168.147.201/24
EOF

netplan apply
```

### 2.3 Cấu hình DNS (tránh bị ghi đè bởi systemd-resolved)

```bash
mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/dns.conf << 'EOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1
DNSStubListener=no
EOF

ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved
```

### 2.4 Cài đặt các package cơ bản

```bash
apt update && apt upgrade -y
apt install -y chrony curl wget vim git python3-openstackclient
```

### 2.5 Cấu hình NTP (sync theo controller)

```bash
cat > /etc/chrony/chrony.conf << 'EOF'
server controller iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF

systemctl restart chrony
chronyc tracking
```

### 2.6 Copy SSH key từ controller (để controller có thể SSH vào)

Trên **controller**:

```bash
ssh-copy-id root@compute2
# Hoặc
ssh-copy-id root@192.168.225.201
```

---

## 3. Cài đặt Nova Compute

> Thực hiện trên node **compute2**

### 3.1 Cài đặt package

```bash
apt install -y nova-compute
```

### 3.2 Cấu hình nova.conf

Sửa file `/etc/nova/nova.conf`:

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller
my_ip = 192.168.225.201
```

Trong section `[api]`:

```ini
[api]
auth_strategy = keystone
```

Trong section `[keystone_authtoken]`:

```ini
[keystone_authtoken]
www_authenticate_uri = http://controller:5000/
auth_url = http://controller:5000/
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = nova
password = Welcome123
```

Trong section `[service_user]`:

```ini
[service_user]
send_service_user_token = true
auth_url = http://controller:5000/identity
auth_strategy = keystone
auth_type = password
project_domain_name = Default
project_name = service
user_domain_name = Default
username = nova
password = Welcome123
```

Trong section `[vnc]`:

```ini
[vnc]
enabled = true
server_listen = 0.0.0.0
server_proxyclient_address = $my_ip
novncproxy_base_url = http://192.168.182.195:6080/vnc_lite.html
```

Trong section `[glance]`:

```ini
[glance]
api_servers = http://controller:9292
```

Trong section `[oslo_concurrency]`:

```ini
[oslo_concurrency]
lock_path = /var/lib/nova/tmp
```

Trong section `[placement]`:

```ini
[placement]
region_name = RegionOne
project_domain_name = Default
project_name = service
auth_type = password
user_domain_name = Default
auth_url = http://controller:5000/v3
username = placement
password = Welcome123
```

Trong section `[neutron]`:

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

### 3.3 Kiểm tra hỗ trợ KVM

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
```

Nếu kết quả là `0` → CPU không hỗ trợ hardware virtualization, dùng QEMU:

```bash
# Sửa /etc/nova/nova-compute.conf
cat > /etc/nova/nova-compute.conf << 'EOF'
[DEFAULT]
compute_driver = libvirt.LibvirtDriver

[libvirt]
virt_type = qemu
EOF
```

### 3.4 Khởi động service

```bash
systemctl restart nova-compute
systemctl enable nova-compute
```

---

## 4. Cài đặt Neutron OVN

> Thực hiện trên node **compute2**

### 4.1 Cài đặt package

```bash
apt install -y neutron-ovn-metadata-agent ovn-host
```

### 4.2 Cấu hình neutron.conf

Sửa `/etc/neutron/neutron.conf`:

```ini
[DEFAULT]
transport_url = rabbit://openstack:Welcome123@controller
auth_strategy = keystone

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

[oslo_concurrency]
lock_path = /var/lib/neutron/tmp
```

### 4.3 Cấu hình OVN metadata agent

Sửa `/etc/neutron/neutron_ovn_metadata_agent.ini`:

```ini
[DEFAULT]
nova_metadata_host = controller

[ovs]
ovsdb_connection = tcp:127.0.0.1:6640

[ovn]
ovn_sb_connection = tcp:192.168.225.195:6642

[agent]
root_helper = sudo neutron-rootwrap /etc/neutron/rootwrap.conf
```

### 4.4 Cấu hình OVS và kết nối vào OVN cluster

```bash
# Khởi động OVS
systemctl start openvswitch-switch
systemctl enable openvswitch-switch

# Kết nối OVS vào OVN SB DB trên controller
ovs-vsctl set open . external-ids:ovn-remote=tcp:192.168.225.195:6642
ovs-vsctl set open . external-ids:ovn-encap-type=geneve
ovs-vsctl set open . external-ids:ovn-encap-ip=192.168.147.201

# Khởi động OVN controller
systemctl start ovn-controller
systemctl enable ovn-controller
```

### 4.5 Khởi động Neutron metadata agent

```bash
systemctl restart neutron-ovn-metadata-agent
systemctl enable neutron-ovn-metadata-agent
```

---

## 5. Cài đặt Ceilometer (tùy chọn)

> Thực hiện trên node **compute2** nếu đã cài Ceilometer

```bash
apt install -y ceilometer-agent-compute

# Cấu hình giống compute1
cp /etc/ceilometer/ceilometer.conf /etc/ceilometer/ceilometer.conf.bak
# Sửa transport_url và service_credentials như trong 14-ceilometer.md

systemctl restart ceilometer-agent-compute nova-compute
systemctl enable ceilometer-agent-compute
```

---

## 6. Đăng ký node với Controller

> Thực hiện trên node **controller**

### 6.1 Discover compute node mới

```bash
source ~/admin-openrc

# Nova tự discover compute node mới qua RabbitMQ
# Chạy lệnh này để force discover ngay
nova-manage cell_v2 discover_hosts --verbose
```

### 6.2 Cập nhật /etc/hosts trên tất cả nodes

Thêm `compute2` vào `/etc/hosts` trên **controller**, **compute1**, **storage1**, **object1**, **object2**:

```bash
# Chạy từ bastion
for node in 192.168.225.195 192.168.225.196 192.168.225.197 192.168.225.198 192.168.225.199; do
  ssh root@$node "echo '192.168.225.201   compute2' >> /etc/hosts"
done
```

### 6.3 Cập nhật bastion-check.sh

Thêm compute2 vào script check:

```bash
# Sửa scripts/bastion-check.sh
# Thêm COMPUTE2="192.168.225.201"
# Thêm check_remote_services $COMPUTE2 "COMPUTE2" nova-compute neutron-ovn-metadata-agent ovn-controller openvswitch-switch
```

---

## 7. Kiểm tra

```bash
source ~/admin-openrc

# Verify compute2 đã được đăng ký
openstack compute service list
# Phải thấy nova-compute trên compute2 với State=up

# Verify Neutron agent
openstack network agent list
# Phải thấy ovn-controller và neutron-ovn-metadata-agent trên compute2

# Verify Placement
openstack resource provider list
# Phải thấy compute2 trong danh sách

# Test tạo VM trên compute2
openstack server create \
  --flavor m1.tiny \
  --image cirros \
  --nic net-id=$(openstack network show selfservice-net -f value -c id) \
  --availability-zone nova:compute2 \
  test-compute2

openstack server show test-compute2 -f value -c status -c OS-EXT-SRV-ATTR:host
# Status phải là ACTIVE, host phải là compute2

# Dọn dẹp
openstack server delete test-compute2
```

---

Trước: [12-octavia.md](12-octavia.md) | Tiếp theo: [14-ceilometer.md](14-ceilometer.md)
