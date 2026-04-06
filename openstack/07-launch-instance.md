# Tạo Instance Đầu Tiên

> Thực hiện trên node **Controller**

## Mục lục

1. [Tạo mạng Provider Network](#1-tạo-mạng-provider-network)
2. [Tạo mạng Self-service Network](#2-tạo-mạng-self-service-network)
3. [Tạo Router kết nối 2 mạng](#3-tạo-router-kết-nối-2-mạng)
4. [Tạo Flavor](#4-tạo-flavor)
5. [Tạo Security Group](#5-tạo-security-group)
6. [Tạo SSH Key Pair](#6-tạo-ssh-key-pair)
7. [Tạo Instance](#7-tạo-instance)
8. [Kiểm tra và truy cập Instance](#8-kiểm-tra-và-truy-cập-instance)

---

## 1. Tạo mạng Provider Network

Chạy script biến môi trường với quyền admin:

```bash
source ~/admin-openrc
```

Tạo provider network (external network):

```bash
openstack network create --share --external \
  --provider-physical-network provider \
  --provider-network-type flat \
  provider-net
```

Tạo subnet cho provider network:

```bash
openstack subnet create \
  --network provider-net \
  --allocation-pool start=192.168.182.100,end=192.168.182.150 \
  --dns-nameserver 8.8.8.8 \
  --gateway 192.168.182.2 \
  --subnet-range 192.168.182.0/24 \
  provider-subnet
```

> Lưu ý: Kiểm tra dải DHCP của VMnet8 trong **VMware → Virtual Network Editor → VMnet8 → DHCP Settings** để tránh trùng IP. Mặc định VMware cấp DHCP từ `.128-.254`, nên dùng dải `.100-.150` là an toàn. Các IP `.195` và `.196` đang dùng cho controller và compute phải nằm ngoài `allocation-pool`.

---

## 2. Tạo mạng Self-service Network

Chuyển sang biến môi trường của user demo:

```bash
source ~/demo-openrc
```

Tạo self-service network (tenant network):

```bash
openstack network create selfservice-net
```

Tạo subnet cho self-service network:

```bash
openstack subnet create \
  --network selfservice-net \
  --dns-nameserver 8.8.8.8 \
  --gateway 192.168.100.1 \
  --subnet-range 192.168.100.0/24 \
  selfservice-subnet
```

---

## 3. Tạo Router kết nối 2 mạng

```bash
openstack router create router1
```

Gán self-service subnet vào router:

```bash
openstack router add subnet router1 selfservice-subnet
```

Gán provider network làm external gateway cho router:

```bash
openstack router set router1 --external-gateway provider-net
```
Kiểm tra router:

```bash
openstack router show router1
```

---

## 4. Tạo Flavor

Chạy với quyền admin:

```bash
source ~/admin-openrc
```

```bash
openstack flavor create --id 1 --vcpus 1 --ram 512  --disk 1  m1.tiny
openstack flavor create --id 2 --vcpus 1 --ram 2048 --disk 20 m1.small
openstack flavor create --id 3 --vcpus 2 --ram 4096 --disk 40 m1.medium
```

Kiểm tra:

```bash
openstack flavor list
```

Kết quả mong đợi:

```
+----+-----------+-------+------+-----------+-------+-----------+
| ID | Name      |   RAM | Disk | Ephemeral | VCPUs | Is Public |
+----+-----------+-------+------+-----------+-------+-----------+
|  1 | m1.tiny   |   512 |    1 |         0 |     1 | True      |
|  2 | m1.small  |  2048 |   20 |         0 |     1 | True      |
|  3 | m1.medium |  4096 |   40 |         0 |     2 | True      |
+----+-----------+-------+------+-----------+-------+-----------+
```

---

## 5. Tạo Security Group

Chuyển sang user demo:

```bash
source ~/demo-openrc
```

Tạo security group:

```bash
openstack security group create --description "Allow SSH and ICMP" my-sg
```

Thêm rule cho phép SSH (port 22):

```bash
openstack security group rule create --proto tcp --dst-port 22 my-sg
```

Thêm rule cho phép ICMP (ping):

```bash
openstack security group rule create --proto icmp my-sg
```

Kiểm tra:

```bash
openstack security group rule list my-sg
```

---

## 6. Tạo SSH Key Pair

```bash
ssh-keygen -q -N "" -f ~/demo-key
openstack keypair create --public-key ~/demo-key.pub demo-key
```

Kiểm tra:

```bash
openstack keypair list
```

Kết quả mong đợi:

```
+----------+-------------------------------------------------+------+
| Name     | Fingerprint                                     | Type |
+----------+-------------------------------------------------+------+
| demo-key | xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx | ssh  |
+----------+-------------------------------------------------+------+
```

---

## 7. Tạo Instance

Nếu có instance lỗi từ lần trước, xóa đi trước:

```bash
openstack server list --all-projects
openstack server delete <instance-id-loi>
```

Kiểm tra các thành phần trước khi tạo:

```bash
openstack image list
openstack flavor list
openstack network list
openstack security group list
```

Lấy ID của selfservice network (dùng ID thay vì tên để tránh nhầm lẫn):

```bash
openstack network list
# Ghi lại ID của selfservice-net
```

Tạo instance trên **self-service network**:

```bash
openstack server create \
  --flavor m1.tiny \
  --image cirros \
  --nic net-id=<SELFSERVICE_NET_ID> \
  --security-group my-sg \
  --key-name demo-key \
  my-first-instance
```

---

## 8. Kiểm tra và truy cập Instance

Kiểm tra trạng thái instance:

```bash
openstack server list
```

Kết quả mong đợi (chờ đến khi status là `ACTIVE`):

```
+--------------------------------------+-------------------+--------+-------------------------------+--------+---------+
| ID                                   | Name              | Status | Networks                      | Image  | Flavor  |
+--------------------------------------+-------------------+--------+-------------------------------+--------+---------+
| 1a2b3c4d-...                         | my-first-instance | ACTIVE | selfservice-net=192.168.100.x | cirros | m1.tiny |
+--------------------------------------+-------------------+--------+-------------------------------+--------+---------+
```

### Truy cập qua VNC Console

```bash
openstack console url show my-first-instance
```

Mở URL trả về trong trình duyệt. Thông tin đăng nhập mặc định của Cirros:
- Username: `cirros`
- Password: `gocubsgo`

Sau khi login, verify network từ bên trong instance:

```bash
# Ping gateway của self-service network
ping -c 4 192.168.100.1

# Ping ra internet
ping -c 4 8.8.8.8
```

### Gán Floating IP để truy cập từ bên ngoài

```bash
# Tạo floating IP từ provider network
openstack floating ip create provider-net

# Gán floating IP cho instance
openstack server add floating ip my-first-instance <FLOATING_IP>
```

Kiểm tra:

```bash
openstack server show my-first-instance
```

SSH vào instance:

```bash
ssh -i ~/demo-key cirros@<FLOATING_IP>
```

> Floating IP sẽ thuộc dải `192.168.182.100-150`. Vì VMnet8 là NAT, bạn có thể truy cập floating IP này từ máy tính Windows host.

### Xem log console (debug khi instance không boot được)

```bash
openstack console log show my-first-instance
```

---

## Tóm tắt thứ tự cài đặt

```
01-environment-prepare  →  Chuẩn bị môi trường (Controller + Compute)
02-keystone             →  Identity Service (Controller)
03-glance               →  Image Service (Controller)
04-placement            →  Placement API (Controller)
05-nova                 →  Compute Service (Controller + Compute)
06-neutron              →  Networking Service (Controller + Compute)
07-launch-instance      →  Tạo instance đầu tiên ✓
```

---

Trước: [06-neutron.md](06-neutron.md) | Tiếp theo: [08-horizon.md](08-horizon.md)
