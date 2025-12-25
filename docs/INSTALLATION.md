# Turing RK1 Kubernetes Cluster Installation Guide

This guide documents the complete installation of a 4-node Kubernetes cluster on Turing RK1 boards using Talos Linux.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Hardware Overview](#hardware-overview)
3. [Network Configuration](#network-configuration)
4. [Talos Image Preparation](#talos-image-preparation)
5. [Flashing Nodes](#flashing-nodes)
6. [Cluster Bootstrap](#cluster-bootstrap)
7. [Storage Setup](#storage-setup)
8. [Ingress Configuration](#ingress-configuration)
9. [Monitoring Setup](#monitoring-setup)
10. [Management Tools](#management-tools)
11. [Verification](#verification)

---

## Prerequisites

### Required Tools

Install the following on your workstation:

```bash
# Talos CLI
curl -sL https://talos.dev/install | sh

# Kubernetes CLI
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Turing Pi CLI (optional, for BMC management)
# Download from: https://github.com/turing-machines/tpi/releases
```

### BMC Access

Ensure you have SSH access to the Turing Pi BMC:

```bash
# Add to ~/.ssh/config
Host turing-bmc
    HostName 10.10.88.70
    User root
```

### BMC Requirements

**Firmware Version:** BMC firmware v2.0.0+ requires authentication for `tpi` commands.

```bash
# Check BMC firmware version
ssh turing-bmc "tpi info"

# Set credentials (for BMC v2.0.0+)
export TPI_USER=root
export TPI_PASSWORD=turing
```

**SD Card Required:** The BMC has no local storage. An SD card must be installed and will be automatically mounted at `/mnt/sdcard/`. This is required for flashing images.

```bash
# Verify SD card is mounted
ssh turing-bmc "ls -la /mnt/sdcard/"
```

---

## Hardware Overview

| Node | Role | IP Address | Storage |
|------|------|------------|---------|
| Node 1 | Control Plane | 10.10.88.73 | 31GB eMMC |
| Node 2 | Worker | 10.10.88.74 | 31GB eMMC + 500GB NVMe |
| Node 3 | Worker | 10.10.88.75 | 31GB eMMC + 500GB NVMe |
| Node 4 | Worker | 10.10.88.76 | 31GB eMMC + 500GB NVMe |

**Hardware Specifications (per RK1 node):**
- SoC: Rockchip RK3588 (8-core ARM64)
- RAM: 16GB or 32GB
- eMMC: 32GB (system disk)
- NVMe: 500GB Crucial P3 (worker nodes only)
- NPU: 6 TOPS (not currently supported in Talos)

---

## Network Configuration

### IP Allocation

| Purpose | IP Range |
|---------|----------|
| BMC | 10.10.88.70 |
| Cluster Nodes | 10.10.88.73-76 |
| MetalLB Pool | 10.10.88.80-89 |
| Kubernetes API | 10.10.88.73:6443 |

### Assigned LoadBalancer IPs

| Service | IP |
|---------|-----|
| Ingress Controller | 10.10.88.80 |
| Portainer Agent | 10.10.88.81 |

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

### Step 2: Generate Image URL

Submit the schematic to Talos Image Factory:

```bash
curl -X POST --data-binary @talos-schematic.yaml \
  https://factory.talos.dev/schematics

# Returns schematic ID, e.g.:
# 85f683902139269fbc5a7f64ea94a694d31e0b3d94347a225223fcbd042083ae
```

### Step 3: Download Image

```bash
SCHEMATIC_ID="85f683902139269fbc5a7f64ea94a694d31e0b3d94347a225223fcbd042083ae"
TALOS_VERSION="v1.11.6"

mkdir -p images/latest
curl -L -o images/latest/metal-arm64.raw.xz \
  "https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/metal-arm64.raw.xz"

# Decompress
xz -d images/latest/metal-arm64.raw.xz
```

---

## Flashing Nodes

### Step 1: Power Off All Nodes

```bash
ssh turing-bmc "tpi power off -n 1,2,3,4"
```

### Step 2: Flash Each Node

Flash nodes one at a time via BMC. The image must be on the SD card mounted at `/mnt/sdcard/`.

```bash
# Copy image to BMC SD card
scp images/latest/metal-arm64.raw turing-bmc:/mnt/sdcard/

# Flash each node (repeat for nodes 1-4)
# Note: -l flag specifies local file on BMC
for node in 1 2 3 4; do
  echo "Flashing node $node..."
  ssh turing-bmc "tpi flash -l -n $node -i /mnt/sdcard/metal-arm64.raw"
  sleep 10
done
```

> **Note:** Flashing via BMC takes approximately 15-20 minutes per node for a ~1GB image. For faster flashing, use USB cable method (see [Turing Pi docs](https://docs.turingpi.com/docs/turing-rk1-flashing-os)).

### Step 3: Power On Nodes

```bash
ssh turing-bmc "tpi power on -n 1,2,3,4"

# Wait for nodes to boot (2-3 minutes)
sleep 180
```

### Step 4: Verify Nodes

```bash
# Check if nodes are in maintenance mode
for ip in 10.10.88.73 10.10.88.74 10.10.88.75 10.10.88.76; do
  talosctl -n $ip -e $ip --insecure version 2>/dev/null && echo "$ip: OK"
done
```

---

## Cluster Bootstrap

### Step 1: Generate Secrets

```bash
mkdir -p cluster-config
cd cluster-config

talosctl gen secrets -o secrets.yaml
```

### Step 2: Generate Configurations

```bash
# Control plane config
talosctl gen config turing-cluster https://10.10.88.73:6443 \
  --with-secrets secrets.yaml \
  --config-patch-control-plane @controlplane-patch.yaml \
  --output-types controlplane \
  -o controlplane.yaml

# Worker config
talosctl gen config turing-cluster https://10.10.88.73:6443 \
  --with-secrets secrets.yaml \
  --config-patch-worker @worker-patch.yaml \
  --output-types worker \
  -o worker.yaml
```

### Step 3: Apply Configurations

```bash
# Apply to control plane
talosctl apply-config --insecure -n 10.10.88.73 --file controlplane.yaml

# Apply to workers
for ip in 10.10.88.74 10.10.88.75 10.10.88.76; do
  talosctl apply-config --insecure -n $ip --file worker.yaml
done
```

### Step 4: Bootstrap Cluster

```bash
# Set up talosctl config
export TALOSCONFIG=$(pwd)/talosconfig
talosctl config endpoint 10.10.88.73
talosctl config node 10.10.88.73

# Bootstrap etcd
talosctl bootstrap

# Wait for cluster to be ready (5-10 minutes)
talosctl health --wait-timeout 10m
```

### Step 5: Get Kubeconfig

```bash
talosctl kubeconfig kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig

# Verify cluster
kubectl get nodes
```

---

## Storage Setup

See [STORAGE.md](STORAGE.md) for detailed storage configuration.

### Quick Setup

```bash
# Add Longhorn repo
helm repo add longhorn https://charts.longhorn.io
helm repo update

# Create namespace
kubectl create namespace longhorn-system
kubectl label namespace longhorn-system pod-security.kubernetes.io/enforce=privileged

# Install Longhorn
helm install longhorn longhorn/longhorn -n longhorn-system --wait

# Configure NVMe on workers (see STORAGE.md for details)
```

---

## Ingress Configuration

See [NETWORKING.md](NETWORKING.md) for detailed networking setup.

### Quick Setup

```bash
# Install MetalLB
helm repo add metallb https://metallb.github.io/metallb
kubectl create namespace metallb-system
kubectl label namespace metallb-system pod-security.kubernetes.io/enforce=privileged
helm install metallb metallb/metallb -n metallb-system --wait

# Configure IP pool (see metallb-config.yaml)
kubectl apply -f metallb-config.yaml

# Install NGINX Ingress
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
kubectl create namespace ingress-nginx
kubectl label namespace ingress-nginx pod-security.kubernetes.io/enforce=privileged
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
  --set controller.service.type=LoadBalancer \
  --set controller.ingressClassResource.default=true \
  --wait
```

---

## Monitoring Setup

See [MONITORING.md](MONITORING.md) for detailed monitoring configuration.

### Quick Setup

```bash
# Add Prometheus Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace monitoring
kubectl label namespace monitoring pod-security.kubernetes.io/enforce=privileged

# Install kube-prometheus-stack
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f prometheus-values.yaml \
  --wait
```

### Access URLs

Add to `/etc/hosts`:
```
10.10.88.80  grafana.local prometheus.local alertmanager.local
```

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://grafana.local | admin / admin |
| Prometheus | http://prometheus.local | - |
| Alertmanager | http://alertmanager.local | - |

### External Docker Monitoring

To monitor Docker hosts, deploy exporters on each host:
- Node Exporter (port 9100) - system metrics
- cAdvisor (port 8080) - container metrics

See [MONITORING.md](MONITORING.md) for docker-compose configuration.

---

## Management Tools

### Portainer Agent

Deploy Portainer agent to connect to existing Portainer instance:

```bash
# Deploy with NodePort (or LoadBalancer if MetalLB is configured)
# For Community Edition:
kubectl apply -f https://downloads.portainer.io/ce2-22/portainer-agent-k8s-nodeport.yaml

# For Business Edition, use the versioned URL from your Portainer instance

# Label namespace for Talos
kubectl label namespace portainer pod-security.kubernetes.io/enforce=privileged

# Upgrade to LoadBalancer (optional)
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

### Expected Output

```
NAME            STATUS   ROLES           AGE   VERSION
talos-0ow-v7t   Ready    <none>          5h    v1.34.1
talos-6ed-cqn   Ready    <none>          5h    v1.34.1
talos-700-itj   Ready    <none>          5h    v1.34.1
turing-cp1      Ready    control-plane   5h    v1.34.1
```

---

## Troubleshooting

### Node Won't Boot

```bash
# Check BMC power status
ssh turing-bmc "tpi power status"

# Re-flash if needed (ensure image is on SD card)
ssh turing-bmc "tpi flash -l -n <node> -i /mnt/sdcard/metal-arm64.raw"
```

### Talos Not Responding

```bash
# Use insecure mode for maintenance
talosctl -n <ip> -e <ip> --insecure version
```

### Pods Stuck in Pending

```bash
# Check for PodSecurity issues
kubectl describe pod <pod-name>

# Label namespace as privileged if needed
kubectl label namespace <ns> pod-security.kubernetes.io/enforce=privileged
```

### Storage Issues

```bash
# Check Longhorn status
kubectl get volumes.longhorn.io -n longhorn-system

# Check NVMe mounts
talosctl -n 10.10.88.74 mounts | grep nvme
```

---

## Next Steps

- Configure DNS for ingress hostnames
- Set up TLS certificates (cert-manager)
- Deploy applications
- Configure monitoring (Prometheus/Grafana)

---

## References

- [Talos Linux Documentation](https://www.talos.dev/docs/)
- [Longhorn Documentation](https://longhorn.io/docs/)
- [MetalLB Documentation](https://metallb.io/)
- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
