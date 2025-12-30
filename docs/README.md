# Turing RK1 Kubernetes Cluster Documentation

This repository contains documentation and configuration for running a 4-node Kubernetes cluster on Turing Pi 2.5 with RK1 compute modules.

## Installation Guides

Choose your preferred Kubernetes distribution:

| Guide | OS | Kubernetes | Best For |
|-------|-----|------------|----------|
| [INSTALLATION.md](INSTALLATION.md) | Talos Linux | Talos K8s | Production, Security |
| [INSTALLATION-K3S.md](INSTALLATION-K3S.md) | Armbian | K3s | Development, AI/ML |

## Quick Comparison

| Feature | Talos | K3s on Armbian |
|---------|-------|----------------|
| Shell Access | No (API only) | Yes (SSH) |
| Security | Hardened by default | Manual hardening |
| **NPU (6 TOPS)** | Not available | **Supported** |
| **GPU (Mali-G610)** | Not available | **Supported** |
| Debugging | talosctl | Standard Linux |
| Updates | Atomic | apt + reinstall |
| Learning Curve | Steeper | Gentler |

See [COMPARISON.md](COMPARISON.md) for the complete feature matrix.

## Cluster Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  Turing Pi 2.5 Board                     │
├─────────────┬─────────────┬─────────────┬─────────────┬─┤
│   Node 1    │   Node 2    │   Node 3    │   Node 4    │B│
│ Control     │   Worker    │   Worker    │   Worker    │M│
│ Plane       │             │             │             │C│
│ 10.10.88.73 │ 10.10.88.74 │ 10.10.88.75 │ 10.10.88.76 │ │
├─────────────┼─────────────┼─────────────┼─────────────┤ │
│ 32GB eMMC   │ 32GB eMMC   │ 32GB eMMC   │ 32GB eMMC   │ │
│ 500GB NVMe  │ 500GB NVMe  │ 500GB NVMe  │ 500GB NVMe  │ │
└─────────────┴─────────────┴─────────────┴─────────────┴─┘
```

## Common Components (Both Distributions)

Both installation methods deploy the same workloads:

- **MetalLB** - Load balancer (IP pool: 10.10.88.80-99)
- **NGINX Ingress** - Ingress controller at 10.10.88.80
- **Longhorn** - Distributed storage on NVMe drives
- **Prometheus Stack** - Monitoring (Grafana, Prometheus, Alertmanager)

## Access URLs

Add to `/etc/hosts`:
```
10.10.88.80  grafana.local prometheus.local alertmanager.local longhorn.local
```

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://grafana.local | admin / admin |
| Prometheus | http://prometheus.local | - |
| Alertmanager | http://alertmanager.local | - |

## Additional Documentation

- [QUICKREF.md](QUICKREF.md) - Quick reference card
- [STORAGE.md](STORAGE.md) - Storage configuration details
- [NETWORKING.md](NETWORKING.md) - Network configuration details
- [MONITORING.md](MONITORING.md) - Monitoring setup details

## Scripts

Helper scripts in `../scripts/`:

| Script | Purpose |
|--------|---------|
| `setup-k3s-node.sh` | Prepare Armbian node for K3s |
| `deploy-k3s-cluster.sh` | Deploy K3s cluster from workstation |
| `wipe-cluster.sh` | Reset cluster for distribution switch |

### Switching Distributions

Use `wipe-cluster.sh` to reset nodes when switching between Talos and K3s:

```bash
# View cluster status
./scripts/wipe-cluster.sh status

# Reset Talos cluster
./scripts/wipe-cluster.sh talos

# Uninstall K3s from Armbian
./scripts/wipe-cluster.sh k3s

# Full reset (power off for reflash)
./scripts/wipe-cluster.sh full
```
