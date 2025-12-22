# Turing RK1 Cluster Documentation

This folder contains documentation for deploying and managing a Kubernetes cluster on Turing RK1 boards.

## Quick Start

1. Read [INSTALLATION.md](INSTALLATION.md) for complete setup instructions
2. Use [QUICKREF.md](QUICKREF.md) for daily operations
3. Refer to specialized guides for specific topics

## Documentation Index

### Cluster Setup & Operations

| Document | Description |
|----------|-------------|
| [INSTALLATION.md](INSTALLATION.md) | Complete installation guide from scratch |
| [QUICKREF.md](QUICKREF.md) | Quick reference card for common commands |
| [STORAGE.md](STORAGE.md) | Longhorn storage and NVMe configuration |
| [NETWORKING.md](NETWORKING.md) | MetalLB and NGINX Ingress setup |
| [MONITORING.md](MONITORING.md) | Prometheus, Grafana & external Docker monitoring |

### Reference Materials

| Document | Description |
|----------|-------------|
| [getting_started-talos_clustor.md](getting_started-talos_clustor.md) | Talos cluster basics |
| [talos-production_clusters.md](talos-production_clusters.md) | Production considerations |
| [talos-troubleshooting_support.md](talos-troubleshooting_support.md) | Troubleshooting guide |
| [support_matrix_talos-versions.md](support_matrix_talos-versions.md) | Talos version compatibility |
| [new_talos_1.11.0.md](new_talos_1.11.0.md) | Talos 1.11 features |

### NPU/AI Documentation

| Document | Description |
|----------|-------------|
| [01_Rockchip_RKNPU_Quick_Start_*.pdf](01_Rockchip_RKNPU_Quick_Start_RKNN_SDK_V2.3.2_EN.pdf) | RKNN SDK quick start |
| [02_Rockchip_RKNPU_User_Guide_*.pdf](02_Rockchip_RKNPU_User_Guide_RKNN_SDK_V2.3.2_EN.pdf) | RKNN user guide |
| [03_Rockchip_RKNPU_API_Reference_Toolkit2_*.pdf](03_Rockchip_RKNPU_API_Reference_RKNN_Toolkit2_V2.3.2_EN.pdf) | Toolkit2 API reference |
| [04_Rockchip_RKNPU_API_Reference_RKNNRT_*.pdf](04_Rockchip_RKNPU_API_Reference_RKNNRT_V2.3.2_EN.pdf) | Runtime API reference |
| [benchmark.md](benchmark.md) | RKNN performance benchmarks |

### Other References

| Document | Description |
|----------|-------------|
| [sidero_documentation.md](sidero_documentation.md) | Sidero Labs documentation |
| [sidero-sb-turing_rk1.txt](sidero-sb-turing_rk1.txt) | Turing RK1 specific notes |
| [installation_go-contrainerregistry.md](installation_go-contrainerregistry.md) | Container registry setup |
| [Compilation_Environment_Setup_Guide.md](Compilation_Environment_Setup_Guide.md) | Dev environment setup |

---

## Cluster Overview

### Hardware

- **4x Turing RK1** (RK3588 SoC, 8-core ARM64)
- **Turing Pi 2** BMC for management
- **500GB NVMe** per worker node
- **32GB eMMC** per node (system disk)

### Software Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| Talos Linux | v1.11.6 | Immutable Kubernetes OS |
| Kubernetes | v1.34.1 | Container orchestration |
| Longhorn | Latest | Distributed storage |
| MetalLB | Latest | LoadBalancer for bare-metal |
| NGINX Ingress | Latest | HTTP/HTTPS ingress |
| Prometheus | Latest | Metrics & monitoring |
| Grafana | Latest | Dashboards & visualization |
| Alertmanager | Latest | Alert management |
| Portainer Agent | v2.33.6 | Management UI |

### Network Topology

```
BMC: 10.10.88.70
├── Node 1 (CP):  10.10.88.73
├── Node 2 (W):   10.10.88.74
├── Node 3 (W):   10.10.88.75
└── Node 4 (W):   10.10.88.76

LoadBalancer IPs: 10.10.88.80-89
├── Ingress:      10.10.88.80
│   ├── grafana.local
│   ├── prometheus.local
│   ├── alertmanager.local
│   └── longhorn.local
└── Portainer:    10.10.88.81
```

---

## Important Notes

### NPU Support

The RK3588 NPU is **not currently supported** in Talos Linux. The mainline kernel does not include Rockchip's proprietary RKNPU driver. Options:

1. Wait for mainline NPU driver (in development)
2. Build custom Talos extension with RKNPU driver
3. Use alternative OS with Rockchip BSP kernel

### Security

- Keep `cluster-config/secrets.yaml` secure - it contains cluster credentials
- All namespaces running privileged workloads need the label:
  ```
  pod-security.kubernetes.io/enforce=privileged
  ```

### Backups

Recommended backup targets:
- `cluster-config/` directory (secrets, configs)
- Longhorn volume snapshots
- Application data via Longhorn backups

---

## Support

- [Talos Documentation](https://www.talos.dev/docs/)
- [Longhorn Documentation](https://longhorn.io/docs/)
- [Turing Pi Documentation](https://docs.turingpi.com/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [Grafana Dashboard Library](https://grafana.com/grafana/dashboards/)
- [Rockchip RKNN Documentation](../repo/rknn-toolkit2/)
