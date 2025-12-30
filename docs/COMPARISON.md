# Talos vs K3s Comparison Matrix

This document provides a comprehensive comparison between the two Kubernetes distributions supported for the Turing RK1 cluster.

## Quick Decision Guide

| If you need... | Choose |
|----------------|--------|
| Maximum security and immutability | **Talos** |
| NPU/GPU hardware acceleration | **K3s on Armbian** |
| SSH access to nodes | **K3s on Armbian** |
| Minimal attack surface | **Talos** |
| Easier debugging and learning | **K3s on Armbian** |
| Production-grade hardening | **Talos** |
| Custom kernel modules | **K3s on Armbian** |

---

## Feature Comparison Matrix

### Core Features

| Feature | Talos Linux | K3s on Armbian |
|---------|-------------|----------------|
| **Kubernetes Version** | v1.34.1 | v1.31.x (latest) |
| **Container Runtime** | containerd v2.1.5 | containerd |
| **etcd** | Bundled (Talos managed) | Bundled (SQLite or etcd) |
| **CNI** | Flannel (bundled) | Flannel (default) |
| **Kernel** | Mainline 6.12.x | Rockchip BSP 5.10.x / 6.1.x |
| **Init System** | None (API-driven) | systemd |
| **Package Manager** | Extensions only | apt (full Debian) |

### Security

| Feature | Talos Linux | K3s on Armbian |
|---------|-------------|----------------|
| **SSH Access** | No | Yes |
| **Root Shell** | No | Yes |
| **Filesystem** | Immutable (read-only) | Mutable |
| **Attack Surface** | Minimal | Standard Linux |
| **Configuration** | API-only | Files + SSH |
| **Secrets Management** | Encrypted at rest | User-managed |
| **Updates** | Atomic A/B | apt upgrade + restart |
| **CIS Benchmarks** | Pre-hardened | Manual hardening |

### Hardware Support

| Feature | Talos Linux | K3s on Armbian |
|---------|-------------|----------------|
| **CPU** | Full support | Full support |
| **RAM** | Full support | Full support |
| **eMMC Boot** | Supported | Supported |
| **NVMe Storage** | Supported | Supported |
| **NPU (6 TOPS)** | Not available | **Supported** |
| **GPU (Mali-G610)** | Not available | **Supported** |
| **Hardware Video Decode** | Not available | **Supported** |

### NPU/AI Hardware Access

| Capability | Talos Linux | K3s on Armbian |
|------------|-------------|----------------|
| **RKNN Runtime** | Not supported | **Full support** |
| **RKLLM (LLM inference)** | Not supported | **Full support** |
| **6 TOPS INT8** | Not available | **Available** |
| **Model Conversion** | Not supported | **Supported** |
| **Hardware Video Encode** | Not available | **Supported** |
| **OpenCL** | Not available | **Supported** |

### Management

| Feature | Talos Linux | K3s on Armbian |
|---------|-------------|----------------|
| **Primary CLI** | talosctl | kubectl + SSH |
| **Node Access** | API only | SSH + API |
| **Log Access** | talosctl logs | journalctl / kubectl |
| **File Inspection** | talosctl read | cat, vim, etc. |
| **Process Debugging** | Limited | Full (strace, gdb) |
| **Package Installation** | Extensions only | apt install |
| **Learning Curve** | Steeper | Gentler |

### Operations

| Feature | Talos Linux | K3s on Armbian |
|---------|-------------|----------------|
| **Node Reset** | `talosctl reset` | SSH + reinstall |
| **Config Changes** | Apply new config | Edit files + restart |
| **Version Upgrades** | `talosctl upgrade` | Script-based |
| **Backup** | etcd snapshot | etcd + filesystem |
| **Recovery** | Bootstrap from snapshot | Multiple options |
| **Multi-node Join** | Apply config | Token + script |

---

## Workload Stack Comparison

Both distributions deploy the same Kubernetes workloads:

| Component | Version | Purpose | Notes |
|-----------|---------|---------|-------|
| **MetalLB** | v0.14.9 | LoadBalancer | L2 mode, IP pool 10.10.88.80-99 |
| **NGINX Ingress** | Latest | Ingress Controller | External IP: 10.10.88.80 |
| **Longhorn** | v1.7.2 | Distributed Storage | NVMe-backed on workers |
| **Prometheus Stack** | Latest | Monitoring | Grafana + Alertmanager |

---

## NPU/GPU Support Details (K3s Only)

### Available Capabilities

The RK3588 SoC in each RK1 module includes:

| Component | Specification | K3s Support |
|-----------|---------------|-------------|
| **NPU** | 6 TOPS INT8 | Full |
| **NPU Precision** | INT4/INT8/INT16/FP16/BF16 | Full |
| **GPU** | Mali-G610 MP4 | OpenCL/Vulkan |
| **VPU** | 8K H.265/VP9 decode | Full |
| **VPU** | 8K H.264 encode | Full |

### RKNN Toolkit Setup

```bash
# Install RKNN runtime on each node
apt install -y python3-pip libopencv-dev
pip3 install rknn-toolkit2-lite2

# Verify NPU access
python3 -c "from rknnlite.api import RKNNLite; print('NPU available')"
```

### RKLLM Setup (LLM Inference)

```bash
# Install RKLLM runtime
pip3 install rkllm

# Run inference (example)
rkllm-server --model /path/to/model.rkllm --port 8080
```

### Example Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rknn-inference
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rknn-inference
  template:
    metadata:
      labels:
        app: rknn-inference
    spec:
      containers:
      - name: inference
        image: your-rknn-image:latest
        securityContext:
          privileged: true  # Required for NPU access
        volumeMounts:
        - name: npu-device
          mountPath: /dev/dri
        resources:
          limits:
            memory: "4Gi"
            cpu: "2"
      volumes:
      - name: npu-device
        hostPath:
          path: /dev/dri
          type: Directory
```

---

## When to Choose Each Distribution

### Choose Talos Linux When

1. **Security is paramount** - Immutable OS, no shell access, minimal attack surface
2. **Production workloads** - Pre-hardened, atomic updates, API-driven management
3. **Compliance requirements** - Meets security benchmarks out of the box
4. **GitOps workflows** - Configuration as code, declarative management
5. **Standard Kubernetes workloads** - No special hardware requirements

### Choose K3s on Armbian When

1. **NPU/GPU required** - AI inference, model serving, hardware acceleration
2. **Learning Kubernetes** - SSH access makes debugging easier
3. **Custom kernel needs** - Hardware video, special drivers
4. **Development clusters** - Quick iteration, easy debugging
5. **Edge AI workloads** - RKNN, RKLLM, OpenCV with hardware acceleration

---

## Migration Paths

### Talos to K3s

1. Backup workloads and PVCs
2. Flash Armbian to nodes using TPI
3. Run node setup script
4. Deploy K3s cluster
5. Restore workloads

### K3s to Talos

1. Backup workloads and PVCs
2. Flash Talos image to nodes using TPI
3. Generate and apply Talos configs
4. Bootstrap cluster
5. Restore workloads

See [wipe-cluster.sh](../scripts/wipe-cluster.sh) for automated cluster reset between distributions.

---

## Performance Considerations

### CPU Performance

Both distributions offer equivalent CPU performance for Kubernetes workloads.

### Storage Performance

| Metric | Talos | K3s/Armbian |
|--------|-------|-------------|
| Sequential Read | ~3000 MB/s | ~3000 MB/s |
| Sequential Write | ~2000 MB/s | ~2000 MB/s |
| Random 4K IOPS | ~300K | ~300K |

NVMe performance is equivalent on both distributions.

### AI Inference Performance (K3s Only)

| Model Type | Talos | K3s/Armbian |
|------------|-------|-------------|
| ResNet-50 (CPU) | ~50ms | ~50ms |
| ResNet-50 (NPU) | N/A | **~8ms** |
| YOLO v5 (CPU) | ~200ms | ~200ms |
| YOLO v5 (NPU) | N/A | **~25ms** |
| LLM (1B params) | CPU only | **NPU accelerated** |

---

## Summary

| Aspect | Winner |
|--------|--------|
| Security | Talos |
| Hardware Access | K3s/Armbian |
| Ease of Use | K3s/Armbian |
| Production Readiness | Talos |
| AI/ML Workloads | K3s/Armbian |
| Debugging | K3s/Armbian |
| Updates/Maintenance | Talos |
