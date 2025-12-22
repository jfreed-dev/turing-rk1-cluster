# Monitoring Configuration

This document covers the Prometheus and Grafana monitoring setup for the Turing RK1 cluster, including external Docker host monitoring.

## Overview

The monitoring stack includes:

| Component | Purpose | URL |
|-----------|---------|-----|
| Prometheus | Metrics collection & storage | http://prometheus.local |
| Grafana | Visualization & dashboards | http://grafana.local |
| Alertmanager | Alert routing | http://alertmanager.local |
| Node Exporter | Host metrics | Per-node |
| kube-state-metrics | Kubernetes state | Cluster-wide |

---

## Access URLs

Add these entries to `/etc/hosts` on your workstation:

```
10.10.88.80  grafana.local prometheus.local alertmanager.local
```

| Service | URL | Default Credentials |
|---------|-----|---------------------|
| Grafana | http://grafana.local | admin / admin |
| Prometheus | http://prometheus.local | N/A |
| Alertmanager | http://alertmanager.local | N/A |

### Get Grafana Password

```bash
kubectl --namespace monitoring get secrets prometheus-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d ; echo
```

---

## Monitoring External Docker Hosts

To monitor Docker containers running on external servers, you need to deploy exporters on those hosts.

### Option 1: Docker Compose Stack (Recommended)

Deploy this stack on each Docker host you want to monitor:

```yaml
# docker-compose.monitoring.yml
version: '3.8'

services:
  # Node Exporter - System metrics (CPU, memory, disk, network)
  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    pid: host
    network_mode: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    ports:
      - "9100:9100"

  # cAdvisor - Container metrics
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    restart: unless-stopped
    privileged: true
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    ports:
      - "8080:8080"

  # Docker daemon metrics (alternative to enabling daemon metrics)
  docker-exporter:
    image: prometheusnet/docker_exporter:latest
    container_name: docker-exporter
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "9417:9417"
```

Deploy with:

```bash
docker-compose -f docker-compose.monitoring.yml up -d
```

### Option 2: Enable Docker Daemon Metrics

Edit Docker daemon configuration on the host:

```bash
sudo nano /etc/docker/daemon.json
```

Add:

```json
{
  "metrics-addr": "0.0.0.0:9323",
  "experimental": true
}
```

Restart Docker:

```bash
sudo systemctl restart docker
```

---

## Configure Prometheus Scrape Targets

### Method 1: Update Helm Values

Edit `cluster-config/prometheus-values.yaml` and add your targets:

```yaml
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: 'docker-hosts'
        static_configs:
          - targets:
            - '192.168.1.100:9323'  # Docker daemon metrics
            - '192.168.1.101:9323'
        metrics_path: /metrics

      - job_name: 'docker-nodes'
        static_configs:
          - targets:
            - '192.168.1.100:9100'  # Node exporter
            - '192.168.1.101:9100'

      - job_name: 'docker-cadvisor'
        static_configs:
          - targets:
            - '192.168.1.100:8080'  # cAdvisor
            - '192.168.1.101:8080'
```

Apply changes:

```bash
helm --kubeconfig=kubeconfig upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f prometheus-values.yaml
```

### Method 2: Use ScrapeConfig CR

For Prometheus Operator, create a ScrapeConfig resource:

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  name: external-docker-hosts
  namespace: monitoring
  labels:
    prometheus: kube-prometheus
spec:
  staticConfigs:
    - labels:
        job: docker-nodes
      targets:
        - 192.168.1.100:9100
        - 192.168.1.101:9100
```

---

## Recommended Dashboards

### Import from Grafana.com

In Grafana, go to **Dashboards → Import** and enter the dashboard ID:

| Dashboard | ID | Description |
|-----------|-----|-------------|
| Node Exporter Full | 1860 | Comprehensive host metrics |
| Docker and System | 893 | Docker container monitoring |
| Docker Container | 11600 | Container details |
| Kubernetes Cluster | 6417 | K8s cluster overview |
| Kubernetes Pods | 6879 | Pod-level metrics |
| Longhorn | 13032 | Storage monitoring |

### Pre-installed Dashboards

The kube-prometheus-stack includes these dashboards:

- Kubernetes / API server
- Kubernetes / Compute Resources / Cluster
- Kubernetes / Compute Resources / Namespace
- Kubernetes / Compute Resources / Node
- Kubernetes / Compute Resources / Pod
- Kubernetes / Compute Resources / Workload
- Kubernetes / Kubelet
- Kubernetes / Networking
- Kubernetes / Persistent Volumes
- Node Exporter / Nodes
- Prometheus / Overview

---

## Longhorn Monitoring

### Enable ServiceMonitor

Create a ServiceMonitor for Longhorn:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: longhorn-prometheus-servicemonitor
  namespace: monitoring
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: longhorn-manager
  namespaceSelector:
    matchNames:
      - longhorn-system
  endpoints:
    - port: manager
      path: /metrics
```

Apply:

```bash
kubectl apply -f longhorn-servicemonitor.yaml
```

---

## Alert Configuration

### Example Alert Rules

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: custom-alerts
  namespace: monitoring
  labels:
    release: prometheus
spec:
  groups:
    - name: node-alerts
      rules:
        - alert: HighCPUUsage
          expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High CPU usage on {{ $labels.instance }}"
            description: "CPU usage is above 80% for more than 5 minutes."

        - alert: HighMemoryUsage
          expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High memory usage on {{ $labels.instance }}"

        - alert: DiskSpaceLow
          expr: (node_filesystem_avail_bytes{fstype!="tmpfs"} / node_filesystem_size_bytes{fstype!="tmpfs"}) * 100 < 15
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Low disk space on {{ $labels.instance }}"

    - name: docker-alerts
      rules:
        - alert: ContainerHighCPU
          expr: sum(rate(container_cpu_usage_seconds_total{name!=""}[5m])) by (name) * 100 > 80
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Container {{ $labels.name }} high CPU usage"

        - alert: ContainerHighMemory
          expr: (container_memory_usage_bytes{name!=""} / container_spec_memory_limit_bytes{name!=""}) * 100 > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Container {{ $labels.name }} high memory usage"
```

---

## Useful PromQL Queries

### Cluster Overview

```promql
# Total cluster CPU usage
sum(rate(node_cpu_seconds_total{mode!="idle"}[5m])) / sum(machine_cpu_cores) * 100

# Total cluster memory usage
sum(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes) * 100

# Pod count by namespace
count by (namespace) (kube_pod_info)
```

### Docker Container Metrics

```promql
# Container CPU usage
sum(rate(container_cpu_usage_seconds_total{name!=""}[5m])) by (name) * 100

# Container memory usage
container_memory_usage_bytes{name!=""} / 1024 / 1024

# Container network I/O
sum(rate(container_network_receive_bytes_total[5m])) by (name)
sum(rate(container_network_transmit_bytes_total[5m])) by (name)
```

### Storage Metrics

```promql
# Longhorn volume usage
longhorn_volume_actual_size_bytes / longhorn_volume_capacity_bytes * 100

# Node disk usage
(node_filesystem_size_bytes - node_filesystem_avail_bytes) / node_filesystem_size_bytes * 100
```

---

## Troubleshooting

### Prometheus Not Scraping Targets

1. Check target status in Prometheus UI → Status → Targets
2. Verify network connectivity:
   ```bash
   kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -- \
     wget -qO- http://192.168.1.100:9100/metrics | head
   ```
3. Check firewall rules on target hosts

### Grafana Dashboard Not Loading

1. Check data source configuration in Grafana
2. Verify Prometheus is running:
   ```bash
   kubectl get pods -n monitoring | grep prometheus
   ```
3. Check Grafana logs:
   ```bash
   kubectl logs -n monitoring -l app.kubernetes.io/name=grafana
   ```

### High Memory Usage

Reduce retention or scrape interval:

```yaml
prometheus:
  prometheusSpec:
    retention: 7d
    scrapeInterval: 60s
```

---

## Resource Usage

Expected resource consumption:

| Component | Memory | CPU |
|-----------|--------|-----|
| Prometheus | 512Mi - 2Gi | 250m - 1000m |
| Grafana | 256Mi - 512Mi | 100m - 500m |
| Alertmanager | 128Mi - 256Mi | 50m - 200m |
| Node Exporter | 64Mi per node | 50m per node |
| kube-state-metrics | 128Mi | 100m |

---

## Maintenance

### Compact Prometheus Data

```bash
kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -- \
  promtool tsdb compact /prometheus
```

### Backup Grafana Dashboards

```bash
# Export all dashboards
kubectl exec -n monitoring deployment/prometheus-grafana -- \
  grafana-cli admin export-all /tmp/dashboards
```

### Update Stack

```bash
helm repo update prometheus-community
helm --kubeconfig=kubeconfig upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f prometheus-values.yaml
```
