# Lab 07: Failure Simulation và Recovery

> Mục tiêu: Hiểu cách Ceph phản ứng khi có sự cố và cách recovery.

---

## 1. OSD Failure Simulation

### Scenario: OSD bị down đột ngột

```bash
# Trạng thái ban đầu
ceph status
ceph osd tree

# Ghi data trước khi simulate failure
rados bench -p volumes 30 write --no-cleanup &
BENCH_PID=$!

# Stop OSD 0 đột ngột (simulate crash)
ssh root@ceph-osd1 "systemctl stop ceph-osd@0"

# Quan sát cluster phản ứng ngay lập tức
watch ceph status
# Sẽ thấy:
# health: HEALTH_WARN
# osd.0 is down
# Degraded data: x% (x/x objects degraded)

# Sau ~10 phút (mon_osd_down_out_interval=600s)
# OSD sẽ bị mark OUT và recovery bắt đầu
# Hoặc force out ngay:
ceph osd out 0

# Theo dõi recovery
ceph -w
# Sẽ thấy: recovery_io, misplaced objects đang được di chuyển

# Dừng benchmark
kill $BENCH_PID 2>/dev/null
```

### Recovery

```bash
# Khởi động lại OSD
ssh root@ceph-osd1 "systemctl start ceph-osd@0"

# Mark OSD in
ceph osd in 0

# Theo dõi backfill
watch ceph status
# Sẽ thấy: backfilling, recovering

# Chờ HEALTH_OK
```

---

## 2. Network Partition Simulation

```bash
# Block traffic từ ceph-osd1 đến ceph-osd2 (cluster network)
ssh root@ceph-osd1 "iptables -I INPUT -s 192.168.147.204 -j DROP"
ssh root@ceph-osd1 "iptables -I OUTPUT -d 192.168.147.204 -j DROP"

# Quan sát
watch ceph status
# OSD sẽ báo slow ops, peering issues

# Restore
ssh root@ceph-osd1 "iptables -D INPUT -s 192.168.147.204 -j DROP"
ssh root@ceph-osd1 "iptables -D OUTPUT -d 192.168.147.204 -j DROP"
```

---

## 3. Full OSD Simulation

```bash
# Set nearfull ratio thấp để trigger warning
ceph config set global mon_osd_nearfull_ratio 0.01

# Xem warning
ceph health detail
# HEALTH_WARN: x nearfull osd(s)

# Reset
ceph config rm global mon_osd_nearfull_ratio
```

---

## 4. MON Failure (nếu có nhiều MON)

```bash
# Với lab 1 MON, chỉ xem - không thực hiện
# Với 3 MON cluster:
# ceph mon remove ceph-mon2
# → cluster vẫn hoạt động với 2/3 MON (quorum)
# ceph mon remove ceph-mon3
# → cluster mất quorum, KHÔNG thể write

# Xem quorum hiện tại
ceph quorum_status
```

---

## 5. Data Integrity Check

```bash
# Tạo object với checksum đã biết
echo "test data for integrity check" | md5sum
echo "test data for integrity check" > /tmp/test-integrity.txt
rados -p volumes put integrity-test /tmp/test-integrity.txt

# Verify object
rados -p volumes get integrity-test /tmp/integrity-output.txt
md5sum /tmp/integrity-output.txt
# Phải match với checksum ban đầu

# Force scrub để check integrity
ceph pg scrub $(ceph osd map volumes integrity-test | grep -oP 'pg \K[\d.]+')

# Xem scrub errors
ceph health detail | grep scrub
```

---

## 6. Recovery Tuning

```bash
# Xem recovery settings
ceph config get osd osd_recovery_max_active
ceph config get osd osd_recovery_op_priority
ceph config get osd osd_backfill_scan_max

# Tăng tốc recovery (dùng nhiều resource hơn)
ceph config set osd osd_recovery_max_active 5
ceph config set osd osd_recovery_op_priority 10

# Giảm tốc recovery (ưu tiên client IO)
ceph config set osd osd_recovery_max_active 1
ceph config set osd osd_recovery_op_priority 3

# Reset về default
ceph config rm osd osd_recovery_max_active
ceph config rm osd osd_recovery_op_priority
```

---

## Bài tập

1. Stop OSD 0, quan sát health thay đổi từng bước
2. Đo thời gian từ khi OSD down đến khi recovery hoàn tất
3. Trong khi OSD down, thử đọc/ghi data - có hoạt động không?
4. Tăng recovery speed, stop/start OSD lại và so sánh thời gian recovery
