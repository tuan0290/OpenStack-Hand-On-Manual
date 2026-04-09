# Lab 06: Monitoring và Dashboard

> Mục tiêu: Sử dụng Ceph Dashboard, Prometheus metrics, và alert management.

---

## 1. Ceph Dashboard

```bash
# Kiểm tra dashboard đang chạy
ceph mgr services
# Output: dashboard: https://192.168.225.202:8443/

# Truy cập từ browser
# https://192.168.225.202:8443
# Username: admin / Password: Welcome123

# Reset password nếu cần
ceph dashboard ac-user-set-password admin Welcome123
```

Dashboard cung cấp:
- Cluster overview (health, capacity, IOPS)
- OSD map và status
- Pool list và usage
- RBD images
- Log viewer

---

## 2. Prometheus Metrics

```bash
# Enable Prometheus module
ceph mgr module enable prometheus

# Kiểm tra endpoint
ceph mgr services | grep prometheus
# Output: prometheus: http://192.168.225.202:9283/

# Test metrics endpoint
curl http://192.168.225.202:9283/metrics | head -50

# Các metrics quan trọng:
# ceph_health_status          - 0=OK, 1=WARN, 2=ERR
# ceph_osd_up                 - OSD up/down
# ceph_osd_in                 - OSD in/out
# ceph_pool_bytes_used        - bytes used per pool
# ceph_pool_max_avail         - available bytes per pool
# ceph_pg_active              - active PGs
# ceph_pg_clean               - clean PGs
```

---

## 3. Performance Monitoring

```bash
# IOPS và throughput realtime
ceph osd perf

# Latency per OSD
ceph osd perf | sort -k3 -n  # sort by commit latency

# Pool stats
ceph osd pool stats

# Benchmark đơn giản
rados bench -p volumes 10 write --no-cleanup
rados bench -p volumes 10 seq
rados bench -p volumes 10 rand

# Cleanup sau benchmark
rados -p volumes cleanup
```

---

## 4. Log Management

```bash
# Xem log realtime
ceph log last 20
ceph -w

# Log files
ls /var/log/ceph/
tail -f /var/log/ceph/ceph.log

# Set log level (debug)
ceph config set global debug_osd 5
ceph config set global debug_mon 5

# Reset về default
ceph config rm global debug_osd
ceph config rm global debug_mon
```

---

## 5. Alerts

```bash
# Xem active alerts
ceph health detail

# Silence alert tạm thời
ceph crash ls
ceph crash info <crash-id>
ceph crash archive <crash-id>
ceph crash archive-all

# MGR alerts module
ceph mgr module enable alerts
ceph alerts send
```

---

## 6. Capacity Planning

```bash
# Xem usage trend
ceph df
ceph df detail

# Tính toán usable capacity
# Usable = (Total raw) / replication_size
# Ví dụ: 100GB raw, replication=2 → 50GB usable

# Xem per-pool usage
ceph osd pool stats

# Warning thresholds
ceph config get mon mon_osd_full_ratio      # default 0.95
ceph config get mon mon_osd_backfillfull_ratio  # default 0.90
ceph config get mon mon_osd_nearfull_ratio  # default 0.85
```

---

## Bài tập

1. Truy cập Ceph Dashboard và khám phá các section
2. Enable Prometheus và xem metrics endpoint
3. Chạy `rados bench` write 30 giây, xem IOPS và throughput
4. Xem log của cluster trong 1 giờ qua
5. Tính toán usable capacity của cluster hiện tại
