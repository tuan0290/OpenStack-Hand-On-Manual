# CephX Authentication

> Hiểu cách Ceph xác thực client - quan trọng khi tích hợp với OpenStack.

## 1. CephX là gì?

CephX là hệ thống authentication của Ceph, dựa trên **shared secret key** (giống Kerberos).

```
Không có CephX:                 Có CephX:
Bất kỳ ai cũng mount được       Chỉ client có key mới kết nối được
→ Không an toàn                 → Mỗi service có key riêng, quyền riêng
```

---

## 2. Keyring File

Mỗi user Ceph có 1 keyring file:

```ini
# /etc/ceph/ceph.client.glance.keyring
[client.glance]
    key = AQBREtdpfbWGNBAAM88++mq8xzplH1OuugRnzA==
```

**Cấu trúc tên user:** `<type>.<name>`
- `client.admin` - admin user (full access)
- `client.glance` - Glance service user
- `client.cinder` - Cinder service user
- `client.nova` - Nova service user

---

## 3. Capabilities (Quyền hạn)

Mỗi user có capabilities cho từng service:

```bash
# Xem capabilities của user
ceph auth get client.glance
```

Output:
```
[client.glance]
    key = AQB...==
    caps mon = "profile rbd"
    caps osd = "profile rbd pool=images"
    caps mgr = "profile rbd pool=images"
```

**Giải thích:**
- `caps mon` - quyền trên MON (auth, cluster map)
- `caps osd` - quyền trên OSD (read/write pools)
- `caps mgr` - quyền trên MGR (metrics, orchestration)

**Các profile phổ biến:**

| Profile | Quyền |
|---|---|
| `profile rbd` | Full RBD access trên pool |
| `profile rbd-read-only` | Chỉ đọc RBD |
| `allow r` | Chỉ đọc |
| `allow rw` | Đọc và ghi |
| `allow *` | Full access (chỉ dùng cho admin) |

---

## 4. Luồng Authentication

```
1. Client (Glance) muốn ghi image vào pool "images"

2. Client gửi request đến MON:
   "Tôi là client.glance, đây là key của tôi"

3. MON verify key:
   - Tìm client.glance trong auth database
   - So sánh key
   - Kiểm tra capabilities

4. MON cấp session ticket (có thời hạn)

5. Client dùng ticket giao tiếp trực tiếp với OSD
   (không cần hỏi MON cho mỗi request)

6. OSD verify ticket → cho phép ghi vào pool "images"
```

---

## 5. Quản lý Users

```bash
# Tạo user mới
ceph auth get-or-create client.myapp \
  mon 'profile rbd' \
  osd 'profile rbd pool=mypool'

# Xem tất cả users
ceph auth ls

# Xem user cụ thể
ceph auth get client.glance

# Lấy key của user
ceph auth get-key client.glance

# Xóa user
ceph auth del client.myapp

# Export keyring ra file
ceph auth get client.glance > /etc/ceph/ceph.client.glance.keyring
```

---

## 6. Tại sao Nova cần 2 secrets?

Khi tích hợp với OpenStack, Nova cần 2 libvirt secrets:

```
client.cinder secret:
  → QEMU dùng để attach Cinder volume (RBD volume từ pool "volumes")
  → Cần quyền: rw pool=volumes

client.nova secret:
  → QEMU dùng để boot VM từ Ceph (ephemeral disk từ pool "vms")
  → Cần quyền: rw pool=vms

Nếu dùng chung 1 secret:
  → QEMU không biết dùng key nào cho pool nào
  → Permission denied
```

---

## 7. Rotate Key (Đổi key)

```bash
# Tạo key mới cho user (key cũ vẫn còn hiệu lực cho đến khi xóa)
ceph auth get-or-create client.glance \
  mon 'profile rbd' \
  osd 'profile rbd pool=images'

# Cập nhật keyring file
ceph auth get client.glance > /etc/ceph/ceph.client.glance.keyring

# Copy sang controller
scp /etc/ceph/ceph.client.glance.keyring root@controller:/etc/ceph/

# Restart Glance
systemctl restart glance-api
```
