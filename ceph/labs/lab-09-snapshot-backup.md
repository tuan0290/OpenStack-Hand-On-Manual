# Lab 09: Snapshot và Backup Strategy

> Mục tiêu: Xây dựng backup strategy với RBD snapshot, export/import, và incremental backup.

---

## 1. RBD Snapshot Strategy

```bash
# Tạo image production
rbd create volumes/prod-data --size 2G
rbd map volumes/prod-data
mkfs.ext4 /dev/rbd0
mount /dev/rbd0 /mnt/prod

# Ghi data ban đầu
dd if=/dev/urandom of=/mnt/prod/data-v1.bin bs=1M count=100
echo "version 1" > /mnt/prod/version.txt
sync

# Snapshot v1
rbd snap create volumes/prod-data@v1
echo "Snapshot v1 created: $(date)"
```

---

## 2. Incremental Backup

```bash
# Export full backup từ snapshot v1
rbd export volumes/prod-data@v1 /tmp/backup-v1.img
ls -lh /tmp/backup-v1.img

# Thay đổi data
echo "version 2" > /mnt/prod/version.txt
dd if=/dev/urandom of=/mnt/prod/data-v2.bin bs=1M count=50
sync

# Snapshot v2
rbd snap create volumes/prod-data@v2

# Export incremental (chỉ diff từ v1 → v2)
rbd export-diff --from-snap v1 volumes/prod-data@v2 /tmp/backup-v1-to-v2.diff
ls -lh /tmp/backup-v1.img /tmp/backup-v1-to-v2.diff
# diff file nhỏ hơn nhiều so với full backup
```

---

## 3. Restore từ Backup

```bash
# Simulate disaster - xóa image gốc
umount /mnt/prod
rbd unmap /dev/rbd0
rbd snap purge volumes/prod-data
rbd rm volumes/prod-data

# Restore từ full backup
rbd import /tmp/backup-v1.img volumes/prod-data-restored

# Apply incremental diff
rbd import-diff /tmp/backup-v1-to-v2.diff volumes/prod-data-restored

# Verify
rbd snap ls volumes/prod-data-restored
rbd map volumes/prod-data-restored
mount /dev/rbd0 /mnt/prod
cat /mnt/prod/version.txt  # phải thấy "version 2"
ls -lh /mnt/prod/
```

---

## 4. Automated Backup Script

```bash
cat > /opt/ceph-rbd-backup.sh << 'SCRIPT'
#!/bin/bash
# RBD Incremental Backup Script
POOL="volumes"
IMAGE="prod-data"
BACKUP_DIR="/tmp/ceph-backups"
DATE=$(date +%Y%m%d-%H%M%S)
LAST_SNAP=$(rbd snap ls $POOL/$IMAGE --format json | python3 -c "
import json,sys
snaps = json.load(sys.stdin)
print(snaps[-1]['name'] if snaps else '')
")

mkdir -p $BACKUP_DIR

if [ -z "$LAST_SNAP" ]; then
  # Full backup
  SNAP_NAME="backup-$DATE"
  rbd snap create $POOL/$IMAGE@$SNAP_NAME
  rbd export $POOL/$IMAGE@$SNAP_NAME $BACKUP_DIR/full-$SNAP_NAME.img
  echo "Full backup: $BACKUP_DIR/full-$SNAP_NAME.img"
else
  # Incremental backup
  SNAP_NAME="backup-$DATE"
  rbd snap create $POOL/$IMAGE@$SNAP_NAME
  rbd export-diff --from-snap $LAST_SNAP $POOL/$IMAGE@$SNAP_NAME \
    $BACKUP_DIR/diff-${LAST_SNAP}-to-${SNAP_NAME}.diff
  echo "Incremental backup: diff-${LAST_SNAP}-to-${SNAP_NAME}.diff"

  # Cleanup old snapshots (giữ 7 ngày)
  rbd snap ls $POOL/$IMAGE --format json | python3 -c "
import json,sys
from datetime import datetime, timedelta
snaps = json.load(sys.stdin)
cutoff = datetime.now() - timedelta(days=7)
for s in snaps[:-1]:  # giữ snap mới nhất
    print(s['name'])
" | while read snap; do
    rbd snap rm $POOL/$IMAGE@$snap
  done
fi
SCRIPT

chmod +x /opt/ceph-rbd-backup.sh

# Test chạy
/opt/ceph-rbd-backup.sh
```

---

## 5. Cross-Pool Clone (DR Strategy)

```bash
# Tạo pool backup riêng
ceph osd pool create backups 32
rbd pool init backups

# Clone snapshot sang pool khác
rbd snap protect volumes/prod-data@v2
rbd clone volumes/prod-data@v2 backups/prod-data-dr

# Flatten để độc lập hoàn toàn
rbd flatten backups/prod-data-dr

# Verify
rbd info backups/prod-data-dr
```

---

## 6. Dọn dẹp

```bash
umount /mnt/prod 2>/dev/null || true
rbd unmap /dev/rbd0 2>/dev/null || true
rbd snap unprotect volumes/prod-data@v1 2>/dev/null || true
rbd snap unprotect volumes/prod-data@v2 2>/dev/null || true
rbd snap purge volumes/prod-data 2>/dev/null || true
rbd rm volumes/prod-data 2>/dev/null || true
rbd rm volumes/prod-data-restored 2>/dev/null || true
rbd rm backups/prod-data-dr 2>/dev/null || true
rm -f /tmp/backup-*.img /tmp/backup-*.diff
```

---

## Bài tập

1. Tạo image, ghi data, tạo 3 snapshots (v1, v2, v3)
2. Export full backup từ v1, incremental từ v1→v2 và v2→v3
3. So sánh kích thước full vs incremental backup
4. Restore về v2 từ backup files
5. Viết script tự động backup hàng ngày với retention 7 ngày
