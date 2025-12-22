# Storage Configuration

This document covers the storage setup for the Turing RK1 Kubernetes cluster using Longhorn distributed storage with NVMe drives.

## Storage Overview

| Node | eMMC (System) | NVMe (Data) | Total Longhorn |
|------|---------------|-------------|----------------|
| turing-cp1 | 31GB | - | ~24GB |
| talos-0ow-v7t | 31GB | 500GB | ~481GB |
| talos-6ed-cqn | 31GB | 500GB | ~481GB |
| talos-700-itj | 31GB | 500GB | ~481GB |
| **Total** | | | **~1.47TB** |

---

## Longhorn Installation

### Prerequisites

The Talos image must include the `iscsi-tools` extension for Longhorn to function properly.

### Step 1: Add Helm Repository

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
```

### Step 2: Create Namespace

```bash
kubectl create namespace longhorn-system

# IMPORTANT: Label as privileged for Talos
kubectl label namespace longhorn-system pod-security.kubernetes.io/enforce=privileged
```

### Step 3: Install Longhorn

```bash
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set defaultSettings.defaultDataPath=/var/lib/longhorn \
  --wait
```

### Step 4: Verify Installation

```bash
kubectl get pods -n longhorn-system
kubectl get nodes.longhorn.io -n longhorn-system
```

---

## NVMe Configuration

The worker nodes have 500GB NVMe drives that need to be configured for Longhorn.

### Step 1: Create UserVolumeConfig

Apply this configuration to mount NVMe drives via Talos:

```yaml
# nvme-user-volume.yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn-storage
provisioning:
  diskSelector:
    match: disk.transport == "nvme"
  minSize: 100GB
  maxSize: 500GB
filesystem:
  type: ext4
```

Apply to all worker nodes:

```bash
talosctl -n 10.10.88.74,10.10.88.75,10.10.88.76 \
  apply-config --mode=no-reboot --config-patch @nvme-user-volume.yaml
```

### Step 2: Wipe Existing Partitions (if needed)

If the NVMe already has partitions, wipe them first:

```bash
# Wipe partition table on all workers
for node in 10.10.88.74 10.10.88.75 10.10.88.76; do
  talosctl -n $node wipe disk nvme0n1p1 --drop-partition
done
```

### Step 3: Verify Volume Status

```bash
# Check volume is ready on all workers
talosctl -n 10.10.88.74,10.10.88.75,10.10.88.76 get volumestatus u-longhorn-storage
```

Expected output:
```
NODE          NAMESPACE   TYPE           ID                   VERSION   TYPE        PHASE   LOCATION         SIZE
10.10.88.74   runtime     VolumeStatus   u-longhorn-storage   3         partition   ready   /dev/nvme0n1p1   500 GB
10.10.88.75   runtime     VolumeStatus   u-longhorn-storage   3         partition   ready   /dev/nvme0n1p1   500 GB
10.10.88.76   runtime     VolumeStatus   u-longhorn-storage   3         partition   ready   /dev/nvme0n1p1   500 GB
```

### Step 4: Add NVMe to Longhorn

Patch Longhorn node configurations to include the NVMe disk:

```yaml
# longhorn-node-patch.yaml
spec:
  disks:
    default-disk-b30600000000:
      allowScheduling: true
      diskType: filesystem
      evictionRequested: false
      path: /var/lib/longhorn
      storageReserved: 0
      tags: []
    nvme-storage:
      allowScheduling: true
      diskType: filesystem
      evictionRequested: false
      path: /var/mnt/longhorn-storage
      storageReserved: 0
      tags:
        - nvme
        - fast
```

Apply to worker nodes:

```bash
for node in talos-0ow-v7t talos-6ed-cqn talos-700-itj; do
  kubectl patch nodes.longhorn.io/$node -n longhorn-system \
    --type=merge --patch-file=longhorn-node-patch.yaml
done
```

### Step 5: Verify Disk Status

```bash
kubectl get nodes.longhorn.io -n longhorn-system -o yaml | grep -A5 "nvme-storage:"
```

---

## Storage Classes

### Default Storage Class

The default `longhorn` storage class uses any available disk:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "3"
  staleReplicaTimeout: "2880"
```

### NVMe-Only Storage Class

For high-performance workloads, use NVMe-only storage:

```yaml
# longhorn-nvme-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-nvme
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
  diskSelector: "nvme"
  fromBackup: ""
```

Apply:

```bash
kubectl apply -f longhorn-nvme-storageclass.yaml
```

---

## Using Storage

### Create a PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn-nvme  # or "longhorn" for default
  resources:
    requests:
      storage: 10Gi
```

### Use in a Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-data
```

---

## Longhorn UI Access

The Longhorn UI is available via ingress:

**URL:** http://10.10.88.80 (with `Host: longhorn.local` header)

Or add to `/etc/hosts`:
```
10.10.88.80  longhorn.local
```

Then browse to: http://longhorn.local

---

## Monitoring Storage

### Check Disk Usage

```bash
# Via kubectl
kubectl get nodes.longhorn.io -n longhorn-system \
  -o jsonpath='{range .items[*]}Node: {.metadata.name}{"\n"}{range .status.diskStatus.*}  {.diskName}: {.storageAvailable} available{"\n"}{end}{end}'

# Via Talos
talosctl -n 10.10.88.74 mounts | grep longhorn
```

### Check Volumes

```bash
kubectl get volumes.longhorn.io -n longhorn-system
kubectl get pvc -A
```

### Check Replicas

```bash
kubectl get replicas.longhorn.io -n longhorn-system \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeID,DISK:.spec.diskPath'
```

---

## Troubleshooting

### Volume Won't Provision

1. Check if disks are schedulable:
```bash
kubectl get nodes.longhorn.io -n longhorn-system -o yaml | grep -A10 "diskStatus:"
```

2. Check Longhorn manager logs:
```bash
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=50
```

### NVMe Not Detected

1. Verify Talos sees the device:
```bash
talosctl -n 10.10.88.74 get blockdevices | grep nvme
```

2. Check volume status:
```bash
talosctl -n 10.10.88.74 get volumestatus
```

### Disk Shows 0 Available

The disk path might not be mounted. Verify:
```bash
talosctl -n 10.10.88.74 mounts | grep longhorn-storage
```

---

## Backup and Recovery

### Enable Backups

Configure an S3-compatible backup target in Longhorn settings:

1. Open Longhorn UI
2. Go to Settings → General
3. Set Backup Target (e.g., `s3://bucket@region/`)
4. Set Backup Target Credential Secret

### Create Backup

```bash
kubectl -n longhorn-system annotate volume/<volume-name> \
  longhorn.io/backup-enabled=true
```

### Restore from Backup

1. In Longhorn UI, go to Backup
2. Select backup to restore
3. Click "Restore Latest Backup"
