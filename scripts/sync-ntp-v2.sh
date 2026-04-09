#!/bin/bash
# Sync NTP cho Controller, Compute và Ceph cluster từ bastion
# Usage: bash sync-ntp-v2.sh

CONTROLLER="192.168.225.195"
COMPUTE1="192.168.225.196"
CEPH_MON1="192.168.225.202"
CEPH_OSD1="192.168.225.203"
CEPH_OSD2="192.168.225.204"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}    $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC}  $1"; }
info() { echo -e "${CYAN}>>> $1${NC}"; }

echo "========================================================"
echo "  NTP Sync - OpenStack + Ceph Cluster"
echo "========================================================"
echo ""

# ── STEP 1: Sync controller với internet ─────────────────────
info "Step 1: Sync controller với internet NTP"
ssh $SSH_OPTS root@$CONTROLLER "
  systemctl stop chrony 2>/dev/null || true
  chronyd -q 'pool pool.ntp.org iburst' 2>/dev/null || true
  systemctl start chrony
  sleep 3
  chronyc -a makestep
" && ok "Controller synced" || fail "Controller sync failed"

CTRL_TIME=$(ssh $SSH_OPTS root@$CONTROLLER "date '+%Y-%m-%d %H:%M:%S %Z'" 2>/dev/null)
echo "  Controller time: $CTRL_TIME"

echo ""

# ── STEP 2: Sync tất cả nodes theo controller ────────────────
info "Step 2: Sync tất cả nodes theo controller"

NODES=(
  "$COMPUTE1:compute1"
  "$CEPH_MON1:ceph-mon1"
  "$CEPH_OSD1:ceph-osd1"
  "$CEPH_OSD2:ceph-osd2"
)

for entry in "${NODES[@]}"; do
  host="${entry%%:*}"
  name="${entry##*:}"

  if ! ssh $SSH_OPTS root@$host "echo ok" &>/dev/null; then
    fail "$name ($host) - cannot SSH"
    continue
  fi

  ssh $SSH_OPTS root@$host "
    systemctl restart chrony
    sleep 3
    chronyc -a makestep 2>/dev/null || true
  " &>/dev/null

  node_time=$(ssh $SSH_OPTS root@$host "date '+%Y-%m-%d %H:%M:%S %Z'" 2>/dev/null)
  ok "$name: $node_time"
done

echo ""

# ── STEP 3: Summary ──────────────────────────────────────────
info "Step 3: Time summary"
printf "  %-12s: %s\n" "controller" "$CTRL_TIME"
for entry in "${NODES[@]}"; do
  host="${entry%%:*}"
  name="${entry##*:}"
  t=$(ssh $SSH_OPTS root@$host "date '+%Y-%m-%d %H:%M:%S %Z'" 2>/dev/null || echo "unreachable")
  printf "  %-12s: %s\n" "$name" "$t"
done

echo ""
echo "========================================================"
echo "  Done."
echo "========================================================"
