# Ceph Troubleshooting Guide

> Các lỗi thường gặp và cách xử lý khi vận hành Ceph cluster.

## 1. Đọc Health Status

```bash
ceph health detail
```

**Các warning phổ biến:**

| Warning | Nguyên nhân | Fix |
|---|---|---|
| `OSD count X < osd_pool_default_size 3` | Lab chỉ có 2 OSD | `ceph config set global osd_pool_default_size 2` |
| `clock skew detected` | NTP không đồng bộ | Sync NTP trên tất cả nodes |
| `too many PGs per OSD` | PG count quá cao | Giảm PG hoặc thêm OSD |
| `nearfull OSD` | Disk gần đầy (>85%) | Thêm OSD hoặc xóa data |
| `slow ops` | OSD bị chậm | Kiểm tra disk I/O, network |

---

## 2. OSD Down

```bash
# Xem OSD nào down
ceph osd tree | grep down

# Xem lý do OSD down
ceph health detail | grep osd

# Kiểm tra service trên node đó
ssh root@ceph-osd1 "systemctl status ceph-osd@0"

# Xem log
ssh root@ceph-osd1 "journalctl -u ceph-osd@0 -n 50"

# Start lại OSD
ssh root@ceph-osd1 "systemctl start ceph-osd@0"

# Nếu OSD bị mark out, mark in lại
ceph osd in 0
```

---

## 3. HEALTH_ERR - Cluster không hoạt động

```bash
# Xem chi tiết
ceph health detail

# Trường hợp: không đủ replicas (quá nhiều OSD down)
# → Cluster từ chối write để bảo vệ data
# Fix: bring up OSD hoặc tạm thời giảm min_size
ceph osd pool set volumes min_size 1  # NGUY HIỂM - chỉ dùng tạm thời

# Trường hợp: MON mất quorum
ceph mon stat
# Nếu chỉ còn 1/3 MON → mất quorum
# Fix: bring up MON nodes
```

---

## 4. PG Stuck

```bash
# Xem PG đang stuck
ceph pg dump_stuck

# PG stuck inactive (không có primary OSD)
ceph pg dump_stuck inactive

# PG stuck unclean (chưa đủ replicas)
ceph pg dump_stuck unclean

# Force recovery
ceph pg repair <pg-id>

# Xem PG cụ thể
ceph pg <pg-id> query
```

---

## 5. Slow OSD Performance

```bash
# Xem latency của từng OSD
ceph osd perf
# commit_latency > 100ms → OSD bị chậm

# Xem slow ops
ceph daemon osd.0 dump_ops_in_flight

# Kiểm tra disk I/O trên node
ssh root@ceph-osd1 "iostat -x 1 5"

# Kiểm tra network
ssh root@ceph-osd1 "iperf3 -c ceph-osd2"

# Xem OSD log
ssh root@ceph-osd1 "tail -f /var/log/ceph/ceph-osd.0.log | grep -i slow"
```

---

## 6. Full Cluster (Disk đầy)

```bash
# Xem usage
ceph df
ceph osd df

# Xem pool nào dùng nhiều nhất
ceph df detail

# Giải phóng space:
# 1. Xóa snapshots cũ
rbd snap purge volumes/old-volume

# 2. Xóa volumes không dùng
rbd ls volumes
rbd rm volumes/unused-volume

# 3. Tăng nearfull threshold tạm thời (để tiếp tục ghi)
ceph config set global mon_osd_nearfull_ratio 0.95

# 4. Thêm OSD mới (giải pháp lâu dài)
ceph orch apply osd --all-available-devices
```

---

## 7. Clock Skew

```bash
# Xem clock skew
ceph health detail | grep clock

# Fix: sync NTP trên tất cả nodes
for node in ceph-mon1 ceph-osd1 ceph-osd2; do
  ssh root@$node "chronyc -a makestep"
done

# Verify
for node in ceph-mon1 ceph-osd1 ceph-osd2; do
  echo "$node: $(ssh root@$node date)"
done
```

---

## 8. Ceph + OpenStack Issues

### Glance không lưu vào Ceph

```bash
# Kiểm tra config
grep -n "default_backend\|enabled_backends" /etc/glance/glance-api.conf

# Kiểm tra keyring permissions
ls -la /etc/ceph/ceph.client.glance.keyring
# Phải là: -rw-r----- glance:glance

# Test kết nối Ceph từ controller
rbd -n client.glance ls images
```

### Cinder volume không tạo được

```bash
# Kiểm tra cinder-volume log
journalctl -u cinder-volume -n 50 | grep -i error

# Test kết nối Ceph
rbd -n client.cinder ls volumes

# Kiểm tra secret UUID
grep rbd_secret_uuid /etc/cinder/cinder.conf
virsh secret-list  # trên compute1
```

### Nova VM không boot được

```bash
# Xem nova-compute log
ssh root@compute1 "tail -50 /var/log/nova/nova-compute.log | grep -i error"

# Kiểm tra libvirt secret
ssh root@compute1 "virsh secret-list"
ssh root@compute1 "virsh secret-get-value <NOVA_UUID>"

# Test kết nối Ceph từ compute1
ssh root@compute1 "rbd -n client.nova ls vms"
```

---

## 9. Debug Commands

```bash
# Enable debug logging tạm thời
ceph config set global debug_osd 5
ceph config set global debug_ms 1

# Xem log realtime
ceph -w

# Xem event log
ceph log last 50

# Dump toàn bộ cluster state
ceph report > /tmp/ceph-report.json

# Reset debug logging
ceph config rm global debug_osd
ceph config rm global debug_ms
```
