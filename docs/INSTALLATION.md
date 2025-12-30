# Turing RK1 Kubernetes Cluster Installation Guide

This guide documents the complete installation of a 4-node Kubernetes cluster on Turing RK1 boards using Talos Linux.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Hardware Overview](#hardware-overview)
3. [Network Configuration](#network-configuration)
4. [BMC Access](#bmc-access)
5. [Talos Image Preparation](#talos-image-preparation)
6. [Flashing Nodes](#flashing-nodes)
7. [Boot Order Fix (NVMe vs eMMC)](#boot-order-fix-nvme-vs-emmc)
8. [NVMe Filesystem Mismatch](#nvme-filesystem-mismatch-ext4-vs-xfs)
9. [Cluster Bootstrap](#cluster-bootstrap)
10. [Adding Worker Nodes](#adding-worker-nodes)
11. [Storage Setup](#storage-setup)
12. [Ingress Configuration](#ingress-configuration)
13. [Monitoring Setup](#monitoring-setup)
14. [Management Tools](#management-tools)
15. [Verification](#verification)
16. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required Tools

Install the following on your workstation:

```bash
# Talos CLI
curl -sL https://talos.dev/install | sh
# or
brew install siderolabs/tap/talosctl

# Kubernetes CLI
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Turing Pi CLI
# Download from: https://github.com/turing-machines/tpi/releases
```

---

## Hardware Overview

| Node | Role | Hostname | IP Address | Storage |
|------|------|----------|------------|---------|
| Node 1 | Control Plane | turing-cp1 | 10.10.88.73 | 31GB eMMC + 500GB NVMe |
| Node 2 | Worker | turing-w1 | 10.10.88.74 | 31GB eMMC + 500GB NVMe |
| Node 3 | Worker | turing-w2 | 10.10.88.75 | 31GB eMMC + 500GB NVMe |
| Node 4 | Worker | turing-w3 | 10.10.88.76 | 31GB eMMC + 500GB NVMe |

**Hardware Specifications (per RK1 node):**
- SoC: Rockchip RK3588 (8-core ARM64)
- RAM: 16GB or 32GB
- eMMC: 32GB (system disk - /dev/mmcblk0)
- NVMe: 500GB Crucial P3 (data disk - /dev/nvme0n1)
- NPU: 6 TOPS (not currently supported in Talos)

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
| Portainer Agent | 10.10.88.81 |

---

## BMC Access

### Credentials

Store BMC credentials in environment variables (do not commit to git):

```bash
# Add to ~/.bashrc or ~/.zshrc (not tracked by git)
export TPI_USERNAME=root
export TPI_PASSWORD="<your-bmc-password>"
export TPI_HOSTNAME=10.10.88.70
```

### TPI Command Usage

**IMPORTANT:** Always use environment variables when running TPI commands remotely:

```bash
# With env vars set, run commands normally
tpi info
tpi power status
tpi flash -n 1 --image-url "https://example.com/image.raw.xz"
```

Or source from a local env file (gitignored):

```bash
# Create .env.local (add to .gitignore)
source .env.local
tpi info
```

### Common TPI Commands

```bash
# System info
tpi info

# Power operations
tpi power status                    # Check all nodes
tpi power on -n 1                   # Power on node 1
tpi power on -n 1,2,3,4             # Power on all nodes
tpi power off -n 1                  # Power off node 1

# Flash firmware (via URL - recommended)
tpi flash -n 1 --image-url "https://example.com/image.raw.xz"

# Flash firmware (local file on BMC)
tpi flash -n 1 -i /mnt/sdcard/image.raw

# UART access
tpi uart -n 1 get                   # Get UART buffer
```

### SSH to BMC

```bash
ssh root@10.10.88.70
# Use password from your credentials store
```

### Serial Port Mapping (on BMC)

| Node | Serial Device | Baud Rate |
|------|---------------|-----------|
| Node 1 | /dev/ttyS2 | 115200 |
| Node 2 | /dev/ttyS3 | 115200 |
| Node 3 | /dev/ttyS4 | 115200 |
| Node 4 | /dev/ttyS5 | 115200 |

---

## Talos Image Preparation

### Step 1: Create Schematic

Create a custom Talos schematic with required extensions:

```yaml
# talos-schematic.yaml
overlay:
  name: turingrk1
  image: siderolabs/sbc-rockchip
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
```

### Step 2: Get Schematic ID

```bash
curl -s -X POST --data-binary @talos-schematic.yaml \
  https://factory.talos.dev/schematics | jq -r '.id'

# Current schematic ID:
# 85f683902139269fbc5a7f64ea94a694d31e0b3d94347a225223fcbd042083ae
```

### Step 3: Image URLs

**Current Image (Talos v1.11.6):**
```
https://factory.talos.dev/image/85f683902139269fbc5a7f64ea94a694d31e0b3d94347a225223fcbd042083ae/v1.11.6/metal-arm64.raw.xz
```

To download locally:
```bash
mkdir -p images/latest
wget -O images/latest/metal-arm64.raw.xz \
  "https://factory.talos.dev/image/85f683902139269fbc5a7f64ea94a694d31e0b3d94347a225223fcbd042083ae/v1.11.6/metal-arm64.raw.xz"
```

---

## Flashing Nodes

### Method 1: Via TPI Command with Local Image (Recommended)

Download the image locally first, then flash using `--image-path`:

```bash
# Ensure TPI_USERNAME, TPI_PASSWORD, TPI_HOSTNAME env vars are set

# Download image locally
wget -O /tmp/talos-rk1-v1.11.6.raw.xz \
  "https://factory.talos.dev/image/85f683902139269fbc5a7f64ea94a694d31e0b3d94347a225223fcbd042083ae/v1.11.6/metal-arm64.raw.xz"

# Flash control plane (node 1)
tpi flash -n 1 --image-path /tmp/talos-rk1-v1.11.6.raw.xz

# Flash worker nodes
for node in 2 3 4; do
  echo "Flashing node $node..."
  tpi flash -n $node --image-path /tmp/talos-rk1-v1.11.6.raw.xz
done

# Power on all nodes after flashing
for node in 1 2 3 4; do tpi power on -n $node; done
```

### Method 2: From Within a Running OS

If the node is running Ubuntu or another OS with SSH access:

```bash
# SSH to node
ssh ubuntu@<node-ip>

# Download Talos image
wget https://factory.talos.dev/image/85f683902139269fbc5a7f64ea94a694d31e0b3d94347a225223fcbd042083ae/v1.11.6/metal-arm64.raw.xz

# Decompress
xz -d metal-arm64.raw.xz

# Flash to eMMC (DESTROYS CURRENT OS!)
sudo dd if=metal-arm64.raw of=/dev/mmcblk0 bs=4M status=progress

# Sync and shutdown
sudo sync
sudo shutdown -h now
```

### Method 3: Via BMC SD Card

```bash
# Copy image to BMC SD card
scp images/latest/metal-arm64.raw root@10.10.88.70:/mnt/sdcard/

# SSH to BMC and flash
ssh root@10.10.88.70
tpi flash -n 1 -i /mnt/sdcard/metal-arm64.raw
```

### Power On After Flashing

```bash
export # Ensure TPI_USERNAME, TPI_PASSWORD, TPI_HOSTNAME env vars are set
tpi power on -n 1,2,3,4

# Wait for nodes to boot (2-3 minutes)
sleep 180
```

### Verify Nodes in Maintenance Mode

```bash
# Check if Talos maintenance port is open
for ip in 10.10.88.73 10.10.88.74 10.10.88.75 10.10.88.76; do
  nc -zv $ip 50000 2>&1 | grep -q succeeded && echo "$ip: Maintenance mode OK"
done
```

---

## Boot Order Fix (NVMe vs eMMC)

### Problem

If a node boots from NVMe instead of eMMC, the NVMe likely has bootable content that U-Boot prioritizes. This results in the node running an old OS instead of freshly flashed Talos.

### Symptoms

- Node boots into Ubuntu instead of Talos after flashing
- SSH port 22 is open instead of Talos port 50000
- `lsblk` shows root filesystem on mmcblk0 but node runs wrong OS

### Solution: Wipe NVMe via U-Boot

1. **Power off the node:**
   ```bash
   # Ensure TPI_USERNAME, TPI_PASSWORD, TPI_HOSTNAME env vars are set tpi power off -n 1
   ```

2. **Flash Ubuntu temporarily** (to get SSH access):
   ```bash
   # Ensure TPI_USERNAME, TPI_PASSWORD, TPI_HOSTNAME env vars are set \
     tpi flash -n 1 --image-url "https://firmware.turingpi.com/turing-rk1/ubuntu_22.04_rockchip_linux/v2.1.0/ubuntu-22.04.5-v2.1.0.img"
   ```

3. **SSH to BMC and open serial console:**
   ```bash
   ssh root@10.10.88.70
   picocom /dev/ttyS2 -b 115200    # For Node 1
   ```

4. **From another terminal, power on the node:**
   ```bash
   # Ensure TPI_USERNAME, TPI_PASSWORD, TPI_HOSTNAME env vars are set tpi power on -n 1
   ```

5. **In picocom session, interrupt U-Boot:**
   - Press **spacebar** when you see "Hit any key to stop autoboot"

6. **Set boot order to eMMC first:**
   ```
   => setenv boot_targets "mmc0 nvme0"
   => saveenv
   => boot
   ```

7. **Login to Ubuntu and wipe NVMe:**
   ```bash
   # Login: ubuntu / ubuntu (will force password change)
   # Set new password when prompted

   sudo wipefs -a /dev/nvme0n1
   sudo shutdown -h now
   ```

8. **Flash Talos:**
   ```bash
   # Ensure TPI_USERNAME, TPI_PASSWORD, TPI_HOSTNAME env vars are set \
     tpi flash -n 1 --image-url "https://factory.talos.dev/image/85f683902139269fbc5a7f64ea94a694d31e0b3d94347a225223fcbd042083ae/v1.11.6/metal-arm64.raw.xz"
   ```

9. **Power on - node should now boot Talos from eMMC:**
   ```bash
   # Ensure TPI_USERNAME, TPI_PASSWORD, TPI_HOSTNAME env vars are set
   tpi power on -n 1
   ```

---

## NVMe Filesystem Mismatch (ext4 vs XFS)

### Problem

If nodes were previously running Ubuntu or another OS, the NVMe drives may have ext4 partitions. Talos expects XFS filesystem for its disk mounts, causing boot failures.

### Symptoms

```
[talos] volume status ... "error": "filesystem type mismatch: ext4 != xfs"
[talos] controller failed ... "error": "error writing kubelet PKI: read-only file system"
```

The node boots but kubelet fails to start, and the node won't join the cluster.

### Solution: Wipe NVMe with talosctl

**Option A: From a working cluster (recommended)**

If you have at least one working node (e.g., control plane), use it to wipe the NVMe on problem nodes:

```bash
export TALOSCONFIG=/path/to/talosconfig

# Wipe NVMe on each worker node
talosctl --endpoints 10.10.88.73 --nodes 10.10.88.74 wipe disk nvme0n1
talosctl --endpoints 10.10.88.73 --nodes 10.10.88.75 wipe disk nvme0n1
talosctl --endpoints 10.10.88.73 --nodes 10.10.88.76 wipe disk nvme0n1

# Apply config (will reboot to create new XFS partitions)
talosctl --endpoints 10.10.88.73 apply-config --nodes 10.10.88.74 --file worker2-final.yaml
```

**Option B: Remove NVMe config temporarily**

If all nodes are failing, temporarily remove the NVMe disk config from worker configs:

1. Edit worker configs to remove `machine.disks` and `machine.kubelet.extraMounts`
2. Apply configs - nodes will boot without NVMe
3. Once nodes are up, wipe NVMe using talosctl
4. Re-add disk config and apply again

```bash
# After nodes are running without disk config:
talosctl --endpoints 10.10.88.73 --nodes 10.10.88.74 wipe disk nvme0n1

# Then apply full config with disk mounts
talosctl --endpoints 10.10.88.73 apply-config --nodes 10.10.88.74 --file worker-with-nvme.yaml
```

### Verify NVMe is Properly Mounted

```bash
# Check volume status
talosctl --endpoints 10.10.88.73 --nodes 10.10.88.74 get discoveredvolumes | grep nvme

# Should show:
# nvme0n1        disk        500 GB   gpt
# nvme0n1p1      partition   500 GB   xfs   <-- Must be XFS, not ext4

# Check mount
talosctl --endpoints 10.10.88.73 --nodes 10.10.88.74 mounts | grep longhorn
# Should show /var/lib/longhorn mounted from nvme0n1p1
```

---

## Cluster Bootstrap

### Step 1: Generate Secrets

Generate cluster secrets once and keep them secure:

```bash
mkdir -p cluster-config
cd cluster-config
talosctl gen secrets -o secrets.yaml
```

### Step 2: Generate Configurations

```bash
# Generate control plane config
talosctl gen config turing-cluster https://10.10.88.73:6443 \
  --with-secrets secrets.yaml \
  --output-types controlplane \
  --output controlplane.yaml

# Generate worker config
talosctl gen config turing-cluster https://10.10.88.73:6443 \
  --with-secrets secrets.yaml \
  --output-types worker \
  --output worker.yaml
```

### Step 3: Create Node Patches

**controlplane-patch.yaml:**
```yaml
machine:
  network:
    hostname: turing-cp1
    interfaces:
      - interface: eth0
        dhcp: true
  install:
    disk: /dev/mmcblk0
  disks:
    - device: /dev/nvme0n1
      partitions:
        - mountpoint: /var/lib/longhorn
  kubelet:
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/lib/longhorn
        options:
          - bind
          - rshared
          - rw
  nodeLabels:
    node.kubernetes.io/exclude-from-external-load-balancers: ""
cluster:
  allowSchedulingOnControlPlanes: true
```

**worker-patch.yaml** (template - adjust hostname per node):
```yaml
machine:
  network:
    hostname: turing-w1   # Change for each worker: w1, w2, w3
    interfaces:
      - interface: eth0
        dhcp: true
  install:
    disk: /dev/mmcblk0
  disks:
    - device: /dev/nvme0n1
      partitions:
        - mountpoint: /var/lib/longhorn
  kubelet:
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/lib/longhorn
        options:
          - bind
          - rshared
          - rw
```

### Step 4: Generate Final Configs

```bash
# Control plane
talosctl machineconfig patch controlplane.yaml --patch @controlplane-patch.yaml \
  --output controlplane-node1.yaml

# Workers (create separate patches for each with unique hostnames)
talosctl machineconfig patch worker.yaml --patch @worker2-patch.yaml --output worker2-final.yaml
talosctl machineconfig patch worker.yaml --patch @worker3-patch.yaml --output worker3-final.yaml
talosctl machineconfig patch worker.yaml --patch @worker4-patch.yaml --output worker4-final.yaml
```

### Step 5: Apply Control Plane Config

```bash
# Verify node is in maintenance mode
nc -zv 10.10.88.73 50000

# Apply config
talosctl apply-config --insecure --nodes 10.10.88.73 --file controlplane-node1.yaml
```

### Step 6: Configure talosctl

```bash
# Set endpoints and node
talosctl config endpoint 10.10.88.73
talosctl config node 10.10.88.73

# Or specify talosconfig location
export TALOSCONFIG=$(pwd)/talosconfig
```

### Step 7: Bootstrap Cluster

Wait for node to finish applying config (~2 minutes), then:

```bash
talosctl bootstrap --nodes 10.10.88.73
```

### Step 8: Get Kubeconfig

```bash
talosctl kubeconfig --force
```

### Step 9: Verify Cluster

```bash
# Check Talos health
talosctl health --wait-timeout 5m

# Check Kubernetes
kubectl get nodes -o wide
kubectl get pods -A
```

---

## Adding Worker Nodes

### Apply Worker Configs

For nodes in maintenance mode (port 50000 open, no TLS required):

```bash
# Node 2
talosctl apply-config --insecure --nodes 10.10.88.74 --file worker2-final.yaml

# Node 3
talosctl apply-config --insecure --nodes 10.10.88.75 --file worker3-final.yaml

# Node 4
talosctl apply-config --insecure --nodes 10.10.88.76 --file worker4-final.yaml
```

### Verify Workers Joined

```bash
# Watch nodes join
kubectl get nodes -w

# Expected output:
# NAME         STATUS   ROLES           AGE   VERSION
# turing-cp1   Ready    control-plane   10m   v1.34.1
# turing-w1    Ready    <none>          2m    v1.34.1
# turing-w2    Ready    <none>          2m    v1.34.1
# turing-w3    Ready    <none>          2m    v1.34.1
```

### If Worker Has Wrong Certificates

If a worker was configured with a different cluster's secrets:

```bash
# Reflash the node
# Ensure TPI_USERNAME, TPI_PASSWORD, TPI_HOSTNAME env vars are set \
  tpi flash -n 2 --image-url "https://factory.talos.dev/image/85f683902139269fbc5a7f64ea94a694d31e0b3d94347a225223fcbd042083ae/v1.11.6/metal-arm64.raw.xz"

# Power on
# Ensure TPI_USERNAME, TPI_PASSWORD, TPI_HOSTNAME env vars are set tpi power on -n 2

# Wait and apply config
sleep 120
talosctl apply-config --insecure --nodes 10.10.88.74 --file worker2-final.yaml
```

---

## Storage Setup

See [STORAGE.md](STORAGE.md) for detailed storage configuration.

### Quick Longhorn Setup

```bash
# Create namespace
kubectl create namespace longhorn-system
kubectl label namespace longhorn-system pod-security.kubernetes.io/enforce=privileged

# Install Longhorn
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml

# Wait for deployment
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer

# Create NVMe storage class
cat <<EOF | kubectl apply -f -
apiVersion: storage.longhorn.io/v1beta2
kind: StorageClass
metadata:
  name: longhorn-nvme
provisioner: driver.longhorn.io
allowVolumeExpansion: true
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
  diskSelector: "nvme"
  dataLocality: "best-effort"
EOF
```

---

## Ingress Configuration

See [NETWORKING.md](NETWORKING.md) for detailed networking setup.

### Quick MetalLB Setup

```bash
# Install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml

# Wait for pods
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s

# Configure IP pool
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

### Quick Ingress NGINX Setup

```bash
# Create and label namespace
kubectl create namespace ingress-nginx
kubectl label namespace ingress-nginx pod-security.kubernetes.io/enforce=privileged

# Install NGINX Ingress Controller (cloud provider version for LoadBalancer support)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0-beta.0/deploy/static/provider/cloud/deploy.yaml

# Wait for controller to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# Verify LoadBalancer IP assigned (should be 10.10.88.80)
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

---

## Monitoring Setup

See [MONITORING.md](MONITORING.md) for detailed monitoring configuration.

### Quick Prometheus Stack Setup

```bash
# Add Prometheus Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace monitoring
kubectl label namespace monitoring pod-security.kubernetes.io/enforce=privileged

# Install kube-prometheus-stack with values file
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f cluster-config/prometheus-values.yaml \
  --wait --timeout 10m

# Verify deployment
kubectl get pods -n monitoring
kubectl get ingress -n monitoring
```

### Prometheus Values File

Save as `cluster-config/prometheus-values.yaml`:

```yaml
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
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 2Gi
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

# Disable components not accessible on Talos
kubeEtcd:
  enabled: false
kubeScheduler:
  enabled: false
kubeControllerManager:
  enabled: false
```

### Access URLs

Add to `/etc/hosts`:
```
10.10.88.80  grafana.local prometheus.local alertmanager.local longhorn.local
```

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://grafana.local | admin / admin |
| Prometheus | http://prometheus.local | - |
| Alertmanager | http://alertmanager.local | - |

---

## Management Tools

### Portainer Agent

```bash
kubectl apply -f https://downloads.portainer.io/ce2-22/portainer-agent-k8s-nodeport.yaml
kubectl label namespace portainer pod-security.kubernetes.io/enforce=privileged
kubectl patch svc portainer-agent -n portainer -p '{"spec":{"type":"LoadBalancer"}}'
```

**Connection URL:** `10.10.88.81:9001`

---

## Verification

### Check All Components

```bash
# Nodes
kubectl get nodes -o wide

# System pods
kubectl get pods -A

# Storage
kubectl get nodes.longhorn.io -n longhorn-system

# Services with external IPs
kubectl get svc -A --field-selector spec.type=LoadBalancer

# Ingress
kubectl get ingress -A
```

### Expected Cluster State

```
NAME         STATUS   ROLES           AGE   VERSION
turing-cp1   Ready    control-plane   1h    v1.34.1
turing-w1    Ready    <none>          1h    v1.34.1
turing-w2    Ready    <none>          1h    v1.34.1
turing-w3    Ready    <none>          1h    v1.34.1
```

---

## Troubleshooting

### BMC Lockout

If too many authentication attempts lock out the BMC:
```
Exceeded allowed authentication attempts. Access blocked for Xm Ys
```

**Solution:** Wait for the lockout period to expire, then retry with correct credentials.

### Node Not in Maintenance Mode

```bash
# Check port 50000
nc -zv <node-ip> 50000

# If "connection refused" - Talos not running or wrong IP
# If "tls: certificate required" - node already configured
```

### Node Configured with Wrong Certificates

```bash
# Must reflash the node
# Ensure TPI_USERNAME, TPI_PASSWORD, TPI_HOSTNAME env vars are set \
  tpi flash -n <node> --image-url "https://factory.talos.dev/image/85f683902139269fbc5a7f64ea94a694d31e0b3d94347a225223fcbd042083ae/v1.11.6/metal-arm64.raw.xz"
```

### Node Boots Wrong OS

See [Boot Order Fix](#boot-order-fix-nvme-vs-emmc) section.

### Check Talos Logs

```bash
# System logs
talosctl -n <node-ip> dmesg

# Service logs
talosctl -n <node-ip> logs kubelet
talosctl -n <node-ip> logs etcd

# All services status
talosctl -n <node-ip> services
```

### Pods Stuck in Pending

```bash
# Check for PodSecurity issues
kubectl describe pod <pod-name> -n <namespace>

# Label namespace as privileged if needed
kubectl label namespace <ns> pod-security.kubernetes.io/enforce=privileged
```

### Storage Issues

```bash
# Check Longhorn status
kubectl get volumes.longhorn.io -n longhorn-system

# Check NVMe mounts on node
talosctl -n <node-ip> mounts | grep nvme
```

---

## Version Reference

| Component | Version |
|-----------|---------|
| Talos | v1.11.6 |
| Kubernetes | v1.34.1 |
| Longhorn | v1.7.2 |
| MetalLB | v0.14.9 |
| Ingress NGINX | v1.12.0-beta.0 |
| kube-prometheus-stack | latest (Helm) |

---

## File Locations

| File | Purpose |
|------|---------|
| `cluster-config/secrets.yaml` | Cluster secrets (KEEP SECURE!) |
| `cluster-config/talosconfig` | Talos CLI configuration |
| `cluster-config/controlplane-node1.yaml` | Control plane config |
| `cluster-config/worker*-final.yaml` | Worker configs |
| `talos-schematic.yaml` | Image customization |

---

## References

- [Talos Linux Documentation](https://www.talos.dev/docs/)
- [Turing Pi Documentation](https://docs.turingpi.com/)
- [Longhorn Documentation](https://longhorn.io/docs/)
- [MetalLB Documentation](https://metallb.io/)
- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
