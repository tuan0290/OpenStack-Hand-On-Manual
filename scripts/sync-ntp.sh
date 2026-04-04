#!/bin/bash
# Sync NTP trên toàn bộ cluster theo controller
# Usage: bash sync-ntp.sh
# Chạy từ bastion sau khi reboot hoặc revert snapshot

CONTROLLER="192.168.225.195"
COMPUTE1="192.168.225.196"
STORAGE1="192.168.225.197"
OBJECT1="192.168.225.198"
OBJECT2="192.168.225.199"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}    $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC}  $1"; }
info() { echo -e "${CYAN}>>> $1${NC}"; }

echo "========================================================"
echo "  NTP Sync - OpenStack Cluster"
echo "========================================================"
echo ""

# ── STEP 1: Sync controller với internet NTP ─────────────────
info "Step 1: Sync controller với internet NTP"
ssh $SSH_OPTS root@$CONTROLLER "
  systemctl stop chrony 2>/dev/null || true
  chronyc -a makestep 2>/dev/null || true
  systemctl restart chrony
  sleep 3
  chronyc tracking | grep -E 'Reference|Stratum|System time'
" && ok "Controller NTP synced" || fail "Controller NTP sync failed"

echo ""

# ── STEP 2: Force sync thời gian trên controller ─────────────
info "Step 2: Force step sync trên controller"
ssh $SSH_OPTS root@$CONTROLLER "
  chronyc -a makestep
  date
" && ok "Controller time stepped" || fail "Controller time step failed"

CONTROLLER_TIME=$(ssh $SSH_OPTS root@$CONTROLLER "date '+%Y-%m-%d %H:%M:%S %Z'")
echo "  Controller time: $CONTROLLER_TIME"

echo ""

# ── STEP 3: Sync tất cả nodes còn lại theo controller ────────
NODES=("$COMPUTE1:compute1" "$STORAGE1:storage1" "$OBJECT1:object1" "$OBJECT2:object2")

info "Step 3: Sync các nodes theo controller ($CONTROLLER)"
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

  # Verify
  node_time=$(ssh $SSH_OPTS root@$host "date '+%Y-%m-%d %H:%M:%S %Z'" 2>/dev/null)
  sync_status=$(ssh $SSH_OPTS root@$host "chronyc tracking 2>/dev/null | grep 'Reference ID'" 2>/dev/null)

  ok "$name: $node_time"
  echo "       $sync_status"
done

echo ""

# ── STEP 4: Show time diff giữa các nodes ────────────────────
info "Step 4: Time summary"
echo "  Controller : $CONTROLLER_TIME"
for entry in "${NODES[@]}"; do
  host="${entry%%:*}"
  name="${entry##*:}"
  t=$(ssh $SSH_OPTS root@$host "date '+%Y-%m-%d %H:%M:%S %Z'" 2>/dev/null || echo "unreachable")
  printf "  %-12s: %s\n" "$name" "$t"
done

echo ""
echo "========================================================"
echo "  Done. All nodes synced to controller NTP."
echo "========================================================"
