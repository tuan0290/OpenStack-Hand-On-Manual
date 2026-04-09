# Lab 04: OSD Management

> Mục tiêu: Quản lý vòng đời OSD - add, remove, reweight, và xử lý OSD fail.

---

## 1. OSD Status và Info

```bash
# Trạng thái tất cả OSD
ceph osd stat
ceph osd dump

# Chi tiết từng OSD
ceph osd find 0        # tìm OSD 0 ở host nào
ceph osd metadata 0    # metadata của OSD 0

# Disk usage
ceph osd df
ceph osd df tree       # theo topology
```

---

## 2. Reweight OSD

Reweight điều chỉnh lượng data một OSD nhận mà không thay đổi CRUSH map.

```bash
# Xem weight hiện tại
ceph osd tree

# Giảm weight OSD 0 xuống 0.5 (nhận ít data hơn)
ceph osd reweight 0 0.5

# Theo dõi data di chuyển
watch ceph status

# Khôi phục về 1.0
ceph osd reweight 0 1.0

# Reweight tự động dựa trên usage (cân bằng cluster)
ceph osd reweight-by-utilization
```

---

## 3. Mark OSD out/in

```bash
# Mark OSD 0 out (data sẽ migrate sang OSD khác)
ceph osd out 0

# Theo dõi recovery
watch ceph status
# Sẽ thấy: recovery io, degraded objects

# Mark OSD 0 in lại
ceph osd in 0

# Chờ rebalance xong
watch ceph status
```

---

## 4. Simulate OSD Failure

```bash
# Stop OSD daemon trên ceph-osd1
ssh root@ceph-osd1 "systemctl stop ceph-osd@0"

# Quan sát cluster phản ứng
watch ceph status
# Sẽ thấy: HEALTH_WARN, osd.0 down

# Sau ~10 phút OSD sẽ bị mark out và recovery bắt đầu
# Hoặc force out ngay:
ceph osd out 0

# Theo dõi recovery
ceph -w

# Khôi phục
ssh root@ceph-osd1 "systemctl start ceph-osd@0"
ceph osd in 0
watch ceph status
```

---

## 5. Scrub và Deep Scrub

Scrub kiểm tra data integrity của PG.

```bash
# Scrub tất cả PG (nhẹ - chỉ check metadata)
ceph osd scrub 0        # scrub OSD 0
ceph pg scrub 1.0       # scrub PG cụ thể

# Deep scrub (nặng hơn - check cả data)
ceph osd deep-scrub 0
ceph pg deep-scrub 1.0

# Xem scrub status
ceph pg dump | grep scrub

# Xem PG đang scrub
ceph status | grep scrub
```

---

## 6. OSD Blacklist (Block List)

```bash
# Xem blacklist
ceph osd blocklist ls

# Add IP vào blacklist (block client)
ceph osd blocklist add 192.168.225.196:0/0

# Remove khỏi blacklist
ceph osd blocklist rm 192.168.225.196:0/0

# Clear toàn bộ blacklist
ceph osd blocklist clear
```

---

## 7. Thêm OSD mới (nếu có disk mới)

```bash
# Kiểm tra disk available
ceph orch device ls --refresh

# Thêm OSD từ disk cụ thể
ceph orch daemon add osd ceph-osd1:/dev/sdc

# Verify
ceph osd tree
watch ceph status
```

---

## Bài tập

1. Reweight OSD 1 xuống 0.7, quan sát data rebalance, khôi phục về 1.0
2. Stop OSD 0, quan sát cluster health thay đổi như thế nào
3. Start lại OSD 0, quan sát recovery process
4. Chạy scrub trên OSD 0 và xem kết quả
