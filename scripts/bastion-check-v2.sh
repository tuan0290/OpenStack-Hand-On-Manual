#!/bin/bash
# Check Controller, Compute nodes và Ceph cluster từ bastion
# Usage: bash bastion-check-v2.sh [--fix]

CONTROLLER="192.168.225.195"
COMPUTE1="192.168.225.196"
CEPH_MON1="192.168.225.202"
CEPH_OSD1="192.168.225.203"
CEPH_OSD2="192.168.225.204"
SSH_USER="root"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
AUTO_FIX=false
[[ "$1" == "--fix" ]] && AUTO_FIX=true

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()    { echo -e "  ${GREEN}[OK]${NC}    $1"; }
fail()  { echo -e "  ${RED}[FAIL]${NC}  $1"; }
info()  { echo -e "${CYAN}>>> $1${NC}"; }
fixed() { echo -e "  ${YELLOW}[FIXED]${NC} $1"; }

ssh_check() {
  ssh $SSH_OPTS $SSH_USER@$1 "echo ok" &>/dev/null
}

check_svc() {
  local host=$1 svc=$2 result
  result=$(ssh $SSH_OPTS $SSH_USER@$host "systemctl is-active '$svc' 2>/dev/null")
  if [ "$result" = "active" ]; then
    ok "$svc"
  else
    if $AUTO_FIX; then
      ssh $SSH_OPTS $SSH_USER@$host "systemctl start '$svc'" &>/dev/null
      sleep 2
      result=$(ssh $SSH_OPTS $SSH_USER@$host "systemctl is-active '$svc' 2>/dev/null")
      [ "$result" = "active" ] && fixed "$svc (started)" || fail "$svc (start failed)"
    else
      fail "$svc ($result)"
    fi
  fi
}

echo "========================================================"
echo "  OpenStack + Ceph Health Check (from Bastion)"
$AUTO_FIX && echo "  Mode: AUTO-FIX" || echo "  Mode: check only (--fix to auto-start)"
echo "========================================================"

# ── CONTROLLER ──────────────────────────────────────────────
echo ""
info "[CONTROLLER] ($CONTROLLER)"
if ! ssh_check $CONTROLLER; then
  fail "Cannot SSH to $CONTROLLER"
else
  for svc in mariadb rabbitmq-server memcached \
             ovn-northd ovn-controller openvswitch-switch \
             glance-api nova-scheduler nova-conductor nova-novncproxy \
             neutron-ovn-metadata-agent cinder-scheduler \
             octavia-api octavia-health-manager octavia-housekeeping octavia-worker \
             swift-proxy heat-engine \
             gnocchi-metricd ceilometer-agent-central ceilometer-agent-notification \
             aodh-api aodh-evaluator aodh-notifier; do
    check_svc $CONTROLLER $svc
  done

  # Apache-based services
  apache=$(ssh $SSH_OPTS $SSH_USER@$CONTROLLER "systemctl is-active apache2")
  [ "$apache" = "active" ] \
    && ok "nova-api / neutron-server / cinder-api / heat-api / placement-api (via apache2)" \
    || fail "apache2 down → API services affected"

  # Octavia interface
  oct=$(ssh $SSH_OPTS $SSH_USER@$CONTROLLER "systemctl is-active octavia-interface 2>/dev/null")
  if [ "$oct" = "active" ]; then
    ok "octavia-interface"
  else
    fail "octavia-interface"
    echo "    Fix:"
    echo "      ip link del o-hm0 2>/dev/null || true"
    echo "      ovs-vsctl del-port br-int o-bhm0 2>/dev/null || true"
    echo "      systemctl start octavia-interface"
    if $AUTO_FIX; then
      ssh $SSH_OPTS $SSH_USER@$CONTROLLER "
        ip link del o-hm0 2>/dev/null || true
        ovs-vsctl del-port br-int o-bhm0 2>/dev/null || true
        sleep 1
        systemctl start octavia-interface
      " &>/dev/null
      sleep 2
      oct=$(ssh $SSH_OPTS $SSH_USER@$CONTROLLER "systemctl is-active octavia-interface 2>/dev/null")
      [ "$oct" = "active" ] && fixed "octavia-interface (started)" || fail "octavia-interface (start failed)"
    fi
  fi
fi

# ── COMPUTE1 ────────────────────────────────────────────────
echo ""
info "[COMPUTE1] ($COMPUTE1)"
if ! ssh_check $COMPUTE1; then
  fail "Cannot SSH to $COMPUTE1"
else
  for svc in nova-compute neutron-ovn-metadata-agent ovn-controller openvswitch-switch; do
    check_svc $COMPUTE1 $svc
  done
fi

# ── CEPH MON1 ───────────────────────────────────────────────
echo ""
info "[CEPH-MON1] ($CEPH_MON1)"
if ! ssh_check $CEPH_MON1; then
  fail "Cannot SSH to $CEPH_MON1"
else
  # Check ceph daemons - chạy trong podman container, không phải systemd trực tiếp
  for svc in "ceph-mon@ceph-mon1" "ceph-mgr@ceph-mon1"; do
    # cephadm dùng systemd unit dạng: ceph-<fsid>@<type>.<id>
    result=$(ssh $SSH_OPTS $SSH_USER@$CEPH_MON1 "
      systemctl list-units 'ceph-*' --state=active --no-legend 2>/dev/null | grep -c active || echo 0
    ")
    if [ "$result" -gt 0 ] 2>/dev/null; then
      ok "$svc (running via cephadm)"
      break
    else
      # Fallback: check podman containers
      containers=$(ssh $SSH_OPTS $SSH_USER@$CEPH_MON1 "podman ps --format '{{.Names}}' 2>/dev/null | grep -c ceph || echo 0")
      if [ "$containers" -gt 0 ] 2>/dev/null; then
        ok "$svc (running in podman container)"
        break
      else
        fail "$svc"
      fi
    fi
  done

  # Cluster health
  health=$(ssh $SSH_OPTS $SSH_USER@$CEPH_MON1 "ceph health 2>/dev/null")
  if echo "$health" | grep -q "HEALTH_OK"; then
    ok "Ceph cluster: $health"
  else
    fail "Ceph cluster: $health"
  fi

  # OSD status
  osd_info=$(ssh $SSH_OPTS $SSH_USER@$CEPH_MON1 "ceph osd stat 2>/dev/null | grep osds")
  ok "OSD: $osd_info"

  # Pool usage
  ssh $SSH_OPTS $SSH_USER@$CEPH_MON1 "ceph df 2>/dev/null | grep -E 'POOL|volumes|images|vms|backups'" | while read line; do
    echo "  $line"
  done
fi

# ── CEPH OSD1 ───────────────────────────────────────────────
echo ""
info "[CEPH-OSD1] ($CEPH_OSD1)"
if ! ssh_check $CEPH_OSD1; then
  fail "Cannot SSH to $CEPH_OSD1"
else
  osd_ids=$(ssh $SSH_OPTS $SSH_USER@$CEPH_OSD1 "ls /var/lib/ceph/osd/ 2>/dev/null | sed 's/ceph-//'")
  if [ -z "$osd_ids" ]; then
    # cephadm lưu ở path khác
    containers=$(ssh $SSH_OPTS $SSH_USER@$CEPH_OSD1 "podman ps --format '{{.Names}}' 2>/dev/null | grep osd")
    if [ -n "$containers" ]; then
      ok "ceph-osd1: OSD running in container: $containers"
    else
      fail "No OSD found on ceph-osd1"
    fi
  else
    for id in $osd_ids; do
      check_svc $CEPH_OSD1 "ceph-osd@$id"
    done
  fi
fi

# ── CEPH OSD2 ───────────────────────────────────────────────
echo ""
info "[CEPH-OSD2] ($CEPH_OSD2)"
if ! ssh_check $CEPH_OSD2; then
  fail "Cannot SSH to $CEPH_OSD2"
else
  osd_ids=$(ssh $SSH_OPTS $SSH_USER@$CEPH_OSD2 "ls /var/lib/ceph/osd/ 2>/dev/null | sed 's/ceph-//'")
  if [ -z "$osd_ids" ]; then
    containers=$(ssh $SSH_OPTS $SSH_USER@$CEPH_OSD2 "podman ps --format '{{.Names}}' 2>/dev/null | grep osd")
    if [ -n "$containers" ]; then
      ok "ceph-osd2: OSD running in container: $containers"
    else
      fail "No OSD found on ceph-osd2"
    fi
  else
    for id in $osd_ids; do
      check_svc $CEPH_OSD2 "ceph-osd@$id"
    done
  fi
fi

# ── OPENSTACK API CHECK ──────────────────────────────────────
echo ""
info "[API CHECK] OpenStack"
if ssh_check $CONTROLLER; then
  cmds=(
    "source ~/admin-openrc && openstack token issue -f value -c id | head -c 8 && echo '...'"
    "source ~/admin-openrc && openstack compute service list -f value -c State | grep -c up"
    "source ~/admin-openrc && openstack network agent list -f value -c Alive | grep -c True"
    "source ~/admin-openrc && openstack volume service list -f value -c State | grep -c up"
  )
  descs=("Keystone token" "Nova compute services up" "Neutron agents alive" "Cinder services up")
  for i in "${!cmds[@]}"; do
    result=$(ssh $SSH_OPTS $SSH_USER@$CONTROLLER "bash -c '${cmds[$i]}'" 2>/dev/null)
    [ $? -eq 0 ] && [ -n "$result" ] && ok "${descs[$i]}: $result" || fail "${descs[$i]}"
  done
fi

echo ""
echo "========================================================"
echo "  Done."
echo "========================================================"
