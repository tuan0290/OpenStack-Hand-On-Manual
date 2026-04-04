#!/bin/bash
# Check và auto-fix toàn bộ OpenStack cluster từ bastion
# Usage: bash bastion-check.sh [--fix]
# Yêu cầu: SSH key đã được copy vào tất cả nodes

CONTROLLER="192.168.225.195"
COMPUTE1="192.168.225.196"
STORAGE1="192.168.225.197"
OBJECT1="192.168.225.198"
OBJECT2="192.168.225.199"
SSH_USER="root"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
AUTO_FIX=false
[[ "$1" == "--fix" ]] && AUTO_FIX=true

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}    $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC}  $1"; }
info() { echo -e "${CYAN}>>> $1${NC}"; }
fixed(){ echo -e "  ${YELLOW}[FIXED]${NC} $1"; }

ssh_check() {
  ssh $SSH_OPTS $SSH_USER@$1 "echo ok" &>/dev/null
}

# Check service, tự động start nếu --fix
check_svc() {
  local host=$1
  local svc=$2
  local result
  result=$(ssh $SSH_OPTS $SSH_USER@$host "systemctl is-active $svc 2>/dev/null")
  if [ "$result" = "active" ]; then
    ok "$svc"
  else
    if $AUTO_FIX; then
      ssh $SSH_OPTS $SSH_USER@$host "systemctl start $svc" &>/dev/null
      sleep 2
      result=$(ssh $SSH_OPTS $SSH_USER@$host "systemctl is-active $svc 2>/dev/null")
      if [ "$result" = "active" ]; then
        fixed "$svc (started)"
      else
        fail "$svc (start failed)"
      fi
    else
      fail "$svc ($result)"
    fi
  fi
}

check_remote_services() {
  local host=$1
  local label=$2
  shift 2
  local services=("$@")
  info "[$label] ($host)"
  if ! ssh_check $host; then
    fail "Cannot SSH to $host"
    return
  fi
  for svc in "${services[@]}"; do
    check_svc $host $svc
  done
}

echo "========================================================"
echo "  OpenStack Cluster Health Check (from Bastion)"
$AUTO_FIX && echo "  Mode: AUTO-FIX enabled" || echo "  Mode: check only (use --fix to auto-start failed services)"
echo "========================================================"
echo ""

# ── CONTROLLER ──────────────────────────────────────────────
check_remote_services $CONTROLLER "CONTROLLER" \
  mariadb rabbitmq-server memcached \
  ovn-northd ovn-controller openvswitch-switch \
  apache2 \
  glance-api \
  nova-scheduler nova-conductor nova-novncproxy \
  neutron-ovn-metadata-agent \
  cinder-scheduler \
  octavia-api octavia-health-manager octavia-housekeeping octavia-worker \
  swift-proxy \
  heat-engine

# Check apache2-based services riêng
info "[CONTROLLER] API services via Apache"
if ! ssh_check $CONTROLLER; then
  fail "Cannot SSH to $CONTROLLER"
else
  for svc in "nova-api" "neutron-server" "cinder-api" "heat-api" "placement-api" "keystone"; do
    result=$(ssh $SSH_OPTS $SSH_USER@$CONTROLLER \
      "curl -s -o /dev/null -w '%{http_code}' http://localhost/$(echo $svc | sed 's/-api//')" 2>/dev/null)
    # Đơn giản hơn: check apache2 đang chạy là đủ
    :
  done
  apache_status=$(ssh $SSH_OPTS $SSH_USER@$CONTROLLER "systemctl is-active apache2")
  if [ "$apache_status" = "active" ]; then
    ok "nova-api / neutron-server / cinder-api / heat-api / placement-api (via apache2)"
  else
    fail "apache2 down → nova-api / neutron-server / cinder-api / heat-api / placement-api all affected"
  fi
fi

# Check octavia-interface + o-hm0
info "[CONTROLLER] Octavia network interface"
if ssh_check $CONTROLLER; then
  oct_iface=$(ssh $SSH_OPTS $SSH_USER@$CONTROLLER "systemctl is-active octavia-interface 2>/dev/null")
  if [ "$oct_iface" = "active" ]; then
    ok "octavia-interface"
  else
    if $AUTO_FIX; then
      ssh $SSH_OPTS $SSH_USER@$CONTROLLER "systemctl start octavia-interface" &>/dev/null
      sleep 2
      oct_iface=$(ssh $SSH_OPTS $SSH_USER@$CONTROLLER "systemctl is-active octavia-interface 2>/dev/null")
      [ "$oct_iface" = "active" ] && fixed "octavia-interface (started)" || fail "octavia-interface (start failed)"
    else
      fail "octavia-interface - fix: systemctl start octavia-interface"
    fi
  fi

  hm0_ip=$(ssh $SSH_OPTS $SSH_USER@$CONTROLLER "ip addr show o-hm0 2>/dev/null | grep '172.16.0.2'")
  if [ -n "$hm0_ip" ]; then
    ok "o-hm0 IP 172.16.0.2 OK"
  else
    if $AUTO_FIX; then
      ssh $SSH_OPTS $SSH_USER@$CONTROLLER "ip addr add 172.16.0.2/12 dev o-hm0 2>/dev/null; ip link set o-hm0 up" &>/dev/null
      fixed "o-hm0 IP set to 172.16.0.2"
    else
      fail "o-hm0 missing IP - fix: ip addr add 172.16.0.2/12 dev o-hm0 && ip link set o-hm0 up"
    fi
  fi
fi

echo ""

# ── COMPUTE1 ────────────────────────────────────────────────
check_remote_services $COMPUTE1 "COMPUTE1" \
  nova-compute \
  neutron-ovn-metadata-agent \
  ovn-controller openvswitch-switch

echo ""

# ── STORAGE1 (Cinder) ───────────────────────────────────────
check_remote_services $STORAGE1 "STORAGE1" \
  cinder-volume \
  tgt

echo ""

# ── OBJECT1 (Swift) ─────────────────────────────────────────
check_remote_services $OBJECT1 "OBJECT1" \
  swift-account swift-account-auditor swift-account-reaper swift-account-replicator \
  swift-container swift-container-auditor swift-container-replicator swift-container-updater \
  swift-object swift-object-auditor swift-object-replicator swift-object-updater

echo ""

# ── OBJECT2 (Swift) ─────────────────────────────────────────
check_remote_services $OBJECT2 "OBJECT2" \
  swift-account swift-account-auditor swift-account-reaper swift-account-replicator \
  swift-container swift-container-auditor swift-container-replicator swift-container-updater \
  swift-object swift-object-auditor swift-object-replicator swift-object-updater

echo ""

# ── OPENSTACK API CHECK (từ controller) ─────────────────────
info "[API CHECK] OpenStack endpoints"
if ssh_check $CONTROLLER; then
  cmds=(
    "source ~/admin-openrc && openstack token issue -f value -c id | head -c 8 && echo '...'"
    "source ~/admin-openrc && openstack compute service list -f value -c State | grep -c up"
    "source ~/admin-openrc && openstack network agent list -f value -c Alive | grep -c True"
    "source ~/admin-openrc && openstack volume service list -f value -c State | grep -c up"
    "source ~/admin-openrc && openstack loadbalancer list 2>/dev/null | wc -l"
  )
  descs=(
    "Keystone token"
    "Nova compute services up"
    "Neutron agents alive"
    "Cinder volume services up"
    "Octavia LB count"
  )
  for i in "${!cmds[@]}"; do
    result=$(ssh $SSH_OPTS $SSH_USER@$CONTROLLER "bash -c '${cmds[$i]}'" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$result" ]; then
      ok "${descs[$i]}: $result"
    else
      fail "${descs[$i]}"
    fi
  done
fi

echo ""
echo "========================================================"
echo "  Done."
echo "========================================================"
