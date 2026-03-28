# Cài đặt dịch vụ Image (Glance)

> Cài đặt trên node **Controller**

## Mục lục

1. [Tạo database cho Glance](#1-tạo-database-cho-glance)
2. [Tạo user, service và endpoint API](#2-tạo-user-service-và-endpoint-api)
3. [Cài đặt và cấu hình Glance](#3-cài-đặt-và-cấu-hình-glance)
4. [Kết thúc cài đặt](#4-kết-thúc-cài-đặt)
5. [Kiểm tra cài đặt Glance](#5-kiểm-tra-cài-đặt-glance)

---

## 1. Tạo database cho Glance

Đăng nhập vào MariaDB:

```bash
mysql -u root -pWelcome123
```

Tạo database và cấp quyền:

```sql
CREATE DATABASE glance;
CREATE USER 'glance'@'localhost' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost';
CREATE USER 'glance'@'%' IDENTIFIED BY 'Welcome123';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%';
FLUSH PRIVILEGES;
EXIT;
```

---

## 2. Tạo user, service và endpoint API

Chạy script biến môi trường:

```bash
source ~/admin-openrc
```

Tạo user `glance`:

```bash
openstack user create --domain default --password Welcome123 glance
```

Kết quả:

```
+---------------------+----------------------------------+
| Field               | Value                            |
+---------------------+----------------------------------+
| domain_id           | default                          |
| enabled             | True                             |
| id                  | 119d2cad45584585b5bf9ef799cbfbfa |
| name                | glance                           |
| options             | {}                               |
| password_expires_at | None                             |
+---------------------+----------------------------------+
```

Gán role `admin` cho user `glance` trên project `service`:

```bash
openstack role add --project service --user glance admin
```

Tạo service entity:

```bash
openstack service create --name glance --description "OpenStack Image" image
```

Kết quả:

```
+-------------+----------------------------------+
| Field       | Value                            |
+-------------+----------------------------------+
| description | OpenStack Image                  |
| enabled     | True                             |
| id          | 5ef6ca4ca183461eb2bb64b3c406a839 |
| name        | glance                           |
| type        | image                            |
+-------------+----------------------------------+
```

Tạo các endpoint API:

```bash
openstack endpoint create --region RegionOne image public http://controller:9292
openstack endpoint create --region RegionOne image internal http://controller:9292
openstack endpoint create --region RegionOne image admin http://controller:9292
```

---

## 3. Cài đặt và cấu hình Glance

Cài đặt gói:

```bash
apt install -y glance
```

Sao lưu file cấu hình gốc:

```bash
cp /etc/glance/glance-api.conf /etc/glance/glance-api.conf.orig
```

Sửa file `/etc/glance/glance-api.conf`, cấu hình các section sau:

Trong section `[database]`:

```ini
[database]
connection = mysql+pymysql://glance:Welcome123@controller/glance
```

Trong section `[DEFAULT]`:

```ini
[DEFAULT]
enabled_backends = fs:file
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
username = glance
password = Welcome123
```

Trong section `[paste_deploy]`:

```ini
[paste_deploy]
flavor = keystone
```

Trong section `[glance_store]`:

```ini
[glance_store]
default_backend = fs
```

Thêm section `[fs]` mới (chưa có sẵn trong file):

```ini
[fs]
filesystem_store_datadir = /var/lib/glance/images/
```

Lấy endpoint ID của glance để cấu hình oslo_limit:

```bash
openstack endpoint list --service glance --region RegionOne
```

Ghi lại ID của endpoint `public`, sau đó cấu hình section `[oslo_limit]`:

```ini
[oslo_limit]
auth_url = http://controller:5000
auth_type = password
user_domain_id = default
username = glance
system_scope = all
password = Welcome123
endpoint_id = <ENDPOINT_ID_PUBLIC>
region_name = RegionOne
```

Gán role `reader` system-scope cho user glance:

```bash
openstack role add --user glance --user-domain Default --system all reader
```

Đồng bộ database cho Glance:

```bash
su -s /bin/sh -c "glance-manage db_sync" glance
```

> Bỏ qua các deprecation warning nếu có.

---

## 4. Kết thúc cài đặt

Restart dịch vụ Glance:

```bash
systemctl restart glance-api
systemctl enable glance-api
```

---

## 5. Kiểm tra cài đặt Glance

Chạy script biến môi trường:

```bash
source ~/admin-openrc
```

Tải image Cirros (image nhỏ gọn dùng để test):

```bash
wget http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img
```

Upload image lên Glance:

```bash
openstack image create "cirros" \
  --file cirros-0.6.2-x86_64-disk.img \
  --disk-format qcow2 \
  --container-format bare \
  --public
```

Kiểm tra image đã upload:

```bash
openstack image list
```

Kết quả mong đợi:

```
+--------------------------------------+--------+--------+
| ID                                   | Name   | Status |
+--------------------------------------+--------+--------+
| 9b989c67-57a3-4f7d-88d0-d4137aa0a7fa | cirros | active |
+--------------------------------------+--------+--------+
```

Nếu kết quả như trên là đã cài đặt Glance thành công.

---

Trước: [02-keystone.md](02-keystone.md) | Tiếp theo: [04-placement.md](04-placement.md)

---

## Hỏi & Đáp

### `openstack service create` tạo ra cái gì?

Lệnh này đăng ký Glance vào **Service Catalog** của Keystone - hiểu đơn giản là danh bạ điện thoại của OpenStack.

Khi Nova cần lấy image, nó không hardcode địa chỉ Glance mà hỏi Keystone: "service tên `glance`, type `image` đang ở đâu?" → Keystone tra catalog trả về URL.

```
openstack service create --name glance --description "OpenStack Image" image
                              │                                          │
                           tên service                               type/loại
                           (dùng để tìm kiếm)                    (chuẩn OpenStack)
```

Sau lệnh này catalog có thêm 1 entry:

```
Service Catalog (lưu trong Keystone DB)
┌──────────────┬──────────┬──────────────────────────────┐
│ name         │ type     │ endpoints                     │
├──────────────┼──────────┼──────────────────────────────┤
│ keystone     │ identity │ http://controller:5000/v3     │
│ glance       │ image    │ http://controller:9292        │ ← vừa tạo
│ nova         │ compute  │ http://controller:8774/v2.1   │
│ neutron      │ network  │ http://controller:9696        │
└──────────────┴──────────┴──────────────────────────────┘
```

Endpoint được tạo ở bước tiếp theo (`openstack endpoint create`) mới điền URL thực tế vào. Bước `service create` chỉ tạo "cái tên" trước.

---

### Tạo endpoint API có ý nghĩa gì?

Mỗi service trong OpenStack có 3 endpoint với 3 vai trò khác nhau:

```
openstack endpoint create --region RegionOne image public http://controller:9292
                               │              │      │         │
                            khu vực        loại  interface   URL thực tế
                           (RegionOne)   service  (public)
```

**3 interface:**

```
┌──────────┬─────────────────────────────────────────────────────┐
│ public   │ Dành cho client bên ngoài (user, CLI, Horizon)      │
│          │ Trong production dùng domain/IP public              │
├──────────┼─────────────────────────────────────────────────────┤
│ internal │ Dành cho các service OpenStack gọi nhau nội bộ      │
│          │ (Nova gọi Glance, Neutron gọi Keystone...)          │
├──────────┼─────────────────────────────────────────────────────┤
│ admin    │ Dành cho tác vụ quản trị đặc biệt                   │
│          │ Một số API chỉ admin endpoint mới có                │
└──────────┴─────────────────────────────────────────────────────┘
```

Trong lab này cả 3 đều trỏ cùng 1 URL `http://controller:9292` vì chỉ có 1 node controller. Trong production thực tế sẽ khác nhau:

```
public   → https://glance.mycloud.com:9292      (internet)
internal → http://192.168.225.195:9292           (management network)
admin    → http://192.168.225.195:9292           (management network)
```

**Tại sao cần region?**

`--region RegionOne` cho phép 1 OpenStack deployment có nhiều vùng địa lý (RegionOne, RegionTwo...), mỗi region có bộ service riêng. Khi user chọn region, Keystone trả về endpoint đúng region đó.

---

### Cấu hình region như thế nào và làm sao kiểm tra?

Region được tạo tự động khi chạy `keystone-manage bootstrap --bootstrap-region-id RegionOne`, không cần cấu hình riêng.

**Xem các region đang có:**

```bash
openstack region list
```

**Xem tất cả endpoint theo region:**

```bash
openstack endpoint list
openstack endpoint list --service glance
openstack endpoint list --region RegionOne
```

**Nếu muốn thêm region mới** (multi-region deployment):

```bash
# Tạo region mới
openstack region create RegionTwo

# Đăng ký endpoint của service ở region mới
openstack endpoint create --region RegionTwo \
  image public http://glance-region2.mycloud.com:9292
```

**Chỉ định region khi dùng CLI:**

```bash
openstack --os-region-name RegionTwo image list
```

Hoặc thêm vào file `~/admin-openrc`:

```bash
export OS_REGION_NAME=RegionOne
```

Trong lab này chỉ có 1 region `RegionOne`. Multi-region thường dùng khi có datacenter ở nhiều nơi địa lý khác nhau.

---

### Region có phải là khu vực chứa image hay VM không?

Không. Region là **toàn bộ một deployment OpenStack độc lập** ở một địa điểm địa lý, bao gồm tất cả service.

```
Công ty có 2 datacenter:

RegionOne (Hà Nội)              RegionTwo (TP.HCM)
┌─────────────────────┐         ┌─────────────────────┐
│ Keystone            │         │ Keystone            │
│ Glance  ← image HN  │         │ Glance  ← image HCM │
│ Nova    ← VM HN     │         │ Nova    ← VM HCM    │
│ Neutron             │         │ Neutron             │
└─────────────────────┘         └─────────────────────┘
         │                               │
         └──────── Keystone chung ────────┘
                  (1 nơi auth duy nhất)
```

- Image upload lên RegionOne thì chỉ dùng được ở RegionOne
- VM tạo ở RegionTwo thì chạy trên compute node ở RegionTwo
- Chỉ có authentication là dùng chung 1 Keystone

**Khái niệm gần hơn với "khu vực chứa VM"** trong cùng 1 region là **Availability Zone (AZ)** - phân vùng các compute node trong cùng 1 datacenter:

```
RegionOne
├── AZ: nova (mặc định)
│   ├── compute1
│   └── compute2
├── AZ: az-rack2
│   ├── compute3
│   └── compute4
```

Tạo VM chỉ định AZ:

```bash
openstack server create --availability-zone az-rack2 ...
```

---

### Cấu hình `[glance_store]` có ý nghĩa gì?

```ini
[DEFAULT]
enabled_backends = fs:file   # khai báo backend tên "fs", loại "file"

[glance_store]
default_backend = fs         # dùng backend "fs" làm mặc định khi upload image

[fs]                         # section cấu hình riêng cho backend tên "fs"
filesystem_store_datadir = /var/lib/glance/images/   # thư mục lưu file image
```

Cú pháp `enabled_backends = fs:file` theo dạng `tên:loại`:
- `tên` (fs) - tự đặt, dùng để tham chiếu ở `default_backend`
- `loại` (file) - loại backend, có thể là `file`, `swift`, `rbd` (Ceph)...

Trong production thường dùng `rbd` (Ceph) thay vì `file` để có tính HA và scale được.
