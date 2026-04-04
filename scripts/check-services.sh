#!/bin/bash
# Check toàn bộ OpenStack services sau khi reboot
# Chạy trên controller: bash scripts/check-services.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}    $1"; }
fail() { echo -e "${RED}[FAIL]${NC}  $1"; }
info() { echo -e "${YELLOW}[INFO]${NC}  $1"; }

check_service() {
  local name=$1
  if systemctl is-active --quiet "$name"; then
    ok "$name"
  else
    fail "$name"
  fi
}

echo "================================================"
echo " OpenStack Service Health Check"
echo "================================================"

echo ""
info "=== Infrastructure ==="
check_service mariadb
check_service rabbitmq-server
check_service memcached
check_service ovn-northd
check_service ovn-controller
check_service openvswitch-switch

echo ""
info "=== Keystone ==="
check_service apache2

echo ""
info "=== Glance ==="
check_service glance-api

echo ""
info "=== Placement ==="
# placement chạy qua apache2

echo ""
info "=== Nova (Controller) ==="
# nova-api chạy qua apache2 (wsgi)
if systemctl is-active --quiet apache2; then
  ok "nova-api (via apache2)"
else
  fail "nova-api (apache2 down)"
fi
check_service nova-scheduler
check_service nova-conductor
check_service nova-novncproxy

echo ""
info "=== Neutron (Controller) ==="
# neutron-server chạy qua apache2
if systemctl is-active --quiet apache2; then
  ok "neutron-server (via apache2)"
else
  fail "neutron-server (apache2 down)"
fi
check_service neutron-ovn-metadata-agent

echo ""
info "=== Cinder ==="
# cinder-api chạy qua apache2
if systemctl is-active --quiet apache2; then
  ok "cinder-api (via apache2)"
else
  fail "cinder-api (apache2 down)"
fi
check_service cinder-scheduler

echo ""
info "=== Horizon ==="
# chạy qua apache2

echo ""
info "=== Octavia ==="
check_service octavia-api
check_service octavia-health-manager
check_service octavia-housekeeping
check_service octavia-worker
if systemctl is-active --quiet octavia-interface; then
  ok "octavia-interface"
else
  fail "octavia-interface - fix: systemctl start octavia-interface"
fi

echo ""
info "=== Swift (Controller/Proxy) ==="
check_service swift-proxy

info "  Note: swift-account/container/object chạy trên object1/object2, không phải controller"

echo ""
info "=== Heat ==="
# heat-api và heat-api-cfn chạy qua apache2
if systemctl is-active --quiet apache2; then
  ok "heat-api (via apache2)"
  ok "heat-api-cfn (via apache2)"
else
  fail "heat-api (apache2 down)"
  fail "heat-api-cfn (apache2 down)"
fi
check_service heat-engine

echo ""
info "=== Ceilometer/Gnocchi/Aodh ==="
check_service gnocchi-api
check_service gnocchi-metricd
check_service ceilometer-agent-central
check_service ceilometer-agent-notification
check_service aodh-api
check_service aodh-evaluator
check_service aodh-notifier
check_service aodh-listener

echo ""
info "=== OVN Network Check ==="
if ovs-vsctl show &>/dev/null; then
  ok "OVS running"
  # Check o-hm0 interface cho Octavia
  if ip link show o-hm0 &>/dev/null; then
    ok "o-hm0 interface exists"
    if ip addr show o-hm0 | grep -q "172.16.0.2"; then
      ok "o-hm0 has IP 172.16.0.2"
    else
      fail "o-hm0 missing IP 172.16.0.2 - run: ip addr add 172.16.0.2/12 dev o-hm0"
    fi
  else
    fail "o-hm0 missing - run: systemctl start octavia-interface"
  fi
else
  fail "OVS not running"
fi

echo ""
info "=== OpenStack API Check ==="
if source ~/admin-openrc 2>/dev/null; then
  if openstack token issue &>/dev/null; then
    ok "Keystone auth OK"
  else
    fail "Keystone auth FAILED"
  fi
  if openstack compute service list &>/dev/null; then
    COMPUTE_UP=$(openstack compute service list -f value -c State | grep -c "up")
    ok "Nova compute services: $COMPUTE_UP up"
  else
    fail "Nova API unreachable"
  fi
  if openstack network agent list &>/dev/null; then
    AGENT_UP=$(openstack network agent list -f value -c Alive | grep -c "True")
    ok "Neutron agents: $AGENT_UP alive"
  else
    fail "Neutron API unreachable"
  fi
else
  fail "Cannot source admin-openrc"
fi

echo ""
echo "================================================"
echo " Done. Fix any [FAIL] items before proceeding."
echo "================================================"
