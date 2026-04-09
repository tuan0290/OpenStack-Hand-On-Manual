# Lab 08: Performance Tuning và Benchmarking

> Mục tiêu: Benchmark cluster, hiểu các tuning parameters, tối ưu performance.

---

## 1. Baseline Benchmark

```bash
# Write benchmark - 30 giây
rados bench -p volumes 30 write --no-cleanup
# Ghi lại: Bandwidth (MB/s), IOPS, Latency

# Sequential read
rados bench -p volumes 30 seq

# Random read
rados bench -p volumes 30 rand

# Cleanup
rados -p volumes cleanup
```

---

## 2. RBD Benchmark

```bash
# Tạo image để test
rbd create volumes/perf-test --size 1G

# Benchmark với rbd bench
rbd bench volumes/perf-test --io-type write --io-size 4096 --io-threads 16 --io-total 1G
rbd bench volumes/perf-test --io-type read  --io-size 4096 --io-threads 16 --io-total 1G
rbd bench volumes/perf-test --io-type readwrite --io-size 4096 --io-threads 16 --io-total 1G

# Cleanup
rbd rm volumes/perf-test
```

---

## 3. PG Autoscaler

```bash
# Enable autoscaler
ceph mgr module enable pg_autoscaler

# Xem recommendations
ceph osd pool autoscale-status

# Set target ratio cho pool (% cluster capacity)
ceph osd pool set volumes target_size_ratio 0.4   # 40% cluster
ceph osd pool set images target_size_ratio 0.2    # 20% cluster
ceph osd pool set vms target_size_ratio 0.3       # 30% cluster

# Enable auto mode
ceph osd pool set volumes pg_autoscale_mode on
```

---

## 4. Cache Tiering (Advanced)

```bash
# Tạo fast pool (SSD) làm cache
ceph osd pool create cache-pool 32
ceph osd pool set cache-pool size 1

# Add cache tier
ceph osd tier add volumes cache-pool
ceph osd tier cache-mode cache-pool writeback

# Set cache parameters
ceph osd pool set cache-pool hit_set_type bloom
ceph osd pool set cache-pool hit_set_count 12
ceph osd pool set cache-pool hit_set_period 14400
ceph osd pool set cache-pool target_max_bytes $((1 * 1024 * 1024 * 1024))  # 1GB
ceph osd pool set cache-pool min_read_recency_for_promote 2
ceph osd pool set cache-pool min_write_recency_for_promote 2

# Set overlay
ceph osd tier set-overlay volumes cache-pool

# Remove cache tier (khi không cần)
# ceph osd tier cache-mode cache-pool proxy
# rados -p cache-pool cache-flush-evict-all
# ceph osd tier remove-overlay volumes
# ceph osd tier remove volumes cache-pool
```

---

## 5. OSD Tuning

```bash
# Xem current config
ceph config show osd.0

# BlueStore tuning
ceph config set osd bluestore_cache_size_hdd 1073741824  # 1GB cache cho HDD
ceph config set osd bluestore_cache_size_ssd 3221225472  # 3GB cache cho SSD

# IO queue
ceph config set osd osd_op_queue wpq  # weighted priority queue
# hoặc
ceph config set osd osd_op_queue mclock_scheduler  # mClock (QoS)

# Concurrent operations
ceph config set osd osd_max_backfills 2
ceph config set osd osd_recovery_max_active 3
```

---

## 6. Network Tuning

```bash
# Messenger version
ceph config set global ms_type async  # async messenger (default)

# Message size
ceph config set global ms_dispatch_throttle_bytes 104857600  # 100MB

# Xem network stats
ceph osd perf | sort -k3 -rn | head -5  # top latency OSDs
```

---

## 7. Phân tích Performance

```bash
# Xem slow ops
ceph osd perf
ceph daemon osd.0 dump_ops_in_flight

# Xem OSD op history
ceph daemon osd.0 dump_historic_ops

# Xem PG stats
ceph pg dump_pools_json | python3 -m json.tool | grep -A5 "volumes"
```

---

## Bài tập

1. Chạy baseline benchmark (write/read/randread), ghi lại kết quả
2. Enable pg_autoscaler, set target ratio cho các pools
3. Tăng `bluestore_cache_size_hdd` lên 2GB, benchmark lại và so sánh
4. Chạy benchmark với 1 thread vs 16 threads, so sánh IOPS và latency
