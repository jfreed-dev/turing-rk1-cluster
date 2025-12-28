# Cluster Architecture

This document provides visual architecture diagrams for the Turing RK1 Kubernetes cluster.

## High-Level Overview

```mermaid
flowchart TB
    subgraph External["External Network (10.10.88.0/24)"]
        Client[Client Workstation]
        DNS[DNS / /etc/hosts]
    end

    subgraph TuringPi["Turing Pi 2 Board"]
        BMC["BMC Controller<br/>10.10.88.70"]

        subgraph Nodes["Compute Nodes"]
            subgraph CP["Control Plane"]
                N1["Node 1 (turing-cp1)<br/>10.10.88.73<br/>32GB eMMC"]
            end

            subgraph Workers["Worker Nodes"]
                N2["Node 2<br/>10.10.88.74<br/>32GB + 500GB NVMe"]
                N3["Node 3<br/>10.10.88.75<br/>32GB + 500GB NVMe"]
                N4["Node 4<br/>10.10.88.76<br/>32GB + 500GB NVMe"]
            end
        end
    end

    subgraph VIPs["MetalLB Virtual IPs"]
        VIP1["10.10.88.80<br/>Ingress Controller"]
        VIP2["10.10.88.81<br/>Portainer Agent"]
        VIP3["10.10.88.82-89<br/>Available Pool"]
    end

    Client --> DNS
    DNS --> VIP1
    Client --> BMC
    BMC --> N1
    BMC --> N2
    BMC --> N3
    BMC --> N4

    N1 --> VIPs
    N2 --> VIPs
    N3 --> VIPs
    N4 --> VIPs
```

## Kubernetes Architecture

```mermaid
flowchart TB
    subgraph ControlPlane["Control Plane (Node 1)"]
        API["kube-apiserver<br/>:6443"]
        ETCD["etcd<br/>Cluster State"]
        Sched["kube-scheduler"]
        CM["controller-manager"]

        API <--> ETCD
        API --> Sched
        API --> CM
    end

    subgraph WorkerNodes["Worker Nodes (Nodes 2-4)"]
        subgraph W1["Worker 1"]
            Kubelet1["kubelet"]
            Containerd1["containerd"]
            Flannel1["flannel"]
        end

        subgraph W2["Worker 2"]
            Kubelet2["kubelet"]
            Containerd2["containerd"]
            Flannel2["flannel"]
        end

        subgraph W3["Worker 3"]
            Kubelet3["kubelet"]
            Containerd3["containerd"]
            Flannel3["flannel"]
        end
    end

    subgraph Networking["Networking Layer"]
        MetalLB["MetalLB<br/>L2 LoadBalancer"]
        Ingress["NGINX Ingress<br/>Controller"]
    end

    API --> Kubelet1
    API --> Kubelet2
    API --> Kubelet3

    Kubelet1 --> Containerd1
    Kubelet2 --> Containerd2
    Kubelet3 --> Containerd3

    Flannel1 <--> Flannel2
    Flannel2 <--> Flannel3
    Flannel1 <--> Flannel3

    MetalLB --> Ingress
```

## Storage Architecture

```mermaid
flowchart TB
    subgraph StorageLayer["Longhorn Distributed Storage"]
        LM["Longhorn Manager"]
        LE["Longhorn Engine"]

        subgraph Node2Storage["Worker 1 Storage"]
            eMMC2["eMMC<br/>31GB"]
            NVMe2["NVMe<br/>500GB"]
            LR2["Longhorn<br/>Replica"]
        end

        subgraph Node3Storage["Worker 2 Storage"]
            eMMC3["eMMC<br/>31GB"]
            NVMe3["NVMe<br/>500GB"]
            LR3["Longhorn<br/>Replica"]
        end

        subgraph Node4Storage["Worker 3 Storage"]
            eMMC4["eMMC<br/>31GB"]
            NVMe4["NVMe<br/>500GB"]
            LR4["Longhorn<br/>Replica"]
        end
    end

    subgraph K8sStorage["Kubernetes Storage"]
        SC["StorageClass<br/>longhorn / longhorn-nvme"]
        PVC["PersistentVolumeClaim"]
        PV["PersistentVolume"]
    end

    subgraph Pods["Application Pods"]
        Pod1["Pod with<br/>Volume Mount"]
    end

    Pod1 --> PVC
    PVC --> SC
    SC --> LM
    LM --> LE

    LE --> LR2
    LE --> LR3
    LE --> LR4

    LR2 --> NVMe2
    LR3 --> NVMe3
    LR4 --> NVMe4

    NVMe2 <-.->|Replication| NVMe3
    NVMe3 <-.->|Replication| NVMe4
    NVMe2 <-.->|Replication| NVMe4
```

## Network Traffic Flow

```mermaid
flowchart LR
    subgraph External["External"]
        User["User<br/>Browser/CLI"]
    end

    subgraph LoadBalancer["Load Balancer Layer"]
        MetalLB["MetalLB<br/>10.10.88.80-89"]
    end

    subgraph Ingress["Ingress Layer"]
        NGINX["NGINX Ingress<br/>10.10.88.80"]
    end

    subgraph Services["Kubernetes Services"]
        SVC1["ClusterIP<br/>10.96.x.x"]
        SVC2["NodePort"]
        SVC3["LoadBalancer"]
    end

    subgraph PodNetwork["Pod Network (10.244.0.0/16)"]
        Pod1["Pod<br/>10.244.1.x"]
        Pod2["Pod<br/>10.244.2.x"]
        Pod3["Pod<br/>10.244.3.x"]
    end

    User -->|HTTP/HTTPS| MetalLB
    MetalLB --> NGINX
    NGINX --> SVC1
    SVC1 --> Pod1
    SVC1 --> Pod2

    User -->|Direct LB| SVC3
    SVC3 --> MetalLB
    MetalLB --> Pod3
```

## Monitoring Stack

```mermaid
flowchart TB
    subgraph Targets["Scrape Targets"]
        NodeExp["Node Exporter<br/>(per node)"]
        KSM["kube-state-metrics"]
        Kubelet["Kubelet Metrics"]
        LH["Longhorn Metrics"]
        ExtDocker["External Docker<br/>Hosts (optional)"]
    end

    subgraph Monitoring["monitoring namespace"]
        Prom["Prometheus<br/>prometheus.local"]
        AM["Alertmanager<br/>alertmanager.local"]
        Graf["Grafana<br/>grafana.local"]
    end

    subgraph Notification["Notifications"]
        Email["Email"]
        Slack["Slack"]
        Webhook["Webhooks"]
    end

    NodeExp --> Prom
    KSM --> Prom
    Kubelet --> Prom
    LH --> Prom
    ExtDocker -.-> Prom

    Prom --> AM
    Prom --> Graf

    AM --> Email
    AM --> Slack
    AM --> Webhook
```

## Component Namespaces

```mermaid
flowchart TB
    subgraph kube-system["kube-system namespace"]
        CoreDNS["coredns"]
        KubeProxy["kube-proxy"]
        FlannelNS["flannel"]
    end

    subgraph metallb-system["metallb-system namespace"]
        MetalLBCtrl["metallb-controller"]
        MetalLBSpkr["metallb-speaker"]
    end

    subgraph ingress-nginx["ingress-nginx namespace"]
        IngressCtrl["ingress-nginx-controller"]
    end

    subgraph longhorn-system["longhorn-system namespace"]
        LonghornMgr["longhorn-manager"]
        LonghornUI["longhorn-ui"]
        LonghornDriver["longhorn-csi-driver"]
    end

    subgraph monitoring["monitoring namespace"]
        PromOp["prometheus-operator"]
        PromServer["prometheus-server"]
        GrafanaSvc["grafana"]
        AlertMgr["alertmanager"]
        NodeExporter["node-exporter"]
        KubeStateMetrics["kube-state-metrics"]
    end

    subgraph portainer["portainer namespace"]
        PortainerAgent["portainer-agent"]
    end

    subgraph default["default namespace"]
        UserApps["User Applications"]
    end
```

## Hardware Specifications

```mermaid
flowchart TB
    subgraph RK1["Turing RK1 Module (x4)"]
        subgraph SoC["Rockchip RK3588"]
            CPU["CPU<br/>4x A76 @ 2.4GHz<br/>4x A55 @ 1.8GHz"]
            GPU["GPU<br/>Mali-G610 MP4<br/>(Not Available)"]
            NPU["NPU<br/>6 TOPS INT8<br/>(Not Available)"]
        end

        RAM["RAM<br/>16GB/32GB<br/>LPDDR4X"]

        subgraph Storage["Storage"]
            eMMC["eMMC<br/>32GB"]
            NVMe["NVMe Slot<br/>500GB Crucial P3"]
        end

        NIC["Network<br/>1Gbps Ethernet"]
    end

    subgraph TuringPi2["Turing Pi 2 Board"]
        BMC2["BMC<br/>Management"]
        Slots["4x Module Slots"]
        PSU["Power<br/>~40W Total"]
    end

    RK1 --> Slots
    BMC2 --> Slots
```

## IP Address Map

| Resource | IP Address | Port(s) | Purpose |
|----------|------------|---------|---------|
| BMC | 10.10.88.70 | 22, 80 | Board management |
| Control Plane | 10.10.88.73 | 6443, 50000 | K8s API, talosctl |
| Worker 1 | 10.10.88.74 | 50000 | talosctl |
| Worker 2 | 10.10.88.75 | 50000 | talosctl |
| Worker 3 | 10.10.88.76 | 50000 | talosctl |
| Ingress VIP | 10.10.88.80 | 80, 443 | HTTP/HTTPS traffic |
| Portainer VIP | 10.10.88.81 | 9001 | Portainer agent |
| Available | 10.10.88.82-89 | - | Future services |

## Network CIDRs

| Network | CIDR | Purpose |
|---------|------|---------|
| External | 10.10.88.0/24 | Physical network |
| Pod Network | 10.244.0.0/16 | Container IPs (Flannel) |
| Service Network | 10.96.0.0/12 | ClusterIP services |
| MetalLB Pool | 10.10.88.80-89 | LoadBalancer VIPs |

## Data Flow Example: Web Request

```mermaid
sequenceDiagram
    participant User
    participant DNS
    participant MetalLB
    participant Ingress as NGINX Ingress
    participant Service as K8s Service
    participant Pod

    User->>DNS: Resolve app.local
    DNS-->>User: 10.10.88.80
    User->>MetalLB: HTTP Request :80
    MetalLB->>Ingress: Forward to Ingress Pod
    Ingress->>Ingress: Match Host/Path Rules
    Ingress->>Service: Route to Backend Service
    Service->>Pod: Load Balance to Pod
    Pod-->>Service: Response
    Service-->>Ingress: Response
    Ingress-->>MetalLB: Response
    MetalLB-->>User: HTTP Response
```

## Deployment Dependencies

```mermaid
flowchart TD
    Talos["Talos Linux<br/>(Base OS)"] --> K8s["Kubernetes<br/>(Orchestration)"]
    K8s --> CoreDNS["CoreDNS"]
    K8s --> Flannel["Flannel CNI"]

    Flannel --> MetalLB["MetalLB"]
    MetalLB --> Ingress["NGINX Ingress"]

    K8s --> Longhorn["Longhorn Storage"]

    Ingress --> Monitoring["Prometheus Stack"]
    Longhorn --> Monitoring

    Ingress --> Portainer["Portainer Agent"]

    Monitoring --> Grafana["Grafana Dashboards"]

    Longhorn --> Apps["User Applications"]
    Ingress --> Apps
```

## Rendering These Diagrams

These diagrams use [Mermaid](https://mermaid.js.org/) syntax and can be rendered:

1. **GitHub**: Automatically renders in README/docs
2. **VS Code**: Install "Markdown Preview Mermaid Support" extension
3. **CLI**: Use `mmdc` from mermaid-cli (`npm install -g @mermaid-js/mermaid-cli`)
4. **Online**: Paste into [Mermaid Live Editor](https://mermaid.live/)

To generate PNG/SVG images:

```bash
# Install mermaid-cli
npm install -g @mermaid-js/mermaid-cli

# Generate images
mmdc -i ARCHITECTURE.md -o architecture.png
```
