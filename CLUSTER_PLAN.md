# Turing RK1 Kubernetes Cluster Deployment Plan

## Overview

Deploy a 4-node Kubernetes cluster on Turing RK1 boards (RK3588 SoC) with Talos Linux, NPU support, and distributed NVMe storage.

### Infrastructure Summary

| Component | Details |
|-----------|---------|
| BMC Address | 10.10.88.70 (SSH: `ssh turing-bmc`) |
| Node 1 (Control Plane) | 10.10.88.73 |
| Node 2 (Worker) | 10.10.88.74 |
| Node 3 (Worker) | 10.10.88.75 |
| Node 4 (Worker) | 10.10.88.76 |
| OS | Talos Linux v1.11.6 |
| Storage | NVMe (each node) + Longhorn distributed storage |
| NPU | RK3588 NPU with RKNN Runtime |

---

## Phase 1: Talos Image Preparation

### Current Image Status
- **Available**: `images/latest/metal-arm64.raw` (v1.11.6, 2.2GB decompressed)
- **Source**: https://factory.talos.dev

### Required System Extensions

The base Talos image needs additional extensions for full functionality:

1. **For Longhorn Storage** (required):
   - `iscsi-tools` - iSCSI initiator for Longhorn
   - `util-linux-tools` - Additional utilities

2. **For NPU Support** (optional - see Phase 5):
   - NPU kernel driver must be loaded from custom overlay
   - Currently not available as standard Talos extension

### Build Custom Image (Recommended)

Generate a new image with required extensions from [Talos Image Factory](https://factory.talos.dev):

```bash
# 1. Go to https://factory.talos.dev
# 2. Select: Single Board Computers → Talos v1.11.6 → Turing RK1
# 3. Add extensions:
#    - siderolabs/iscsi-tools
#    - siderolabs/util-linux-tools
# 4. Download and decompress:
curl -LO https://factory.talos.dev/image/<schematic-id>/v1.11.6/metal-arm64.raw.xz
xz -d metal-arm64.raw.xz
mv metal-arm64.raw images/latest/
```

---

## Phase 2: Flash Nodes via BMC

### Prerequisites Check
```bash
# Verify BMC access
ssh turing-bmc 'tpi info'

# Verify tpi is installed locally (for direct commands)
which tpi || echo "Install tpi from https://github.com/turing-machines/tpi/releases"
```

### Flash Sequence

Power down all nodes first, then flash sequentially:

```bash
# Set image path
IMAGE_PATH="/home/jon/Code/turing-rk1-cluster/images/latest/metal-arm64.raw"

# Flash all 4 nodes (run from BMC or use tpi remotely)
# Option A: Via BMC SSH
ssh turing-bmc "tpi flash -n 1 -i /path/to/metal-arm64.raw"
ssh turing-bmc "tpi flash -n 2 -i /path/to/metal-arm64.raw"
ssh turing-bmc "tpi flash -n 3 -i /path/to/metal-arm64.raw"
ssh turing-bmc "tpi flash -n 4 -i /path/to/metal-arm64.raw"

# Option B: Via BMC WebUI at http://10.10.88.70
# Navigate to Flash → Select node → Upload image → Flash
```

### Boot Nodes

```bash
# Power on all nodes
ssh turing-bmc "tpi power on -n 1"
ssh turing-bmc "tpi power on -n 2"
ssh turing-bmc "tpi power on -n 3"
ssh turing-bmc "tpi power on -n 4"

# Monitor boot via UART (check each node)
ssh turing-bmc "tpi uart -n 1 get"
```

---

## Phase 3: Kubernetes Cluster Configuration

### Environment Setup

```bash
# Define cluster variables
export CLUSTER_NAME="turing-cluster"
export CONTROL_PLANE_IP="10.10.88.73"
export WORKER_IPS=("10.10.88.74" "10.10.88.75" "10.10.88.76")
export KUBERNETES_ENDPOINT="https://${CONTROL_PLANE_IP}:6443"

# Working directory for configs
mkdir -p ~/Code/turing-rk1-cluster/cluster-config
cd ~/Code/turing-rk1-cluster/cluster-config
```

### Generate Cluster Secrets

```bash
# Generate secrets bundle (KEEP THIS SAFE!)
talosctl gen secrets -o secrets.yaml
```

### Generate Machine Configurations

```bash
# Generate base configs
talosctl gen config \
  --with-secrets secrets.yaml \
  $CLUSTER_NAME \
  $KUBERNETES_ENDPOINT \
  --install-disk /dev/mmcblk0 \
  --output-dir .
```

This creates:
- `controlplane.yaml` - Control plane configuration
- `worker.yaml` - Worker node configuration
- `talosconfig` - CLI authentication config

### Create Configuration Patches

#### Control Plane Patch (`controlplane-patch.yaml`)

```yaml
# controlplane-patch.yaml
machine:
  network:
    hostname: turing-cp1
    interfaces:
      - interface: eth0
        dhcp: true
  install:
    disk: /dev/mmcblk0  # Install Talos to eMMC
  kubelet:
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/lib/longhorn
        options:
          - bind
          - rshared
          - rw
cluster:
  allowSchedulingOnControlPlanes: true  # Allow workloads on CP (4-node cluster)
```

#### Worker Patch (`worker-patch.yaml`)

```yaml
# worker-patch.yaml
machine:
  network:
    interfaces:
      - interface: eth0
        dhcp: true
  install:
    disk: /dev/mmcblk0  # Install Talos to eMMC
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

#### NVMe Storage Patch (`nvme-storage-patch.yaml`)

```yaml
# nvme-storage-patch.yaml - Add to all nodes
machine:
  disks:
    - device: /dev/nvme0n1
      partitions:
        - mountpoint: /var/lib/longhorn
```

### Apply Patches

```bash
# Patch control plane config
talosctl machineconfig patch controlplane.yaml \
  --patch @controlplane-patch.yaml \
  --patch @nvme-storage-patch.yaml \
  --output controlplane-patched.yaml

# Patch worker config
talosctl machineconfig patch worker.yaml \
  --patch @worker-patch.yaml \
  --patch @nvme-storage-patch.yaml \
  --output worker-patched.yaml
```

---

## Phase 4: Deploy Talos Cluster

### Apply Configurations

```bash
# Wait for nodes to be in maintenance mode (check via UART)
# Then apply configs

# Control plane (node 1)
talosctl apply-config --insecure \
  --nodes 10.10.88.73 \
  --file controlplane-patched.yaml

# Workers (nodes 2-4)
for ip in 10.10.88.74 10.10.88.75 10.10.88.76; do
  echo "Applying config to worker: $ip"
  talosctl apply-config --insecure \
    --nodes $ip \
    --file worker-patched.yaml
done
```

### Configure talosctl

```bash
# Set endpoints
talosctl --talosconfig=./talosconfig config endpoint 10.10.88.73

# Set default node
talosctl --talosconfig=./talosconfig config node 10.10.88.73

# Merge into default config
talosctl config merge ./talosconfig
```

### Bootstrap Cluster

```bash
# Wait for control plane to be ready, then bootstrap (ONCE only!)
talosctl bootstrap --nodes 10.10.88.73

# Monitor bootstrap progress
talosctl --nodes 10.10.88.73 dmesg -f
```

### Get Kubernetes Access

```bash
# Download kubeconfig
talosctl kubeconfig --nodes 10.10.88.73

# Verify cluster
kubectl get nodes
```

Expected output:
```
NAME         STATUS   ROLES           AGE   VERSION
turing-cp1   Ready    control-plane   Xm    v1.34.x
turing-w1    Ready    <none>          Xm    v1.34.x
turing-w2    Ready    <none>          Xm    v1.34.x
turing-w3    Ready    <none>          Xm    v1.34.x
```

---

## Phase 5: Distributed Storage (Longhorn)

### Prerequisites

Ensure Talos image includes `iscsi-tools` extension (see Phase 1).

### Install Longhorn

```bash
# Add Longhorn Helm repo
helm repo add longhorn https://charts.longhorn.io
helm repo update

# Install Longhorn
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultDataPath=/var/lib/longhorn \
  --set defaultSettings.defaultReplicaCount=2 \
  --set persistence.defaultClassReplicaCount=2
```

### Verify Installation

```bash
# Check Longhorn pods
kubectl -n longhorn-system get pods

# Check storage class
kubectl get storageclass

# Access Longhorn UI (port-forward)
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Open http://localhost:8080
```

### Configure Default Storage Class

```bash
kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

---

## Phase 6: NPU Support (Advanced)

### Current State

The RK3588 NPU requires:
1. **Kernel driver** (`rknpu` module) - Must be compiled into/loaded by the kernel
2. **Runtime libraries** (`librknnrt.so`) - Available in `repo/rknn-toolkit2/`
3. **Kubernetes device plugin** - For NPU scheduling

### NPU Integration Options

#### Option A: Use RKNN in Containers (Recommended)

Run AI workloads in containers with RKNN runtime mounted:

```yaml
# Example Pod with NPU access
apiVersion: v1
kind: Pod
metadata:
  name: rknn-workload
spec:
  containers:
  - name: inference
    image: your-rknn-image:latest
    securityContext:
      privileged: true  # Required for /dev/dri access
    volumeMounts:
    - name: dev-dri
      mountPath: /dev/dri
    - name: dev-rknpu
      mountPath: /dev/rknn  # If available
  volumes:
  - name: dev-dri
    hostPath:
      path: /dev/dri
  - name: dev-rknpu
    hostPath:
      path: /dev/rknn
```

#### Option B: Build Custom Talos with NPU Driver

This requires building a custom Talos image with the RKNN kernel module. See `repo/rknn-llm/rknpu-driver/` for driver source.

```bash
# Driver tarball location
ls repo/rknn-llm/rknpu-driver/rknpu_driver_0.9.8_20241009.tar.bz2
```

### NPU Verification (Once Deployed)

```bash
# SSH into node (via talosctl)
talosctl -n 10.10.88.73 shell

# Check for NPU device
ls -la /dev/dri/
ls -la /dev/rknn* 2>/dev/null || echo "RKNN device not found"
```

---

## Quick Reference Commands

### Power Management
```bash
ssh turing-bmc "tpi power status"        # Check all node power status
ssh turing-bmc "tpi power on -n 1"       # Power on node 1
ssh turing-bmc "tpi power off -n 1"      # Power off node 1
ssh turing-bmc "tpi power cycle -n 1"    # Power cycle node 1
```

### UART Console
```bash
ssh turing-bmc "tpi uart -n 1 get"       # Get UART output from node 1
```

### Talos Management
```bash
talosctl -n 10.10.88.73 health           # Cluster health
talosctl -n 10.10.88.73 services         # Service status
talosctl -n 10.10.88.73 logs kubelet     # Kubelet logs
talosctl -n 10.10.88.73 get members      # Etcd members
talosctl -n 10.10.88.73 dashboard        # Interactive dashboard
```

### Storage
```bash
kubectl -n longhorn-system get volumes   # List Longhorn volumes
kubectl get pvc --all-namespaces         # List all PVCs
```

---

## Troubleshooting

### Node Won't Boot
1. Check UART output: `ssh turing-bmc "tpi uart -n <node> get"`
2. Verify image integrity: `sha256sum metal-arm64.raw`
3. Re-flash node: `ssh turing-bmc "tpi flash -n <node> -i <image>"`

### Talosctl Can't Connect
1. Verify node IP: Check DHCP lease or UART output
2. Check maintenance mode: Node must be booted but not configured
3. Verify network: `ping 10.10.88.73`

### Kubernetes Not Starting
1. Check bootstrap: `talosctl -n 10.10.88.73 services`
2. View etcd: `talosctl -n 10.10.88.73 etcd status`
3. Check kubelet: `talosctl -n 10.10.88.73 logs kubelet`

### Longhorn Issues
1. Verify iSCSI extension is loaded
2. Check NVMe mount: `talosctl -n <node> mounts | grep longhorn`
3. View Longhorn logs: `kubectl -n longhorn-system logs -l app=longhorn-manager`

---

## File Locations

| File | Path |
|------|------|
| Talos Image | `images/latest/metal-arm64.raw` |
| Cluster Configs | `cluster-config/` |
| Secrets Bundle | `cluster-config/secrets.yaml` (KEEP SAFE!) |
| U-Boot SPI (for NVMe boot) | Extract from `ghcr.io/siderolabs/sbc-rockchip` |
| RKNN Runtime | `repo/rknn-toolkit2/rknn-toolkit-lite2/packages/` |
| RKLLM Runtime | `repo/rknn-llm/rkllm-runtime/` |

---

## Next Steps After Deployment

1. **Install CNI** - Flannel is default, consider Cilium for advanced networking
2. **Deploy Metrics Server** - For `kubectl top` and HPA
3. **Set up Monitoring** - Prometheus + Grafana stack
4. **Test Storage** - Create PVC and verify Longhorn replication
5. **NPU Workloads** - Deploy RKNN inference containers
6. **Backup Strategy** - Configure Longhorn backup to S3/NFS
