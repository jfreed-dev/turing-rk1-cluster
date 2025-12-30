#!/bin/bash
# K3s Node Setup Script for Turing RK1 on Armbian
# Usage: ./setup-k3s-node.sh <hostname>
# Example: ./setup-k3s-node.sh k3s-server

set -e

HOSTNAME=${1:-$(hostname)}

echo "=== Turing RK1 K3s Node Setup ==="
echo "Hostname: $HOSTNAME"
echo ""

# Set hostname
echo "[1/8] Setting hostname..."
hostnamectl set-hostname "$HOSTNAME"

# Update system
echo "[2/8] Updating system..."
apt update && apt upgrade -y

# Install required packages
echo "[3/8] Installing required packages..."
apt install -y \
  curl wget open-iscsi nfs-common util-linux \
  xfsprogs parted jq htop vim

# Configure kernel modules
echo "[4/8] Configuring kernel modules..."
cat > /etc/modules-load.d/k3s.conf << 'EOF'
br_netfilter
overlay
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

modprobe br_netfilter overlay ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack 2>/dev/null || true

# Configure sysctl
echo "[5/8] Configuring sysctl..."
cat > /etc/sysctl.d/99-k3s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
fs.inotify.max_user_instances = 524288
fs.inotify.max_user_watches = 524288
EOF

sysctl --system > /dev/null

# Enable iSCSI
echo "[6/8] Enabling iSCSI..."
systemctl enable iscsid
systemctl start iscsid

# Disable swap
echo "[7/8] Disabling swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Setup NVMe if present
echo "[8/8] Setting up NVMe storage..."
if [ -b /dev/nvme0n1 ]; then
  if ! mount | grep -q "/var/lib/longhorn"; then
    wipefs -a /dev/nvme0n1 2>/dev/null || true
    parted /dev/nvme0n1 --script mklabel gpt
    parted /dev/nvme0n1 --script mkpart primary xfs 0% 100%
    sleep 2
    mkfs.xfs -f /dev/nvme0n1p1
    mkdir -p /var/lib/longhorn
    UUID=$(blkid -s UUID -o value /dev/nvme0n1p1)
    echo "UUID=$UUID /var/lib/longhorn xfs defaults,noatime 0 2" >> /etc/fstab
    mount -a
    echo "  NVMe mounted at /var/lib/longhorn"
  else
    echo "  NVMe already mounted"
  fi
else
  echo "  No NVMe detected"
fi

echo ""
echo "=== Setup Complete - Reboot recommended ==="
