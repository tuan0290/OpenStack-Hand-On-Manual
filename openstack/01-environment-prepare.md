# Tài liệu cài đặt OpenStack Flamingo (2025.2) trên Ubuntu 24.04

## Mục lục

1. [Mô hình cài đặt](#1-mô-hình-cài-đặt)
2. [IP Planning](#2-ip-planning)
3. [Cấu hình VMware](#3-cấu-hình-vmware)
4. [Cài đặt môi trường trên node Controller](#4-cài-đặt-môi-trường-trên-node-controller)
5. [Cài đặt môi trường trên node Compute](#5-cài-đặt-môi-trường-trên-node-compute)

---

## 1. Mô hình cài đặt
Mô hình mạng trong VmWare
![Mô hình mạng Virtual Network](/image/Vitrual_network.png)

Mô hình triển khai Lab OpenStack Flamingo (2025.2) trên Ubuntu 24.04 LTS với 2 VM chạy trên VMware Workstation.


![Mô hình triển khai](/image/Gemini_Generated_Image_b7ell5b7ell5b7el.png)


**Vai trò từng mạng:**

| VMware Network | Type | Interface | Mục đích | Dải IP |
|---|---|---|---|---|
| VMnet8 | NAT | ens33 | Provider - kết nối internet, Floating IP, truy cập Horizon | 192.168.182.0/24 |
| VMnet1 | Host-only | ens37 | Management - giao tiếp nội bộ giữa các node | 192.168.225.0/24 |
| VMnet2 | Host-only | ens38 | Tunnel/Overlay - VXLAN traffic giữa các node | 192.168.147.0/24 |

---

## 2. IP Planning

### Phân hoạch địa chỉ IP

**Core nodes (bắt buộc):**

| Hostname | VMware Net | Interface | IP Address | Netmask | Gateway | DNS |
|---|---|---|---|---|---|---|
| Controller | VMnet8 (NAT) | ens33 | 192.168.182.195 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 |
| Controller | VMnet1 (Host-only) | ens37 | 192.168.225.195 | 255.255.255.0 | | |
| Controller | VMnet2 (Host-only) | ens38 | 192.168.147.195 | 255.255.255.0 | | |
| Compute1 | VMnet8 (NAT) | ens33 | 192.168.182.196 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 |
| Compute1 | VMnet1 (Host-only) | ens37 | 192.168.225.196 | 255.255.255.0 | | |
| Compute1 | VMnet2 (Host-only) | ens38 | 192.168.147.196 | 255.255.255.0 | | |

**Extended nodes (tùy chọn - Cinder/Swift):**

| Hostname | VMware Net | Interface | IP Address | Netmask | Gateway | DNS | Dùng cho |
|---|---|---|---|---|---|---|---|
| storage1 | VMnet8 (NAT) | ens33 | 192.168.182.197 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 | Cinder |
| storage1 | VMnet1 (Host-only) | ens37 | 192.168.225.197 | 255.255.255.0 | | | Cinder |
| object1 | VMnet8 (NAT) | ens33 | 192.168.182.198 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 | Swift |
| object1 | VMnet1 (Host-only) | ens37 | 192.168.225.198 | 255.255.255.0 | | | Swift |
| object2 | VMnet8 (NAT) | ens33 | 192.168.182.199 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 | Swift |
| object2 | VMnet1 (Host-only) | ens37 | 192.168.225.199 | 255.255.255.0 | | | Swift |

> Gateway của VMnet8 (NAT) mặc định VMware dùng `.2` (ví dụ `192.168.182.2`). Kiểm tra lại trong **VMware → Edit → Virtual Network Editor → VMnet8 → NAT Settings**.

### Yêu cầu phần cứng tối thiểu

**Core nodes:**

| Node | vCPU | RAM | Disk 1 (OS) | Disk 2 | Ghi chú |
|---|---|---|---|---|---|
| Controller | 4 | 4 GB | 40 GB | 30 GB | Disk 2 dự phòng |
| Compute1 | 4 | 4 GB | 50 GB | - | |

**Extended nodes:**

| Node | vCPU | RAM | Disk 1 (OS) | Disk 2 | Disk 3 | Ghi chú |
|---|---|---|---|---|---|---|
| storage1 | 2 | 2 GB | 20 GB | 50 GB | - | Disk 2 cho Cinder LVM |
| object1 | 2 | 2 GB | 20 GB | 20 GB | 20 GB | Disk 2+3 cho Swift data |
| object2 | 2 | 2 GB | 20 GB | 20 GB | 20 GB | Disk 2+3 cho Swift data |

**Lưu ý chung:**
- OS: Ubuntu 24.04 LTS (Server)
- Password thống nhất cho tất cả dịch vụ: `Welcome123`
- Tất cả các bước cài đặt thực hiện với quyền **root**

---

## 3. Cấu hình VMware

### 3.1 Gán Network Adapter cho từng VM

Trong **VM Settings** của mỗi VM, cấu hình 3 Network Adapter:

| Adapter | Kết nối vào | Mục đích |
|---|---|---|
| Network Adapter 1 | VMnet8 (NAT) | Provider / Internet |
| Network Adapter 2 | VMnet1 (Host-only) | Management |
| Network Adapter 3 | VMnet2 (Host-only) | Tunnel |

> Adapter 1 là NAT vì Ubuntu tự nhận `ens33` khi cài, có internet ngay mà không cần cấu hình thêm.

---

## 4. Cài đặt môi trường trên node Controller

### 4.1 Cập nhật hệ thống

```bash
apt update && apt upgrade -y
```

### 4.2 Cấu hình network

Kiểm tra tên interface thực tế trước khi cấu hình:

```bash
ip a
```

Kết quả thường thấy trên VMware Workstation:

```
2: ens33: ...   ← Network Adapter 1 (VMnet8 - Provider/NAT)   ← có IP từ DHCP lúc cài
3: ens37: ...   ← Network Adapter 2 (VMnet1 - Management)
4: ens38: ...   ← Network Adapter 3 (VMnet2 - Tunnel)
```

> Nếu tên interface khác, thay thế `ens33/37/38` trong tất cả các bước bên dưới bằng tên thực tế của máy bạn.

Sửa file `/etc/netplan/50-cloud-init.yaml`:

```yaml
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - 192.168.182.195/24
      routes:
        - to: default
          via: 192.168.182.2
      nameservers:
        addresses: [8.8.8.8]
    ens37:
      addresses:
        - 192.168.225.195/24
    ens38:
      addresses:
        - 192.168.147.195/24
```

> **Lưu ý:** Cấu hình này chỉ dùng trong giai đoạn cài đặt ban đầu (Keystone → Glance → Placement → Nova). Khi đến bước cài Neutron (06-neutron.md), `ens33` sẽ được chuyển sang OVS bridge `br-provider` và không còn có IP trực tiếp nữa.

Áp dụng cấu hình:

```bash
netplan apply
```

Kiểm tra kết nối:

```bash
ping -c 4 192.168.182.2
```

```
PING 192.168.182.2 (192.168.182.2) 56(84) bytes of data.
64 bytes from 192.168.182.2: icmp_seq=1 ttl=64 time=0.3 ms
64 bytes from 192.168.182.2: icmp_seq=2 ttl=64 time=0.3 ms
64 bytes from 192.168.182.2: icmp_seq=3 ttl=64 time=0.3 ms
64 bytes from 192.168.182.2: icmp_seq=4 ttl=64 time=0.3 ms
```

### 4.3 Cấu hình hostname

```bash
hostnamectl set-hostname controller
```

Sửa file `/etc/hosts`, thêm nội dung sau:

```
192.168.225.195    controller
192.168.225.196    compute1
```

> Dùng **Management IP** (`192.168.225.x`) cho hostname. Các service OpenStack và Chrony giao tiếp qua Management network, không phải Provider IP (`192.168.182.x`).

### 4.3.1 Cố định DNS - tắt systemd-resolved ghi đè

Sau khi chuyển `ens33` vào OVS bridge, `systemd-resolved` có thể ghi đè `/etc/resolv.conf` về `127.0.0.53` (local DNS). Fix vĩnh viễn:

```bash
# Cấu hình systemd-resolved dùng 8.8.8.8
mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/dns.conf << 'EOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1
DNSStubListener=no
EOF

systemctl restart systemd-resolved

# Trỏ /etc/resolv.conf về file thực thay vì stub
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# Verify
cat /etc/resolv.conf
# Phải thấy nameserver 8.8.8.8
```

Khởi động lại máy:

```bash
reboot
```

### 4.4 Cài đặt NTP (Chrony)

```bash
apt install -y chrony
```

Sửa file `/etc/chrony/chrony.conf`, comment dòng pool mặc định và thêm:

```
# pool ntp.ubuntu.com        <- comment dòng này
server 1.vn.pool.ntp.org iburst
server 0.asia.pool.ntp.org iburst
server 3.asia.pool.ntp.org iburst
allow 192.168.225.0/24
```

```bash
systemctl restart chrony
systemctl enable chrony
```

Kiểm tra:

```bash
chronyc sources
```

```
210 Number of sources = 3
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
^* 1.vn.pool.ntp.org             2   6    17    32    +79us[  -38ms] +/-   60ms
^- 0.asia.pool.ntp.org           2   6    17    31    +73ms[  +73ms] +/-  223ms
```

### 4.5 Cài đặt OpenStack Flamingo repository

```bash
apt install -y software-properties-common
add-apt-repository cloud-archive:flamingo -y
apt update && apt dist-upgrade -y
```

Cài đặt OpenStack client:

```bash
apt install -y python3-openstackclient
```

Khởi động lại máy:

```bash
reboot
```

### 4.6 Cài đặt MariaDB

```bash
apt install -y mariadb-server python3-pymysql
```

Tạo file `/etc/mysql/mariadb.conf.d/99-openstack.cnf`:

```ini
[mysqld]
bind-address = 192.168.225.195

default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
```

```bash
systemctl restart mariadb
systemctl enable mariadb
mysql_secure_installation
```

> Đặt mật khẩu root MariaDB là `Welcome123`, trả lời `Y` cho tất cả câu hỏi còn lại.

### 4.7 Cài đặt RabbitMQ

```bash
apt install -y rabbitmq-server
systemctl enable rabbitmq-server
systemctl start rabbitmq-server
```

Tạo user `openstack`:

```bash
rabbitmqctl add_user openstack Welcome123
rabbitmqctl set_permissions openstack ".*" ".*" ".*"
```

### 4.8 Cài đặt Memcached

```bash
apt install -y memcached python3-memcache
```

Sửa file `/etc/memcached.conf`, tìm dòng `-l 127.0.0.1` và thay thành:

```
-l 192.168.225.195
```

```bash
systemctl restart memcached
systemctl enable memcached
```

### 4.9 Kiểm tra các service nền trên Controller

```bash
systemctl status mariadb rabbitmq-server memcached
```

Tất cả service phải ở trạng thái `active (running)`.

---

## 5. Cài đặt môi trường trên node Compute

### 5.1 Cập nhật hệ thống

```bash
apt update && apt upgrade -y
```

### 5.2 Cấu hình network

Sửa file `/etc/netplan/50-cloud-init.yaml`:

```yaml
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - 192.168.182.196/24
      routes:
        - to: default
          via: 192.168.182.2
      nameservers:
        addresses: [8.8.8.8]
    ens37:
      addresses:
        - 192.168.225.196/24
    ens38:
      addresses:
        - 192.168.147.196/24
```

> **Lưu ý:** Cấu hình này chỉ dùng trong giai đoạn cài đặt ban đầu. Khi đến bước cài Neutron (06-neutron.md), `ens33` sẽ được chuyển sang OVS bridge `br-provider`.

```bash
netplan apply
```

Kiểm tra kết nối:

```bash
ping -c 4 192.168.182.2
```

```
PING 192.168.182.2 (192.168.182.2) 56(84) bytes of data.
64 bytes from 192.168.182.2: icmp_seq=1 ttl=64 time=0.3 ms
64 bytes from 192.168.182.2: icmp_seq=2 ttl=64 time=0.3 ms
64 bytes from 192.168.182.2: icmp_seq=3 ttl=64 time=0.3 ms
64 bytes from 192.168.182.2: icmp_seq=4 ttl=64 time=0.3 ms
```

```bash
ping -c 4 google.com
```

```
PING google.com (142.250.x.x) 56(84) bytes of data.
64 bytes from ...: icmp_seq=1 ttl=54 time=22.3 ms
64 bytes from ...: icmp_seq=2 ttl=54 time=22.3 ms
64 bytes from ...: icmp_seq=3 ttl=54 time=22.3 ms
64 bytes from ...: icmp_seq=4 ttl=54 time=22.3 ms
```

### 5.3 Cấu hình hostname

```bash
hostnamectl set-hostname compute1
```

Sửa file `/etc/hosts`:

```
192.168.225.195    controller
192.168.225.196    compute1
```

Khởi động lại máy:

```bash
reboot
```

### 5.3.1 Cố định DNS - tắt systemd-resolved ghi đè

```bash
mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/dns.conf << 'EOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1
DNSStubListener=no
EOF

systemctl restart systemd-resolved
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
```

### 5.4 Cài đặt NTP (Chrony) - đồng bộ từ Controller

```bash
apt install -y chrony
```

Sửa file `/etc/chrony/chrony.conf`, comment hết các dòng `pool` mặc định và thêm dòng server controller:

```
# pool ntp.ubuntu.com        <- comment dòng này
server controller iburst
```

Xóa các NTP source tự động từ DHCP và sources.d để tránh sync ngoài ý muốn:

```bash
rm -f /run/chrony-dhcp/*
rm -f /etc/chrony/sources.d/*
```

```bash
systemctl restart chrony
systemctl enable chrony
```

Kiểm tra:

```bash
chronyc sources
```

```
210 Number of sources = 1
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
^* controller                    3   6    17    23    -10ns[+6000ns] +/-  248ms
```

### 5.5 Cài đặt OpenStack Flamingo repository

```bash
apt install -y software-properties-common
add-apt-repository cloud-archive:flamingo -y
apt update && apt dist-upgrade -y
apt install -y python3-openstackclient
```

Khởi động lại máy:

```bash
reboot
```

---

Tiếp theo: [02-keystone.md](02-keystone.md)
