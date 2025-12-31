# Turing RK1 Kubernetes Cluster - K3s on Armbian

This guide documents an alternative installation using K3s on Armbian, providing a similar 4-node Kubernetes cluster to the Talos setup.

## Automated Deployment

Use the provided scripts for streamlined deployment:

### Step 1: Prepare Each Node

SSH to each node after flashing Armbian and run the setup script:

```bash
# Copy script to node
scp scripts/setup-k3s-node.sh root@10.10.88.73:/root/

# SSH and run with hostname
ssh root@10.10.88.73
./setup-k3s-node.sh k3s-server

# Repeat for workers with appropriate hostnames:
# Node 2: ./setup-k3s-node.sh k3s-agent-1
# Node 3: ./setup-k3s-node.sh k3s-agent-2
# Node 4: ./setup-k3s-node.sh k3s-agent-3
```

The setup script:
- Sets hostname
- Updates system packages
- Installs required dependencies (open-iscsi, nfs-common, etc.)
- Configures kernel modules for K3s
- Sets up sysctl parameters
- Enables iSCSI for Longhorn
- Disables swap
- Formats and mounts NVMe for Longhorn storage

### Step 2: Deploy K3s Cluster

From your workstation, run the deployment script:

```bash
./scripts/deploy-k3s-cluster.sh
```

This script:
1. Installs K3s server on Node 1 (10.10.88.73)
2. Retrieves the node token
3. Installs K3s agents on Nodes 2-4
4. Downloads kubeconfig to `~/.kube/config-k3s-turing`

### Step 3: Verify Cluster

```bash
export KUBECONFIG=~/.kube/config-k3s-turing
kubectl get nodes -o wide
```

For step-by-step manual installation or customization, continue reading below.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Hardware Overview](#hardware-overview)
4. [Network Configuration](#network-configuration)
5. [BMC Access](#bmc-access)
6. [Armbian Installation](#armbian-installation)
7. [Base OS Configuration](#base-os-configuration)
8. [NVMe Storage Setup](#nvme-storage-setup)
9. [K3s Cluster Deployment](#k3s-cluster-deployment)
10. [Storage Setup (Longhorn)](#storage-setup-longhorn)
11. [Load Balancer (MetalLB)](#load-balancer-metallb)
12. [Ingress Controller (NGINX)](#ingress-controller-nginx)
13. [Monitoring (Prometheus Stack)](#monitoring-prometheus-stack)
14. [Verification](#verification)
15. [Maintenance](#maintenance)
16. [Troubleshooting](#troubleshooting)
17. [Comparison: Talos vs K3s](#comparison-talos-vs-k3s)

---

## Overview

### Why K3s on Armbian?

| Aspect | Talos | K3s on Armbian |
|--------|-------|----------------|
| OS Access | No shell, API only | Full Linux shell via SSH |
| Debugging | Via talosctl | Standard Linux tools |
| Package Management | None (immutable) | apt, snap, etc. |
| Updates | Atomic OS upgrades | Standard apt upgrades |
| Learning Curve | Steeper | Gentler |
| Security | Hardened by default | Requires configuration |
| Flexibility | Limited | High |

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Turing Pi 2.5 Board                       │
├─────────────┬─────────────┬─────────────┬─────────────┬─────┤
│   Node 1    │   Node 2    │   Node 3    │   Node 4    │ BMC │
│ RK1 Server  │ RK1 Agent   │ RK1 Agent   │ RK1 Agent   │     │
│ 10.10.88.73 │ 10.10.88.74 │ 10.10.88.75 │ 10.10.88.76 │ .70 │
├─────────────┼─────────────┼─────────────┼─────────────┼─────┤
│  Armbian    │  Armbian    │  Armbian    │  Armbian    │     │
│  K3s Server │  K3s Agent  │  K3s Agent  │  K3s Agent  │     │
│  etcd       │             │             │             │     │
├─────────────┼─────────────┼─────────────┼─────────────┤     │
│ 32GB eMMC   │ 32GB eMMC   │ 32GB eMMC   │ 32GB eMMC   │     │
│ 500GB NVMe  │ 500GB NVMe  │ 500GB NVMe  │ 500GB NVMe  │     │
└─────────────┴─────────────┴─────────────┴─────────────┴─────┘
```

---

## Prerequisites

### Required Tools (Workstation)

```bash
# Kubernetes CLI
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Turing Pi CLI
# Download from: https://github.com/turing-machines/tpi/releases
```

### Required Images

Download Armbian for Turing RK1:
```bash
# Official Armbian image for Turing RK1
# Check: https://www.armbian.com/turing-rk1/
# Or: https://github.com/armbian/community/releases

wget -O armbian-turing-rk1.img.xz \
  "https://dl.armbian.com/turing-rk1/Bookworm_current"
```

---

## Hardware Overview

| Node | Role | Hostname | IP Address | Storage |
|------|------|----------|------------|---------|
| Node 1 | K3s Server | k3s-server | 10.10.88.73 | 32GB eMMC + 500GB NVMe |
| Node 2 | K3s Agent | k3s-agent-1 | 10.10.88.74 | 32GB eMMC + 500GB NVMe |
| Node 3 | K3s Agent | k3s-agent-2 | 10.10.88.75 | 32GB eMMC + 500GB NVMe |
| Node 4 | K3s Agent | k3s-agent-3 | 10.10.88.76 | 32GB eMMC + 500GB NVMe |

---

## Network Configuration

### IP Allocation

| Purpose | IP Range |
|---------|----------|
| BMC | 10.10.88.70 |
| Cluster Nodes | 10.10.88.73-76 |
| MetalLB Pool | 10.10.88.80-99 |
| Kubernetes API | 10.10.88.73:6443 |

### Assigned LoadBalancer IPs

| Service | IP |
|---------|-----|
| Ingress Controller | 10.10.88.80 |
| Longhorn UI | 10.10.88.81 |

---

## BMC Access

### Credentials Setup

```bash
# Add to ~/.bashrc (not tracked by git)
export TPI_USERNAME=root
export TPI_PASSWORD="<your-bmc-password>"
export TPI_HOSTNAME=10.10.88.70
```

### Serial Port Mapping

| Node | Serial Device | Baud Rate |
|------|---------------|-----------|
| Node 1 | /dev/ttyS2 | 115200 |
| Node 2 | /dev/ttyS3 | 115200 |
| Node 3 | /dev/ttyS4 | 115200 |
| Node 4 | /dev/ttyS5 | 115200 |

---

## Armbian Installation

### Step 1: Download Armbian Image

```bash
# Download latest Armbian for Turing RK1
mkdir -p images
cd images
wget -O armbian-turing-rk1.img.xz \
  "https://dl.armbian.com/turing-rk1/Bookworm_current"
```

### Step 2: Flash All Nodes

```bash
# Ensure TPI env vars are set

# Flash all nodes with Armbian
for node in 1 2 3 4; do
  echo "Flashing node $node..."
  tpi flash -n $node --image-path images/armbian-turing-rk1.img.xz
done

# Power on all nodes
for node in 1 2 3 4; do
  tpi power on -n $node
  sleep 2
done

# Wait for boot (~2-3 minutes)
sleep 180
```

### Step 3: Initial Login

Default Armbian credentials:
- Username: `root`
- Password: `1234` (will force change on first login)

```bash
# SSH to each node and complete initial setup
ssh root@10.10.88.73  # Node 1
ssh root@10.10.88.74  # Node 2
ssh root@10.10.88.75  # Node 3
ssh root@10.10.88.76  # Node 4
```

---

## Base OS Configuration

Run these steps on **each node** after initial login.

### Step 1: Set Hostname

```bash
# On Node 1
hostnamectl set-hostname k3s-server

# On Node 2
hostnamectl set-hostname k3s-agent-1

# On Node 3
hostnamectl set-hostname k3s-agent-2

# On Node 4
hostnamectl set-hostname k3s-agent-3
```

### Step 2: Configure Static IP (Optional)

If not using DHCP reservations:

```bash
# Edit netplan configuration
cat > /etc/netplan/01-static.yaml << 'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      addresses:
        - 10.10.88.73/24  # Change per node: .73, .74, .75, .76
      routes:
        - to: default
          via: 10.10.88.1
      nameservers:
        addresses:
          - 10.10.88.1
          - 8.8.8.8
EOF

netplan apply
```

### Step 3: Update System

```bash
apt update && apt upgrade -y
apt install -y \
  curl \
  wget \
  open-iscsi \
  nfs-common \
  util-linux \
  jq \
  htop \
  vim
```

### Step 4: Configure Kernel Modules

```bash
# Load required modules
cat > /etc/modules-load.d/k3s.conf << 'EOF'
br_netfilter
overlay
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

# Load immediately
modprobe br_netfilter overlay ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack
```

### Step 5: Configure Sysctl

```bash
cat > /etc/sysctl.d/99-k3s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
fs.inotify.max_user_instances = 524288
fs.inotify.max_user_watches = 524288
EOF

sysctl --system
```

### Step 6: Enable iSCSI (for Longhorn)

```bash
systemctl enable iscsid
systemctl start iscsid
```

### Step 7: Disable Swap

```bash
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### Step 8: Reboot

```bash
reboot
```

---

## NVMe Storage Setup

Run on **each node** after reboot.

### Step 1: Identify NVMe Drive

```bash
lsblk
# Should show nvme0n1 (500GB)
```

### Step 2: Wipe Existing Partitions (if needed)

```bash
wipefs -a /dev/nvme0n1
```

### Step 3: Create Partition and Format

```bash
# Create single partition using entire disk
parted /dev/nvme0n1 --script mklabel gpt
parted /dev/nvme0n1 --script mkpart primary xfs 0% 100%

# Format as XFS
mkfs.xfs /dev/nvme0n1p1
```

### Step 4: Create Mount Point and Configure fstab

```bash
# Create Longhorn directory
mkdir -p /var/lib/longhorn

# Get UUID
UUID=$(blkid -s UUID -o value /dev/nvme0n1p1)

# Add to fstab
echo "UUID=$UUID /var/lib/longhorn xfs defaults,noatime 0 2" >> /etc/fstab

# Mount
mount -a

# Verify
df -h /var/lib/longhorn
```

---

## K3s Cluster Deployment

### Server Node (Node 1)

```bash
# SSH to Node 1
ssh root@10.10.88.73

# Install K3s server
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --disable=traefik \
  --disable=servicelb \
  --write-kubeconfig-mode=644 \
  --tls-san=10.10.88.73 \
  --tls-san=k3s-server \
  --node-name=k3s-server \
  --flannel-backend=vxlan

# Wait for K3s to start
sleep 30

# Get node token (needed for agents)
cat /var/lib/rancher/k3s/server/node-token
# Save this token!

# Verify server is running
kubectl get nodes
```

### Agent Nodes (Nodes 2, 3, 4)

```bash
# Set the token from server node
K3S_TOKEN="<token-from-server>"
K3S_URL="https://10.10.88.73:6443"

# On Node 2
ssh root@10.10.88.74
curl -sfL https://get.k3s.io | K3S_URL=$K3S_URL K3S_TOKEN=$K3S_TOKEN sh -s - agent \
  --node-name=k3s-agent-1

# On Node 3
ssh root@10.10.88.75
curl -sfL https://get.k3s.io | K3S_URL=$K3S_URL K3S_TOKEN=$K3S_TOKEN sh -s - agent \
  --node-name=k3s-agent-2

# On Node 4
ssh root@10.10.88.76
curl -sfL https://get.k3s.io | K3S_URL=$K3S_URL K3S_TOKEN=$K3S_TOKEN sh -s - agent \
  --node-name=k3s-agent-3
```

### Get Kubeconfig (on workstation)

```bash
# Copy kubeconfig from server
mkdir -p ~/.kube
scp root@10.10.88.73:/etc/rancher/k3s/k3s.yaml ~/.kube/config-k3s

# Update server address
sed -i 's/127.0.0.1/10.10.88.73/g' ~/.kube/config-k3s

# Set as default or merge
export KUBECONFIG=~/.kube/config-k3s

# Verify cluster
kubectl get nodes -o wide
```

Expected output:
```
NAME          STATUS   ROLES                       AGE   VERSION
k3s-server    Ready    control-plane,etcd,master   5m    v1.31.x+k3s1
k3s-agent-1   Ready    <none>                      3m    v1.31.x+k3s1
k3s-agent-2   Ready    <none>                      2m    v1.31.x+k3s1
k3s-agent-3   Ready    <none>                      1m    v1.31.x+k3s1
```

---

## Storage Setup (Longhorn)

### Install Longhorn

```bash
# Add Helm repo
helm repo add longhorn https://charts.longhorn.io
helm repo update

# Create namespace
kubectl create namespace longhorn-system

# Install Longhorn
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set defaultSettings.defaultDataPath=/var/lib/longhorn \
  --set defaultSettings.defaultReplicaCount=2 \
  --wait

# Verify installation
kubectl get pods -n longhorn-system
```

### Create Storage Classes

```bash
# Default storage class (already created by Longhorn)
kubectl get storageclass

# Create NVMe-optimized storage class
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-nvme
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "30"
  dataLocality: "best-effort"
EOF
```

### Expose Longhorn UI

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: longhorn-frontend-lb
  namespace: longhorn-system
spec:
  type: LoadBalancer
  selector:
    app: longhorn-ui
  ports:
  - port: 80
    targetPort: 8000
EOF
```

---

## Load Balancer (MetalLB)

### Install MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml

# Wait for pods
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

### Configure IP Pool

```bash
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.10.88.80-10.10.88.99
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF
```

---

## Ingress Controller (NGINX)

### Install NGINX Ingress

```bash
# Create namespace
kubectl create namespace ingress-nginx

# Install via Helm
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.service.type=LoadBalancer \
  --set controller.watchIngressWithoutClass=true

# Verify
kubectl get svc -n ingress-nginx
# Should show EXTERNAL-IP: 10.10.88.80
```

---

## Monitoring (Prometheus Stack)

### Install kube-prometheus-stack

```bash
# Add Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace monitoring

# Create values file
cat > prometheus-values-k3s.yaml << 'EOF'
grafana:
  enabled: true
  adminPassword: admin
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - grafana.local
  persistence:
    enabled: true
    storageClassName: longhorn
    size: 5Gi

prometheus:
  prometheusSpec:
    retention: 15d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - prometheus.local

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 2Gi
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - alertmanager.local

# K3s specific settings
kubeEtcd:
  enabled: false
kubeScheduler:
  enabled: false
kubeControllerManager:
  enabled: false
kubeProxy:
  enabled: false
EOF

# Install
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f prometheus-values-k3s.yaml \
  --wait --timeout 10m
```

---

## Verification

### Check All Components

```bash
# Nodes
kubectl get nodes -o wide

# All pods
kubectl get pods -A

# Storage
kubectl get nodes.longhorn.io -n longhorn-system

# Services with external IPs
kubectl get svc -A --field-selector spec.type=LoadBalancer

# Ingresses
kubectl get ingress -A

# PVCs
kubectl get pvc -A
```

### Test Ingress

```bash
# Add to /etc/hosts on workstation
echo "10.10.88.80  grafana.local prometheus.local alertmanager.local test.local" | sudo tee -a /etc/hosts

# Test
curl -H "Host: grafana.local" http://10.10.88.80/
```

---

## Maintenance

### OS Updates

```bash
# SSH to each node
apt update && apt upgrade -y

# If kernel updated, reboot
reboot
```

### K3s Updates

```bash
# On server node
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --disable=traefik \
  --disable=servicelb

# On agent nodes
curl -sfL https://get.k3s.io | K3S_URL=$K3S_URL K3S_TOKEN=$K3S_TOKEN sh -s - agent
```

### Backup

```bash
# Backup etcd (on server node)
k3s etcd-snapshot save --name manual-backup-$(date +%Y%m%d)

# List snapshots
k3s etcd-snapshot list
```

### Node Drain

```bash
# Before maintenance
kubectl drain k3s-agent-1 --ignore-daemonsets --delete-emptydir-data

# After maintenance
kubectl uncordon k3s-agent-1
```

---

## Troubleshooting

### K3s Service

```bash
# Check K3s status
systemctl status k3s        # Server
systemctl status k3s-agent  # Agent

# View logs
journalctl -u k3s -f        # Server
journalctl -u k3s-agent -f  # Agent

# Restart
systemctl restart k3s
```

### Node Not Joining

```bash
# On agent node, check connectivity
curl -k https://10.10.88.73:6443

# Verify token
cat /var/lib/rancher/k3s/server/node-token  # On server

# Check agent logs
journalctl -u k3s-agent --no-pager | tail -50
```

### Storage Issues

```bash
# Check NVMe mount
df -h /var/lib/longhorn

# Check Longhorn manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=100

# Check iSCSI
systemctl status iscsid
```

### Network Issues

```bash
# Check flannel
kubectl get pods -n kube-system -l app=flannel

# Check MetalLB
kubectl get pods -n metallb-system

# Test internal DNS
kubectl run test --rm -it --image=busybox -- nslookup kubernetes.default
```

---

## Comparison: Talos vs K3s

| Feature | Talos | K3s on Armbian |
|---------|-------|----------------|
| **Base OS** | Custom immutable | Debian-based |
| **Shell Access** | None | Full SSH |
| **Updates** | Atomic via talosctl | apt + K3s reinstall |
| **Configuration** | YAML machine config | Linux config files |
| **Debugging** | talosctl logs/dmesg | Standard Linux tools |
| **Security** | Hardened, minimal | Requires hardening |
| **Resource Usage** | Lower | Higher |
| **Package Install** | Not possible | apt, snap, etc. |
| **Root Access** | Not possible | Available |
| **Recovery** | Reflash required | SSH always available |
| **Learning Curve** | Steeper | Gentler |

### When to Choose K3s on Armbian

- Need SSH access for debugging
- Want to install additional packages
- Prefer familiar Linux administration
- Need flexibility over security hardening
- Development/testing environments

### When to Choose Talos

- Production environments
- Security-critical deployments
- Want minimal attack surface
- Prefer immutable infrastructure
- GitOps-driven operations

---

## Quick Reference

### Environment Variables

```bash
export KUBECONFIG=~/.kube/config-k3s
export TPI_USERNAME=root
export TPI_PASSWORD="<bmc-password>"
export TPI_HOSTNAME=10.10.88.70
```

### Important Paths

| Path | Purpose |
|------|---------|
| `/etc/rancher/k3s/k3s.yaml` | K3s kubeconfig |
| `/var/lib/rancher/k3s/server/node-token` | Agent join token |
| `/var/lib/longhorn/` | Longhorn storage |
| `/var/log/syslog` | System logs |

### Web UIs

| Service | URL |
|---------|-----|
| Grafana | http://grafana.local |
| Prometheus | http://prometheus.local |
| Alertmanager | http://alertmanager.local |
| Longhorn | http://10.10.88.81 |

---

## Version Reference

| Component | Version |
|-----------|---------|
| Armbian | Bookworm (latest) |
| K3s | v1.31.x |
| Longhorn | v1.7.x |
| MetalLB | v0.14.9 |
| NGINX Ingress | v1.12.x |
| kube-prometheus-stack | latest |
