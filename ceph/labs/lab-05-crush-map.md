# Lab 05: CRUSH Map

> Mục tiêu: Hiểu và tùy chỉnh CRUSH map để kiểm soát data placement.

---

## 1. Xem CRUSH Map hiện tại

```bash
# Dump CRUSH map dạng binary
ceph osd getcrushmap -o /tmp/crushmap.bin

# Decompile sang text
crushtool -d /tmp/crushmap.bin -o /tmp/crushmap.txt

# Xem nội dung
cat /tmp/crushmap.txt
```

Cấu trúc CRUSH map:
```
# devices - các OSD
device 0 osd.0 class hdd
device 1 osd.1 class hdd

# types - các loại bucket
type 0 osd
type 1 host
type 2 chassis
type 3 rack
type 4 row
type 5 pdu
type 6 pod
type 7 room
type 8 datacenter
type 9 zone
type 10 region
type 11 root

# buckets - topology
host ceph-osd1 {
    id -3
    item osd.0 weight 0.049
}
host ceph-osd2 {
    id -5
    item osd.1 weight 0.049
}
root default {
    id -1
    item ceph-osd1 weight 0.049
    item ceph-osd2 weight 0.049
}

# rules - cách chọn OSD
rule replicated_rule {
    id 0
    type replicated
    step take default
    step chooseleaf firstn 0 type host
    step emit
}
```

---

## 2. Device Classes (HDD/SSD/NVMe)

```bash
# Xem class của từng OSD
ceph osd tree | grep -E "hdd|ssd|nvme"

# Set class thủ công
ceph osd crush set-device-class ssd osd.0
ceph osd crush set-device-class hdd osd.1

# Xem class
ceph osd crush class ls
ceph osd crush class ls-osd hdd

# Tạo rule chỉ dùng SSD
ceph osd crush rule create-replicated ssd-rule default host ssd

# Tạo pool dùng rule đó
ceph osd pool create fast-pool 32 32 replicated ssd-rule
```

---

## 3. Tùy chỉnh CRUSH Map

Thêm rack level để data không bị đặt trên cùng 1 rack:

```bash
# Edit crushmap
cat /tmp/crushmap.txt

# Thêm rack buckets
cat >> /tmp/crushmap-new.txt << 'EOF'
rack rack1 {
    id -10
    item ceph-osd1 weight 0.049
}
rack rack2 {
    id -11
    item ceph-osd2 weight 0.049
}
root default {
    id -1
    item rack1 weight 0.049
    item rack2 weight 0.049
}
EOF

# Compile và apply
crushtool -c /tmp/crushmap-new.txt -o /tmp/crushmap-new.bin
ceph osd setcrushmap -i /tmp/crushmap-new.bin

# Verify
ceph osd tree
```

---

## 4. CRUSH Rule

```bash
# List rules
ceph osd crush rule ls
ceph osd crush rule dump

# Tạo rule mới - replicate across rack
ceph osd crush rule create-replicated rack-rule default rack hdd

# Assign rule cho pool
ceph osd pool set volumes crush_rule rack-rule

# Verify data placement
ceph osd map volumes test-object
# Output: osdmap e... pool 'volumes' (x) object 'test-object' -> pg x.xxx (x osds: [0,1])
```

---

## 5. Test Data Placement

```bash
# Xem PG nào chứa object cụ thể
ceph osd map volumes my-object

# Xem tất cả PG của pool và OSD chứa chúng
ceph pg dump | grep "^1\." | awk '{print $1, $15}'

# Simulate placement (không thực sự ghi)
crushtool --test -i /tmp/crushmap.bin \
  --show-statistics \
  --rule 0 \
  --num-rep 2 \
  --min-x 0 --max-x 100
```

---

## Bài tập

1. Dump và đọc CRUSH map hiện tại
2. Xem OSD class của từng OSD
3. Tạo rule mới `lab-rule` replicate theo host
4. Tạo pool `lab-crush` dùng rule đó
5. Dùng `ceph osd map` để verify object được đặt đúng
