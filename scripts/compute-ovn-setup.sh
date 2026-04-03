#!/bin/bash
# Script cấu hình OVN/OVS cho Compute node
# Tương ứng với bước 2.2 đến 2.5 trong 06-neutron.md

set -e

MGMT_IP="192.168.225.196"
PROVIDER_IP="192.168.182.196"
PROVIDER_GW="192.168.182.2"
TUNNEL_IP="192.168.147.196"
PROVIDER_IFACE="ens33"
CONTROLLER_MGMT_IP="192.168.225.195"
NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"

echo "=== Fix DNS - tắt systemd-resolved ghi đè ==="
mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/dns.conf << 'EOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1
DNSStubListener=no
EOF
systemctl restart systemd-resolved
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
echo "DNS fixed: $(cat /etc/resolv.conf | grep nameserver)"

echo ""
echo "=== [2.2] Khởi động OVS ==="
systemctl start openvswitch-switch
systemctl enable openvswitch-switch

ovs-vsctl set-manager ptcp:6640:127.0.0.1

# Kiểm tra port 6640
sleep 1
ss -tlnp | grep 6640 && echo "Port 6640 listening OK" || echo "WARNING: Port 6640 not listening"

echo ""
echo "=== [2.3] Cấu hình netplan ==="
chmod 600 ${NETPLAN_FILE}
cat > ${NETPLAN_FILE} << EOF
network:
  version: 2
  ethernets:
    ${PROVIDER_IFACE}:
      dhcp4: false
      dhcp6: false
    ens37:
      addresses:
        - ${MGMT_IP}/24
    ens38:
      addresses:
        - ${TUNNEL_IP}/24
EOF
netplan apply
echo "Netplan applied."

echo ""
echo "=== [2.4] Cấu hình OVS bridge br-provider ==="
ovs-vsctl del-br br-provider 2>/dev/null || true
ip link delete br-provider 2>/dev/null || true

ovs-vsctl add-br br-provider
ovs-vsctl add-port br-provider ${PROVIDER_IFACE}

ip addr add ${PROVIDER_IP}/24 dev br-provider
ip link set br-provider up
ip route add default via ${PROVIDER_GW} dev br-provider

# Kiểm tra lỗi OVS
ERRORS=$(ovs-vsctl show | grep "error" || true)
if [ -n "$ERRORS" ]; then
  echo "WARNING: OVS errors detected:"
  echo "$ERRORS"
else
  echo "OVS bridge OK - no errors"
fi

# Tạo systemd service để persistent qua reboot
cat > /etc/systemd/system/ovs-br-provider.service << 'SVCEOF'
[Unit]
Description=OVS br-provider IP configuration
After=openvswitch-switch.service
Wants=openvswitch-switch.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  ovs-vsctl --may-exist add-br br-provider && \
  ovs-vsctl --may-exist add-port br-provider ens33 && \
  ip addr replace 192.168.182.196/24 dev br-provider && \
  ip link set br-provider up && \
  ip route replace default via 192.168.182.2 dev br-provider && \
  echo "nameserver 8.8.8.8" > /etc/resolv.conf'

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable ovs-br-provider
echo "br-provider configured."

echo ""
echo "=== [2.5] Cấu hình OVS kết nối về Controller ==="
ovs-vsctl set open . external-ids:ovn-remote=tcp:${CONTROLLER_MGMT_IP}:6642
ovs-vsctl set open . external-ids:ovn-encap-type=geneve
ovs-vsctl set open . external-ids:ovn-encap-ip=${TUNNEL_IP}
ovs-vsctl set open . external-ids:ovn-bridge-mappings=provider:br-provider
echo "OVS external-ids configured."

echo ""
echo "=== Kiểm tra ==="
echo "--- Ping gateway ---"
ping -c 2 ${PROVIDER_GW} && echo "Gateway OK" || echo "WARNING: Gateway unreachable"
echo ""
echo "=== DONE ==="
