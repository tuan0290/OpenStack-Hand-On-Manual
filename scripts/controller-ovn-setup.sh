#!/bin/bash
# Script cấu hình OVN/OVS cho Controller node
# Tương ứng với bước 1.4 đến 1.7 trong 06-neutron.md

set -e

MGMT_IP="192.168.225.195"
PROVIDER_IP="192.168.182.195"
PROVIDER_GW="192.168.182.2"
TUNNEL_IP="192.168.147.195"
PROVIDER_IFACE="ens33"
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
echo "=== [1.4] Cấu hình netplan ==="
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
echo "=== [1.5] Khởi động OVS và OVN Central ==="
systemctl start openvswitch-switch
systemctl enable openvswitch-switch
systemctl start ovn-central
systemctl enable ovn-central

ovs-vsctl set-manager ptcp:6640:127.0.0.1

ovn-nbctl set-connection ptcp:6641:${MGMT_IP} -- \
  set connection . inactivity_probe=60000
ovn-sbctl set-connection ptcp:6642:${MGMT_IP} -- \
  set connection . inactivity_probe=60000
echo "OVS and OVN Central started."

echo ""
echo "=== [1.6] Cấu hình OVS bridge br-provider ==="
ovs-vsctl --may-exist add-br br-provider
ovs-vsctl --may-exist add-port br-provider ${PROVIDER_IFACE}

ip addr replace ${PROVIDER_IP}/24 dev br-provider
ip link set br-provider up
ip route replace default via ${PROVIDER_GW} dev br-provider

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
  ip addr replace 192.168.182.195/24 dev br-provider && \
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
echo "=== [1.7] Cấu hình OVS external-ids và khởi động ovn-controller ==="
ovs-vsctl set open . external-ids:ovn-remote=tcp:${MGMT_IP}:6642
ovs-vsctl set open . external-ids:ovn-encap-type=geneve
ovs-vsctl set open . external-ids:ovn-encap-ip=${TUNNEL_IP}
ovs-vsctl set open . external-ids:ovn-bridge-mappings=provider:br-provider
ovs-vsctl set open . external-ids:ovn-cms-options=enable-chassis-as-gw

systemctl start ovn-controller
systemctl enable ovn-controller
echo "ovn-controller started."

echo ""
echo "=== Kiểm tra ==="
echo "--- ovs-vsctl show ---"
ovs-vsctl show | grep -E "Bridge|Port|error" || true
echo ""
echo "--- Ping gateway ---"
ping -c 2 ${PROVIDER_GW} && echo "Gateway OK" || echo "WARNING: Gateway unreachable"
echo ""
echo "=== DONE ==="
