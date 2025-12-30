#!/bin/bash
# Deploy K3s Cluster to Turing RK1 nodes
# Run from workstation with SSH access to all nodes

set -e

# Node configuration
SERVER_IP="10.10.88.73"
AGENT_IPS=("10.10.88.74" "10.10.88.75" "10.10.88.76")
SSH_USER="root"

echo "=== K3s Cluster Deployment ==="
echo "Server: $SERVER_IP"
echo "Agents: ${AGENT_IPS[*]}"
echo ""

# Install K3s Server
echo "[1/4] Installing K3s Server on $SERVER_IP..."
ssh $SSH_USER@$SERVER_IP << 'REMOTE_SCRIPT'
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --disable=traefik \
  --disable=servicelb \
  --write-kubeconfig-mode=644 \
  --tls-san=10.10.88.73 \
  --node-name=k3s-server \
  --flannel-backend=vxlan
REMOTE_SCRIPT

echo "Waiting for server to be ready..."
sleep 30

# Get token
echo "[2/4] Getting node token..."
K3S_TOKEN=$(ssh $SSH_USER@$SERVER_IP "cat /var/lib/rancher/k3s/server/node-token")
echo "Token retrieved"

# Install K3s Agents
echo "[3/4] Installing K3s Agents..."
for i in "${!AGENT_IPS[@]}"; do
  AGENT_IP="${AGENT_IPS[$i]}"
  AGENT_NAME="k3s-agent-$((i+1))"
  echo "  Installing on $AGENT_IP ($AGENT_NAME)..."
  ssh $SSH_USER@$AGENT_IP << REMOTE_SCRIPT
curl -sfL https://get.k3s.io | K3S_URL=https://$SERVER_IP:6443 K3S_TOKEN=$K3S_TOKEN sh -s - agent \
  --node-name=$AGENT_NAME
REMOTE_SCRIPT
done

# Get kubeconfig
echo "[4/4] Retrieving kubeconfig..."
mkdir -p ~/.kube
scp $SSH_USER@$SERVER_IP:/etc/rancher/k3s/k3s.yaml ~/.kube/config-k3s-turing
sed -i "s/127.0.0.1/$SERVER_IP/g" ~/.kube/config-k3s-turing

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Set kubeconfig:"
echo "  export KUBECONFIG=~/.kube/config-k3s-turing"
echo ""
echo "Verify cluster:"
echo "  kubectl get nodes -o wide"
