# Glance - Deep Dive

## Glance là gì?

Glance là Image Service của OpenStack - quản lý **disk image** dùng để boot VM. Glance không lưu trữ image trực tiếp mà là lớp trung gian giữa user và storage backend.

## Kiến trúc

```
User/Nova
    │
    │ REST API (port 9292)
    ▼
glance-api
    │
    ├── glance-registry (deprecated từ Stein, tích hợp vào api)
    │
    ├── Database (MariaDB)
    │   └── image metadata: name, format, size, checksum, owner...
    │   (KHÔNG lưu file image)
    │
    └── Storage Backend
        ├── file    ← /var/lib/glance/images/ (lab)
        ├── swift   ← Object Storage
        ├── rbd     ← Ceph (production)
        ├── cinder  ← Block Storage
        └── http    ← URL trực tiếp
```

## Image Format

**Disk format** - định dạng file image:

| Format | Mô tả | Dùng khi |
|---|---|---|
| `qcow2` | QEMU Copy-On-Write v2 | KVM/QEMU, hỗ trợ snapshot, thin provisioning |
| `raw` | Raw disk image | Hiệu năng cao nhất, không có overhead |
| `vmdk` | VMware | Import từ VMware |
| `vhd` | Hyper-V | Import từ Hyper-V |
| `iso` | CD/DVD image | Boot từ ISO |

**Container format** - metadata wrapper:

| Format | Mô tả |
|---|---|
| `bare` | Không có container, chỉ có disk image (dùng phổ biến nhất) |
| `ovf` | Open Virtualization Format |
| `ova` | OVA archive |

## Cấu hình Backend mới (Flamingo)

Từ OpenStack Ussuri, cấu hình backend dùng `enabled_backends` thay vì `stores`:

```ini
[DEFAULT]
enabled_backends = fs:file    # tên_backend:loại_backend

[glance_store]
default_backend = fs          # backend mặc định

[fs]                          # section riêng cho backend "fs"
filesystem_store_datadir = /var/lib/glance/images/
```

Cú pháp `tên:loại` cho phép định nghĩa nhiều backend cùng loại:

```ini
[DEFAULT]
enabled_backends = fast:rbd,slow:file

[glance_store]
default_backend = fast

[fast]
rbd_store_pool = images_fast
rbd_store_ceph_conf = /etc/ceph/ceph.conf

[slow]
filesystem_store_datadir = /var/lib/glance/images/
```

## oslo_limit và Quota

Từ Flamingo, Glance dùng `oslo_limit` để enforce quota qua Keystone:

```ini
[oslo_limit]
auth_url = http://controller:5000
auth_type = password
username = glance
system_scope = all
password = Welcome123
endpoint_id = <ENDPOINT_ID>
region_name = RegionOne
```

Quota được đăng ký trong Keystone:

```bash
# Đăng ký quota limits
openstack registered limit create \
  --service glance --default-limit 1000 --region RegionOne image_size_total

# Xem quota của project
openstack limit list --service glance
```

Các loại quota:
- `image_size_total`: tổng dung lượng image (MiB)
- `image_stage_total`: dung lượng image đang upload
- `image_count_total`: số lượng image
- `image_count_uploading`: số image đang upload đồng thời

## Luồng upload image

```
User upload image:
  POST /v2/images          → tạo image record trong DB (status: queued)
  PUT /v2/images/{id}/file → upload binary data

Glance xử lý:
  1. Nhận data stream
  2. Tính checksum (MD5/SHA256)
  3. Lưu vào storage backend
  4. Cập nhật DB: status = active, size, checksum

Nova boot VM:
  1. Nova gọi Glance: GET /v2/images/{id}/file
  2. Glance stream image từ backend
  3. Nova compute download về local cache
  4. libvirt tạo VM từ image
```

## Image Visibility

```
public    → tất cả project đều thấy và dùng được
private   → chỉ owner project thấy (mặc định)
shared    → owner chia sẻ với project cụ thể
community → tất cả thấy nhưng không phải official
```

```bash
# Upload image public
openstack image create "ubuntu-24.04" \
  --file ubuntu-24.04-server-cloudimg-amd64.img \
  --disk-format qcow2 --container-format bare \
  --public

# Chia sẻ image với project khác
openstack image add project <image-id> <project-id>
openstack image set --shared <image-id>
```

## Image Cache

Nova compute có local image cache tại `/var/lib/nova/instances/_base/`. Khi boot VM:
1. Kiểm tra cache có image chưa
2. Nếu chưa → download từ Glance → lưu cache
3. Tạo VM từ cached image (copy-on-write với qcow2)

## Debug

```bash
# Xem log
tail -f /var/log/glance/glance-api.log

# Kiểm tra image trong storage
ls -lh /var/lib/glance/images/

# Kiểm tra DB
mysql -u glance -pWelcome123 glance -e "SELECT id, name, status, size FROM images\G"

# Verify checksum
openstack image show cirros -f value -c checksum
md5sum /var/lib/glance/images/<image-file>

# Xem image detail
openstack image show <image-id>
openstack image list --long
```
