# BlueStore - Storage Engine của Ceph OSD

> BlueStore là storage backend mặc định từ Ceph Luminous (2017). Hiểu BlueStore giúp tuning performance đúng cách.

## 1. BlueStore là gì?

BlueStore là **storage engine** chạy bên trong mỗi OSD daemon - quyết định cách data được ghi xuống disk.

```
Trước BlueStore (FileStore):        BlueStore:
OSD → Filesystem (XFS/ext4) → Disk  OSD → BlueStore → Disk trực tiếp
      (overhead filesystem)          (bypass filesystem, nhanh hơn)
```

---

## 2. Kiến trúc BlueStore

```
┌─────────────────────────────────────────────────────┐
│                   OSD Daemon                        │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │              BlueStore                      │   │
│  │                                             │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │   │
│  │  │ RocksDB  │  │  Block   │  │  WAL     │  │   │
│  │  │(metadata)│  │  Device  │  │(journal) │  │   │
│  │  │          │  │  (data)  │  │          │  │   │
│  │  └──────────┘  └──────────┘  └──────────┘  │   │
│  │       │              │             │        │   │
│  └───────┼──────────────┼─────────────┼────────┘   │
│          ▼              ▼             ▼             │
│      /dev/sdb       /dev/sdb      /dev/sdb         │
│      (partition)    (partition)   (partition)       │
└─────────────────────────────────────────────────────┘
```

**3 thành phần:**

| Component | Lưu gì | Disk |
|---|---|---|
| Block Device | Object data thực tế | Phần lớn disk |
| RocksDB | Metadata (object names, checksums, omap) | ~4% disk |
| WAL (Write-Ahead Log) | Journal cho RocksDB | ~1% disk |

---

## 3. Tại sao BlueStore nhanh hơn FileStore?

```
FileStore write path:
  Data → Journal (write 1) → Filesystem (write 2) → Disk
  → Double write penalty

BlueStore write path:
  Data → WAL (metadata) + Block device (data) → Disk
  → Single write, checksums built-in
```

**Lợi ích BlueStore:**
- Không double-write
- Checksum tích hợp (phát hiện bit rot)
- Compression tích hợp
- Partial write support
- Nhanh hơn ~2x so với FileStore

---

## 4. BlueStore Cache

BlueStore có cache riêng trong RAM:

```bash
# Xem cache size hiện tại
ceph config get osd bluestore_cache_size_hdd
ceph config get osd bluestore_cache_size_ssd

# Default:
# HDD: 1GB per OSD
# SSD: 3GB per OSD

# Tăng cache (nếu có nhiều RAM)
ceph config set osd bluestore_cache_size_hdd 2147483648  # 2GB
```

**Cache chứa:**
- RocksDB data (metadata)
- Data blocks (hot data)
- Onodes (object metadata in memory)

---

## 5. Compression

BlueStore hỗ trợ compression transparent:

```bash
# Enable compression cho pool
ceph osd pool set volumes compression_mode aggressive
# Modes: none, passive, aggressive, force

# Set algorithm
ceph osd pool set volumes compression_algorithm snappy
# Algorithms: snappy (fast), zlib (better ratio), zstd (balanced)

# Xem compression stats
ceph osd pool stats volumes
```

---

## 6. Kiểm tra BlueStore

```bash
# Xem BlueStore stats của OSD
ceph daemon osd.0 perf dump | grep bluestore

# Xem cache hit rate
ceph daemon osd.0 perf dump | grep -E "cache_hits|cache_misses"

# Xem disk usage breakdown
ceph osd df
# Cột UTIL = % disk đang dùng

# BlueStore device info
ceph-bluestore-tool show-label --dev /dev/sdb
```

---

## 7. Tuning cho Lab VMware

Với lab VMware (disk là virtual), một số tuning phù hợp:

```bash
# Giảm cache size (tiết kiệm RAM cho lab)
ceph config set osd bluestore_cache_size_hdd 536870912  # 512MB

# Tắt compression (giảm CPU overhead trong lab)
ceph osd pool set volumes compression_mode none

# Tăng concurrent operations
ceph config set osd osd_op_num_threads_per_shard 2
```
