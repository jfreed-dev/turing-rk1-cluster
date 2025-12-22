# Turing RK1 Kubernetes Cluster

[![GitHub Release](https://img.shields.io/github/v/release/jfreed-dev/turing-rk1-cluster)](https://github.com/jfreed-dev/turing-rk1-cluster/releases)
[![Lint](https://github.com/jfreed-dev/turing-rk1-cluster/actions/workflows/lint.yml/badge.svg)](https://github.com/jfreed-dev/turing-rk1-cluster/actions/workflows/lint.yml)
[![CodeQL](https://github.com/jfreed-dev/turing-rk1-cluster/actions/workflows/codeql.yml/badge.svg)](https://github.com/jfreed-dev/turing-rk1-cluster/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Talos](https://img.shields.io/badge/Talos-v1.11.6-blue)](https://www.talos.dev/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.34.1-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)

A 4-node bare-metal Kubernetes cluster built on Turing RK1 compute modules running Talos Linux, designed for edge computing, AI/ML workloads, and distributed storage.

## Hardware Summary

### Turing Pi 2 Board

| Component | Specification |
|-----------|---------------|
| Form Factor | Mini-ITX |
| Node Slots | 4x CM4/RK1 compatible |
| BMC | Integrated management controller |
| Networking | Gigabit Ethernet per node |
| Storage | NVMe slot per node |

### Turing RK1 Compute Modules (x4)

| Component | Specification |
|-----------|---------------|
| SoC | Rockchip RK3588 |
| CPU | 4x Cortex-A76 @ 2.4GHz + 4x Cortex-A55 @ 1.8GHz |
| RAM | 16GB / 32GB LPDDR4X |
| GPU | Mali-G610 MP4 |
| NPU | 6 TOPS (INT8) - *see limitations* |
| eMMC | 32GB (system disk) |
| NVMe | 500GB Crucial P3 (worker nodes) |

### Cluster Topology

```
┌─────────────────────────────────────────────────────────────┐
│                    Turing Pi 2 BMC                          │
│                     10.10.88.70                             │
├─────────────┬─────────────┬─────────────┬───────────────────┤
│   Node 1    │   Node 2    │   Node 3    │      Node 4       │
│ Control Pl. │   Worker    │   Worker    │      Worker       │
│ 10.10.88.73 │ 10.10.88.74 │ 10.10.88.75 │   10.10.88.76     │
│   32GB eMMC │ 32GB + 500GB│ 32GB + 500GB│  32GB + 500GB     │
└─────────────┴─────────────┴─────────────┴───────────────────┘
```

### Total Resources

| Resource | Amount |
|----------|--------|
| CPU Cores | 32 (8 per node) |
| RAM | 64-128GB |
| Storage (eMMC) | 128GB |
| Storage (NVMe) | 1.5TB |
| Network | 4x 1Gbps |

---

## Software Stack

### Operating System

| Component | Version | Notes |
|-----------|---------|-------|
| Talos Linux | v1.11.6 | Immutable, API-driven Kubernetes OS |
| Linux Kernel | 6.12.62 | Mainline kernel (ARM64) |

### Kubernetes Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Kubernetes | v1.34.1 | Container orchestration |
| containerd | v2.1.5 | Container runtime |
| etcd | Bundled | Distributed key-value store |

### Storage

| Component | Version | Purpose |
|-----------|---------|---------|
| Longhorn | Latest | Distributed block storage |
| CSI Driver | Longhorn | Persistent volume provisioning |

### Networking

| Component | Version | Purpose |
|-----------|---------|---------|
| Flannel | Bundled | Pod networking (CNI) |
| MetalLB | Latest | LoadBalancer for bare-metal |
| NGINX Ingress | Latest | HTTP/HTTPS ingress controller |

### Monitoring

| Component | Version | Purpose |
|-----------|---------|---------|
| Prometheus | Latest | Metrics collection & alerting |
| Grafana | Latest | Visualization & dashboards |
| Alertmanager | Latest | Alert routing & management |
| Node Exporter | Latest | Host-level metrics |
| kube-state-metrics | Latest | Kubernetes state metrics |

### Management

| Component | Version | Purpose |
|-----------|---------|---------|
| Portainer Agent | v2.33.6 | Remote cluster management |
| talosctl | v1.11.6 | Talos node management |
| kubectl | v1.34.x | Kubernetes CLI |
| Helm | v3.x | Package manager |

---

## Cluster Capabilities

### What This Cluster Can Do

**Container Orchestration**
- Run containerized workloads across 4 nodes
- Automatic pod scheduling and load balancing
- Rolling updates and rollbacks
- Health monitoring and self-healing

**Distributed Storage**
- ~1.5TB distributed storage via Longhorn
- Volume replication across nodes (configurable 1-3 replicas)
- Snapshots and backups
- Dynamic volume provisioning
- High-performance NVMe-backed storage class

**Networking**
- LoadBalancer services via MetalLB (10.10.88.80-89)
- HTTP/HTTPS ingress with NGINX
- TLS termination
- Path and host-based routing

**Edge Computing**
- Low-power ARM64 architecture (~10W per node)
- Compact form factor (Mini-ITX)
- Suitable for remote/edge deployments

**Development & Testing**
- Full Kubernetes API compatibility
- Helm chart deployment
- GitOps-ready
- Multi-architecture image support (arm64)

**AI/ML Workloads (CPU)**
- ARM64-optimized inference
- NumPy, ONNX Runtime, PyTorch (CPU)
- ~12 GFLOPS matrix operations per node
- Distributed training/inference across nodes

**Monitoring & Observability**
- Full cluster metrics via Prometheus
- Pre-configured Grafana dashboards
- Node, pod, and container-level monitoring
- Alerting with Alertmanager
- External Docker host monitoring support
- Longhorn storage metrics integration

---

## Limitations & Known Issues

### NPU Not Available

| Issue | Status | Details |
|-------|--------|---------|
| RK3588 NPU inaccessible | **Not Supported** | Talos uses mainline Linux kernel which lacks Rockchip's proprietary RKNPU driver |

**Impact:** The 6 TOPS NPU in each RK3588 cannot be used for hardware-accelerated AI inference.

**Workarounds:**
1. Use CPU-based inference (ONNX Runtime, TensorFlow Lite)
2. Wait for mainline NPU driver (in kernel review)
3. Use alternative OS with Rockchip BSP kernel for NPU workloads

### GPU Not Available

| Issue | Status | Details |
|-------|--------|---------|
| Mali-G610 GPU inaccessible | **Not Supported** | No GPU driver/passthrough in Talos |

**Impact:** No GPU acceleration for graphics or compute workloads.

### Storage Limitations

| Issue | Status | Details |
|-------|--------|---------|
| Control plane has no NVMe | By Design | Only workers have NVMe; CP uses eMMC only |
| Single replica risk | Configurable | Default 3 replicas; 2-replica mode loses redundancy if node fails |

### Network Limitations

| Issue | Status | Details |
|-------|--------|---------|
| No native LoadBalancer | Mitigated | MetalLB provides L2 LoadBalancer functionality |
| Single network interface | Hardware | Each node has only 1x 1Gbps NIC |

### Talos-Specific Considerations

| Issue | Details |
|-------|---------|
| Immutable filesystem | Cannot install packages; must use extensions or containers |
| No SSH access | Nodes managed via `talosctl` API only |
| Privileged namespaces | Many add-ons require `pod-security.kubernetes.io/enforce=privileged` label |

### Known Bugs

| Issue | Status | Workaround |
|-------|--------|------------|
| PodSecurity warnings on deploy | Expected | Label namespaces as privileged |
| MetalLB speaker pods require privileges | Expected | Namespace is pre-labeled |

---

## Network Configuration

### IP Allocation

| Resource | IP Address | Port(s) |
|----------|------------|---------|
| BMC | 10.10.88.70 | 22 (SSH) |
| Control Plane | 10.10.88.73 | 6443 (API) |
| Worker 1 | 10.10.88.74 | - |
| Worker 2 | 10.10.88.75 | - |
| Worker 3 | 10.10.88.76 | - |
| Ingress Controller | 10.10.88.80 | 80, 443 |
| Portainer Agent | 10.10.88.81 | 9001 |
| Available Pool | 10.10.88.82-89 | - |

### Internal Networks

| Network | CIDR | Purpose |
|---------|------|---------|
| Pod Network | 10.244.0.0/16 | Container IPs |
| Service Network | 10.96.0.0/12 | ClusterIP services |

---

## Quick Access

### Management URLs

| Service | URL | Notes |
|---------|-----|-------|
| Kubernetes API | https://10.10.88.73:6443 | Use kubeconfig |
| Grafana | http://grafana.local | Default: admin/admin |
| Prometheus | http://prometheus.local | Metrics & queries |
| Alertmanager | http://alertmanager.local | Alert management |
| Longhorn UI | http://longhorn.local | Storage management |
| Portainer | Your Portainer instance | Connect agent: `10.10.88.81:9001` |

Add to `/etc/hosts`:
```
10.10.88.80  grafana.local prometheus.local alertmanager.local longhorn.local
```

### CLI Access

```bash
# Set environment variables
export TALOSCONFIG=/path/to/cluster-config/talosconfig
export KUBECONFIG=/path/to/cluster-config/kubeconfig

# Verify cluster
kubectl get nodes
talosctl health
```

---

## Documentation Map

### Primary Documentation

| Document | Path | Description |
|----------|------|-------------|
| Installation Guide | [docs/INSTALLATION.md](docs/INSTALLATION.md) | Complete setup from scratch |
| Storage Guide | [docs/STORAGE.md](docs/STORAGE.md) | Longhorn and NVMe configuration |
| Networking Guide | [docs/NETWORKING.md](docs/NETWORKING.md) | MetalLB and Ingress setup |
| Monitoring Guide | [docs/MONITORING.md](docs/MONITORING.md) | Prometheus, Grafana & external monitoring |
| Quick Reference | [docs/QUICKREF.md](docs/QUICKREF.md) | Command cheatsheet |
| Docs Index | [docs/README.md](docs/README.md) | Documentation overview |

### Configuration Files

| File | Path | Description |
|------|------|-------------|
| Talos Config | [cluster-config/talosconfig](cluster-config/talosconfig) | Talos CLI configuration |
| Kubeconfig | [cluster-config/kubeconfig](cluster-config/kubeconfig) | Kubernetes access |
| Cluster Secrets | [cluster-config/secrets.yaml](cluster-config/secrets.yaml) | **Keep secure!** |
| MetalLB Config | [cluster-config/metallb-config.yaml](cluster-config/metallb-config.yaml) | IP pool configuration |
| Ingress Config | [cluster-config/ingress-config.yaml](cluster-config/ingress-config.yaml) | Ingress rules |
| Portainer Agent | [cluster-config/portainer-agent.yaml](cluster-config/portainer-agent.yaml) | Agent deployment |
| Prometheus Values | [cluster-config/prometheus-values.yaml](cluster-config/prometheus-values.yaml) | Monitoring stack config |
| External Scrape | [cluster-config/external-scrape-config.yaml](cluster-config/external-scrape-config.yaml) | Docker host monitoring |

### Reference Documentation

| Document | Path | Description |
|----------|------|-------------|
| Cluster Plan | [CLUSTER_PLAN.md](CLUSTER_PLAN.md) | Original deployment plan |
| Talos Schematic | [talos-schematic.yaml](talos-schematic.yaml) | Custom image configuration |
| RKNN Quick Start | [docs/01_Rockchip_RKNPU_Quick_Start_*.pdf](docs/) | NPU SDK guide |
| RKNN Benchmarks | [docs/benchmark.md](docs/benchmark.md) | NPU performance data |

### External Resources

| Resource | URL |
|----------|-----|
| Talos Documentation | https://www.talos.dev/docs/ |
| Longhorn Documentation | https://longhorn.io/docs/ |
| Turing Pi Documentation | https://docs.turingpi.com/ |
| MetalLB Documentation | https://metallb.io/ |
| NGINX Ingress | https://kubernetes.github.io/ingress-nginx/ |
| Prometheus Documentation | https://prometheus.io/docs/ |
| Grafana Documentation | https://grafana.com/docs/ |
| Grafana Dashboards | https://grafana.com/grafana/dashboards/ |

---

## Directory Structure

```
turing-rk1-cluster/
├── README.md                 # This file
├── CLAUDE.md                 # AI assistant instructions
├── CLUSTER_PLAN.md           # Deployment planning document
├── talos-schematic.yaml      # Talos image customization
├── cluster-config/           # Cluster configurations
│   ├── talosconfig           # Talos CLI config
│   ├── kubeconfig            # Kubernetes access
│   ├── secrets.yaml          # Cluster secrets (sensitive!)
│   ├── controlplane.yaml     # Control plane config
│   ├── worker.yaml           # Worker config
│   ├── metallb-config.yaml   # MetalLB IP pool
│   ├── ingress-config.yaml   # Ingress rules
│   ├── prometheus-values.yaml # Monitoring stack config
│   ├── external-scrape-config.yaml # External targets
│   └── *.yaml                # Other configurations
├── docs/                     # Documentation
│   ├── README.md             # Docs index
│   ├── INSTALLATION.md       # Setup guide
│   ├── STORAGE.md            # Storage guide
│   ├── NETWORKING.md         # Network guide
│   ├── MONITORING.md         # Monitoring guide
│   ├── QUICKREF.md           # Quick reference
│   └── *.pdf                 # Vendor documentation
├── images/                   # Talos images
│   └── latest/
│       └── metal-arm64.raw   # Current Talos image
└── repo/                     # Submodules/repos
    ├── sbc-rockchip/         # Talos Rockchip overlay
    ├── rknn-toolkit2/        # RKNN SDK v2.3.2
    ├── rknn-llm/             # RKLLM v1.2.3
    └── rknn_model_zoo/       # Pre-built models
```

---

## Security Notes

1. **Secrets Protection**: `cluster-config/secrets.yaml` contains cluster credentials. Keep it secure and never commit to public repositories.

2. **BMC Access**: The BMC (10.10.88.70) has full control over all nodes. Restrict network access appropriately.

3. **Privileged Workloads**: Many add-ons require privileged namespace labels. Review security implications before deploying untrusted workloads.

4. **Network Segmentation**: Consider isolating the cluster network (10.10.88.x) from untrusted networks.

---

## Contributing

This is a personal homelab cluster. Configuration files and documentation are provided as-is for reference.

## License

Configuration files and documentation are provided under MIT license. Third-party components retain their original licenses.
