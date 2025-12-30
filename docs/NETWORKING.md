# Networking Configuration

This document covers the networking setup for the Turing RK1 Kubernetes cluster, including MetalLB load balancing and NGINX Ingress Controller.

## Network Architecture

```
                    ┌─────────────────────────────────────────┐
                    │           External Network              │
                    │            10.10.88.0/24                │
                    └───────────────┬─────────────────────────┘
                                    │
                    ┌───────────────┴─────────────────────────┐
                    │         Turing Pi 2 BMC                 │
                    │           10.10.88.70                   │
                    └───────────────┬─────────────────────────┘
                                    │
        ┌───────────┬───────────────┼───────────────┬───────────┐
        │           │               │               │           │
   ┌────┴────┐ ┌────┴────┐    ┌────┴────┐    ┌────┴────┐      │
   │ Node 1  │ │ Node 2  │    │ Node 3  │    │ Node 4  │      │
   │   CP    │ │ Worker  │    │ Worker  │    │ Worker  │      │
   │ .73     │ │ .74     │    │ .75     │    │ .76     │      │
   └─────────┘ └─────────┘    └─────────┘    └─────────┘      │
                                                               │
                    ┌─────────────────────────────────────────┘
                    │
                    │  MetalLB Virtual IPs
                    │  ┌─────────────────────────────────┐
                    │  │ 10.10.88.80 - Ingress Controller│
                    │  │ 10.10.88.81 - Portainer Agent   │
                    │  │ 10.10.88.82-89 - Available      │
                    │  └─────────────────────────────────┘
```

---

## IP Address Allocation

### Static Assignments

| Purpose | IP Address |
|---------|------------|
| BMC | 10.10.88.70 |
| Control Plane | 10.10.88.73 |
| Worker 1 | 10.10.88.74 |
| Worker 2 | 10.10.88.75 |
| Worker 3 | 10.10.88.76 |

### MetalLB Pool

| IP Range | Purpose |
|----------|---------|
| 10.10.88.80 | NGINX Ingress Controller |
| 10.10.88.81 | Portainer Agent |
| 10.10.88.82-89 | Available for services |

### Kubernetes Networks

| Network | CIDR |
|---------|------|
| Pod Network | 10.244.0.0/16 |
| Service Network | 10.96.0.0/12 |

---

## MetalLB Installation

MetalLB provides LoadBalancer functionality for bare-metal clusters.

### Step 1: Add Helm Repository

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
```

### Step 2: Create Namespace

```bash
kubectl create namespace metallb-system

# Label as privileged for Talos
kubectl label namespace metallb-system pod-security.kubernetes.io/enforce=privileged
```

### Step 3: Install MetalLB

```bash
helm install metallb metallb/metallb -n metallb-system --wait
```

### Step 4: Configure IP Pool

```yaml
# metallb-config.yaml
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.10.88.80-10.10.88.89
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
```

Apply:

```bash
kubectl apply -f metallb-config.yaml
```

### Step 5: Verify

```bash
kubectl get pods -n metallb-system
kubectl get ipaddresspools -n metallb-system
```

---

## NGINX Ingress Controller

### Step 1: Add Helm Repository

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

### Step 2: Create Namespace

```bash
kubectl create namespace ingress-nginx
kubectl label namespace ingress-nginx pod-security.kubernetes.io/enforce=privileged
```

### Step 3: Install

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  --set controller.service.type=LoadBalancer \
  --set controller.ingressClassResource.default=true \
  --wait
```

### Step 4: Verify

```bash
kubectl get svc -n ingress-nginx
kubectl get pods -n ingress-nginx
```

Expected output:
```
NAME                       TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)
ingress-nginx-controller   LoadBalancer   10.111.58.78   10.10.88.80   80:32072/TCP,443:30100/TCP
```

---

## Creating Ingress Resources

### Basic HTTP Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  namespace: default
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

### Ingress with TLS

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress-tls
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - myapp.example.com
      secretName: myapp-tls
  rules:
    - host: myapp.example.com
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

### Path-Based Routing

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: multi-path-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
    - host: apps.local
      http:
        paths:
          - path: /api(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-service
                port:
                  number: 8080
          - path: /web(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: web-service
                port:
                  number: 80
```

---

## Configured Ingress Resources

### Longhorn UI

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ingress
  namespace: longhorn-system
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: nginx
  rules:
    - host: longhorn.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: longhorn-frontend
                port:
                  number: 80
```

**Access:** Add to `/etc/hosts`:
```
10.10.88.80  longhorn.local
```

---

## LoadBalancer Services

### View All LoadBalancer Services

```bash
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

### Create a LoadBalancer Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-lb-service
  namespace: default
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

### Request Specific IP

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-lb-service
  namespace: default
  annotations:
    metallb.universe.tf/loadBalancerIPs: "10.10.88.85"
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

---

## DNS Configuration

### Local Development

Add entries to `/etc/hosts` on your workstation:

```
10.10.88.80  longhorn.local
10.10.88.80  myapp.local
10.10.88.80  dashboard.local
```

### Production DNS

For production, configure DNS A records:

```
*.apps.example.com  ->  10.10.88.80
```

---

## Useful Annotations

### NGINX Ingress Annotations

```yaml
annotations:
  # SSL/TLS
  nginx.ingress.kubernetes.io/ssl-redirect: "true"
  nginx.ingress.kubernetes.io/force-ssl-redirect: "true"

  # Timeouts
  nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
  nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
  nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"

  # Body size
  nginx.ingress.kubernetes.io/proxy-body-size: "100m"

  # Authentication
  nginx.ingress.kubernetes.io/auth-type: basic
  nginx.ingress.kubernetes.io/auth-secret: basic-auth
  nginx.ingress.kubernetes.io/auth-realm: "Authentication Required"

  # CORS
  nginx.ingress.kubernetes.io/enable-cors: "true"
  nginx.ingress.kubernetes.io/cors-allow-origin: "*"

  # WebSocket
  nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
  nginx.ingress.kubernetes.io/upstream-hash-by: "$request_uri"
```

---

## Troubleshooting

### No External IP Assigned

1. Check MetalLB pods:
```bash
kubectl get pods -n metallb-system
kubectl logs -n metallb-system -l app.kubernetes.io/name=metallb
```

2. Check IP pool configuration:
```bash
kubectl get ipaddresspools -n metallb-system -o yaml
```

3. Check L2Advertisement:
```bash
kubectl get l2advertisements -n metallb-system -o yaml
```

### Ingress Not Working

1. Check ingress controller:
```bash
kubectl get pods -n ingress-nginx
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
```

2. Check ingress resource:
```bash
kubectl describe ingress <name> -n <namespace>
```

3. Test directly:
```bash
curl -H "Host: myapp.local" http://10.10.88.80/
```

### Connection Refused

1. Verify service exists:
```bash
kubectl get svc -n <namespace>
```

2. Check endpoints:
```bash
kubectl get endpoints <service-name> -n <namespace>
```

3. Check pod is running:
```bash
kubectl get pods -n <namespace> -l <selector>
```

---

## Security Considerations

### Network Policies

Restrict traffic between namespaces:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### Rate Limiting

```yaml
annotations:
  nginx.ingress.kubernetes.io/limit-rps: "10"
  nginx.ingress.kubernetes.io/limit-connections: "5"
```

### IP Whitelisting

```yaml
annotations:
  nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8,192.168.0.0/16"
```
