# Quick Reference Card

## Cluster Access

```bash
# Set environment
export TALOSCONFIG=/home/jon/Code/turing-rk1-cluster/cluster-config/talosconfig
export KUBECONFIG=/home/jon/Code/turing-rk1-cluster/cluster-config/kubeconfig

# Or use explicit paths
kubectl --kubeconfig=/path/to/kubeconfig get nodes
talosctl --talosconfig=/path/to/talosconfig version
```

---

## IP Addresses

| Resource | IP Address | Port |
|----------|------------|------|
| **BMC** | 10.10.88.70 | 22 (SSH) |
| **Control Plane** | 10.10.88.73 | 6443 (API) |
| **Worker 1** | 10.10.88.74 | |
| **Worker 2** | 10.10.88.75 | |
| **Worker 3** | 10.10.88.76 | |
| **Ingress** | 10.10.88.80 | 80, 443 |
| **Portainer Agent** | 10.10.88.81 | 9001 |

---

## Common Commands

### Cluster Status

```bash
# Nodes
kubectl get nodes -o wide

# All pods
kubectl get pods -A

# System health
talosctl health

# Services with external IPs
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

### Talos Operations

```bash
# Node version
talosctl -n 10.10.88.73 version

# Node logs
talosctl -n 10.10.88.73 dmesg

# Service status
talosctl -n 10.10.88.73 services

# Reboot node
talosctl -n 10.10.88.74 reboot

# Upgrade Talos
talosctl -n 10.10.88.74 upgrade --image ghcr.io/siderolabs/installer:v1.11.6
```

### Storage

```bash
# Longhorn volumes
kubectl get volumes.longhorn.io -n longhorn-system

# PVCs
kubectl get pvc -A

# Disk status
kubectl get nodes.longhorn.io -n longhorn-system

# NVMe mounts
talosctl -n 10.10.88.74 mounts | grep nvme
```

### Networking

```bash
# Ingress resources
kubectl get ingress -A

# LoadBalancer services
kubectl get svc -A --field-selector spec.type=LoadBalancer

# MetalLB pools
kubectl get ipaddresspools -n metallb-system
```

### Monitoring

```bash
# Monitoring pods
kubectl get pods -n monitoring

# Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Then open http://localhost:9090/targets

# Grafana password
kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo

# Alertmanager alerts
kubectl get prometheusrules -A

# Check scrape configs
kubectl get servicemonitors -A
kubectl get podmonitors -A

# Prometheus storage usage
kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -- df -h /prometheus
```

---

## Web UIs

| Service | URL | Notes |
|---------|-----|-------|
| Grafana | http://grafana.local | Default: admin/admin |
| Prometheus | http://prometheus.local | Metrics & queries |
| Alertmanager | http://alertmanager.local | Alert management |
| Longhorn | http://longhorn.local | Storage management |
| Portainer | Your existing instance | Connect agent at 10.10.88.81:9001 |

Add to `/etc/hosts`:
```
10.10.88.80  grafana.local prometheus.local alertmanager.local longhorn.local
```

---

## Storage Classes

| Name | Replicas | Disk Selector | Use Case |
|------|----------|---------------|----------|
| `longhorn` | 3 | Any | Default, high availability |
| `longhorn-nvme` | 2 | NVMe only | High performance |

### Create PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-nvme
  resources:
    requests:
      storage: 10Gi
```

---

## Deploy Application

### Quick Deploy

```bash
# Create deployment
kubectl create deployment nginx --image=nginx --replicas=3

# Expose as LoadBalancer
kubectl expose deployment nginx --port=80 --type=LoadBalancer

# Create ingress
kubectl create ingress nginx --rule="nginx.local/*=nginx:80"
```

### With Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
spec:
  ingressClassName: nginx
  rules:
    - host: myapp.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
```

---

## BMC Operations

```bash
# SSH to BMC
ssh turing-bmc

# Power status
tpi power status

# Power on/off
tpi power on -n 1,2,3,4
tpi power off -n 1,2,3,4

# Flash node
tpi flash -n 1 -i /tmp/image.raw
```

---

## Troubleshooting

### Pod Issues

```bash
# Describe pod
kubectl describe pod <name> -n <namespace>

# Pod logs
kubectl logs <pod> -n <namespace>

# Pod shell
kubectl exec -it <pod> -n <namespace> -- /bin/sh
```

### Node Issues

```bash
# Talos services
talosctl -n <ip> services

# Talos logs
talosctl -n <ip> logs kubelet

# System info
talosctl -n <ip> get members
```

### Storage Issues

```bash
# Longhorn manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=100

# Volume status
kubectl describe volume <name> -n longhorn-system
```

### Network Issues

```bash
# Ingress controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx

# MetalLB logs
kubectl logs -n metallb-system -l app.kubernetes.io/name=metallb

# Test ingress
curl -v -H "Host: myapp.local" http://10.10.88.80/
```

### Monitoring Issues

```bash
# Prometheus operator logs
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-operator

# Prometheus logs
kubectl logs -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -c prometheus

# Grafana logs
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana

# Check if targets are being scraped
curl -s http://prometheus.local/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
```

---

## Namespace Security

Most add-ons require privileged namespace for Talos:

```bash
kubectl label namespace <name> pod-security.kubernetes.io/enforce=privileged
```

---

## File Locations

| File | Purpose |
|------|---------|
| `cluster-config/talosconfig` | Talos CLI configuration |
| `cluster-config/kubeconfig` | Kubernetes access |
| `cluster-config/secrets.yaml` | Cluster secrets (keep secure!) |
| `cluster-config/controlplane.yaml` | Control plane config |
| `cluster-config/worker.yaml` | Worker config |
| `cluster-config/prometheus-values.yaml` | Monitoring stack config |
| `cluster-config/external-scrape-config.yaml` | External Docker targets |
| `images/latest/metal-arm64.raw` | Talos image for flashing |

---

## Maintenance Windows

### Drain Node

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```

### Uncordon Node

```bash
kubectl uncordon <node>
```

### Rolling Restart

```bash
kubectl rollout restart deployment/<name> -n <namespace>
```
