#!/bin/bash
# Cluster Wipe Script for Turing RK1
# Prepares nodes for switching between Talos and K3s distributions
#
# Usage: ./wipe-cluster.sh [talos|k3s|full]
#   talos - Wipe for Talos installation (resets Talos nodes)
#   k3s   - Wipe for K3s installation (uninstalls K3s from Armbian)
#   full  - Full node wipe via BMC (reflash required)

set -e

# Configuration
BMC_IP="${BMC_IP:-10.10.88.70}"
BMC_USER="${BMC_USER:-root}"
NODES=(1 2 3 4)
NODE_IPS=("10.10.88.73" "10.10.88.74" "10.10.88.75" "10.10.88.76")
SSH_USER="${SSH_USER:-root}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${GREEN}=== $1 ===${NC}\n"
}

print_warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

print_error() {
    echo -e "${RED}ERROR: $1${NC}"
}

confirm() {
    read -p "Are you sure you want to proceed? This will destroy cluster data! (yes/no): " response
    if [[ "$response" != "yes" ]]; then
        echo "Aborted."
        exit 1
    fi
}

# Check for TPI CLI
check_tpi() {
    if ! command -v tpi &> /dev/null; then
        print_error "TPI CLI not found. Install from: https://github.com/turing-machines/tpi"
        exit 1
    fi
}

# Wipe Talos cluster
wipe_talos() {
    print_header "Wiping Talos Cluster"

    print_warning "This will reset all Talos nodes and destroy all data!"
    confirm

    # Check if talosctl is available
    if ! command -v talosctl &> /dev/null; then
        print_error "talosctl not found"
        exit 1
    fi

    # Try graceful reset first
    echo "Attempting graceful Talos reset..."

    for i in "${!NODE_IPS[@]}"; do
        node_ip="${NODE_IPS[$i]}"
        node_num=$((i + 1))

        echo "  Resetting node $node_num ($node_ip)..."

        # Try graceful reset, continue if it fails
        talosctl --endpoints "$node_ip" --nodes "$node_ip" reset \
            --graceful=false \
            --reboot=false \
            2>/dev/null || echo "    Node $node_num may already be wiped or unreachable"
    done

    echo ""
    print_header "Talos Reset Complete"
    echo "Nodes have been reset. To reinstall:"
    echo "  1. Flash Talos image: tpi flash -n <node> --image-path images/latest/metal-arm64.raw"
    echo "  2. Power on nodes: tpi power on -n <node>"
    echo "  3. Apply configs: talosctl apply-config --insecure --nodes <ip> --file <config>"
    echo ""
    echo "See docs/INSTALLATION.md for full instructions."
}

# Wipe K3s cluster (for Armbian nodes)
wipe_k3s() {
    print_header "Wiping K3s Cluster"

    print_warning "This will uninstall K3s from all nodes!"
    confirm

    # Uninstall from server first (node 1)
    echo "Uninstalling K3s server from node 1 (${NODE_IPS[0]})..."
    ssh -o ConnectTimeout=5 "$SSH_USER@${NODE_IPS[0]}" \
        '/usr/local/bin/k3s-uninstall.sh 2>/dev/null || echo "K3s server not installed or already removed"'

    # Uninstall from agents
    for i in 1 2 3; do
        node_ip="${NODE_IPS[$i]}"
        node_num=$((i + 1))

        echo "Uninstalling K3s agent from node $node_num ($node_ip)..."
        ssh -o ConnectTimeout=5 "$SSH_USER@$node_ip" \
            '/usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || echo "K3s agent not installed or already removed"' \
            2>/dev/null || echo "  Node $node_num unreachable"
    done

    # Optionally wipe NVMe
    read -p "Wipe NVMe storage on all nodes? (yes/no): " wipe_nvme
    if [[ "$wipe_nvme" == "yes" ]]; then
        for i in "${!NODE_IPS[@]}"; do
            node_ip="${NODE_IPS[$i]}"
            node_num=$((i + 1))

            echo "  Wiping NVMe on node $node_num ($node_ip)..."
            ssh -o ConnectTimeout=5 "$SSH_USER@$node_ip" \
                'umount /var/lib/longhorn 2>/dev/null; wipefs -af /dev/nvme0n1 2>/dev/null || true' \
                2>/dev/null || echo "    Node $node_num unreachable"
        done
    fi

    echo ""
    print_header "K3s Uninstall Complete"
    echo "K3s has been removed. To reinstall:"
    echo "  1. Run setup script: ssh root@<node> 'bash -s' < scripts/setup-k3s-node.sh"
    echo "  2. Deploy cluster: ./scripts/deploy-k3s-cluster.sh"
    echo ""
    echo "See docs/INSTALLATION-K3S.md for full instructions."
}

# Full node wipe via BMC
wipe_full() {
    print_header "Full Node Wipe via BMC"

    check_tpi

    print_warning "This will power off all nodes and prepare for reflash!"
    print_warning "You will need to manually flash new images after this."
    confirm

    # Power off all nodes
    echo "Powering off all nodes..."
    for node in "${NODES[@]}"; do
        echo "  Powering off node $node..."
        tpi power off -n "$node" 2>/dev/null || true
        sleep 1
    done

    echo ""
    echo "Waiting for nodes to power down..."
    sleep 5

    # Verify power state
    echo ""
    echo "Current power states:"
    tpi power status 2>/dev/null || echo "Unable to query power status"

    echo ""
    print_header "Nodes Powered Off"
    echo ""
    echo "To install Talos:"
    echo "  1. Flash: tpi flash -n <node> --image-path images/latest/metal-arm64.raw"
    echo "  2. Power on: tpi power on -n <node>"
    echo "  3. Apply config: talosctl apply-config --insecure --nodes <ip> --file <config>"
    echo ""
    echo "To install Armbian + K3s:"
    echo "  1. Flash Armbian image via TPI or SD card"
    echo "  2. Power on: tpi power on -n <node>"
    echo "  3. Run setup: ./scripts/setup-k3s-node.sh"
    echo "  4. Deploy K3s: ./scripts/deploy-k3s-cluster.sh"
}

# Wipe specific node
wipe_node() {
    local node=$1
    local method=$2

    if [[ -z "$node" || ! "$node" =~ ^[1-4]$ ]]; then
        print_error "Invalid node number. Use 1-4."
        exit 1
    fi

    local node_idx=$((node - 1))
    local node_ip="${NODE_IPS[$node_idx]}"

    print_header "Wiping Node $node ($node_ip)"

    case "$method" in
        talos)
            print_warning "This will reset Talos on node $node!"
            confirm

            echo "Resetting Talos on node $node..."
            talosctl --endpoints "$node_ip" --nodes "$node_ip" reset \
                --graceful=false \
                --reboot=false \
                2>/dev/null || echo "Node may already be wiped"

            echo ""
            echo "Node $node reset. Power off and reflash to continue."
            ;;

        k3s)
            print_warning "This will uninstall K3s on node $node!"
            confirm

            echo "Uninstalling K3s on node $node..."
            if [[ "$node" == "1" ]]; then
                ssh "$SSH_USER@$node_ip" '/usr/local/bin/k3s-uninstall.sh 2>/dev/null || true'
            else
                ssh "$SSH_USER@$node_ip" '/usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true'
            fi

            echo ""
            echo "K3s removed from node $node."
            ;;

        power)
            check_tpi
            echo "Powering off node $node..."
            tpi power off -n "$node"
            echo "Node $node powered off."
            ;;

        *)
            print_error "Unknown method: $method. Use: talos, k3s, or power"
            exit 1
            ;;
    esac
}

# Show status
show_status() {
    print_header "Cluster Status"

    echo "Checking node reachability..."
    echo ""

    for i in "${!NODE_IPS[@]}"; do
        node_ip="${NODE_IPS[$i]}"
        node_num=$((i + 1))

        # Check SSH (Armbian)
        if ssh -o ConnectTimeout=2 -o BatchMode=yes "$SSH_USER@$node_ip" 'true' 2>/dev/null; then
            # Check if K3s is installed
            if ssh "$SSH_USER@$node_ip" 'systemctl is-active k3s k3s-agent 2>/dev/null | grep -q active'; then
                echo -e "Node $node_num ($node_ip): ${GREEN}Armbian + K3s${NC}"
            else
                echo -e "Node $node_num ($node_ip): ${YELLOW}Armbian (no K3s)${NC}"
            fi
        # Check Talos API
        elif talosctl --endpoints "$node_ip" version --short 2>/dev/null | grep -q 'Tag:'; then
            echo -e "Node $node_num ($node_ip): ${GREEN}Talos${NC}"
        else
            echo -e "Node $node_num ($node_ip): ${RED}Unreachable${NC}"
        fi
    done

    echo ""

    # Check BMC
    if ping -c 1 -W 2 "$BMC_IP" &>/dev/null; then
        echo -e "BMC ($BMC_IP): ${GREEN}Reachable${NC}"

        # Try to get power status
        if command -v tpi &>/dev/null; then
            echo ""
            echo "Power Status:"
            tpi power status 2>/dev/null || echo "  Unable to query power status"
        fi
    else
        echo -e "BMC ($BMC_IP): ${RED}Unreachable${NC}"
    fi
}

# Print usage
usage() {
    cat << EOF
Turing RK1 Cluster Wipe Script

Usage: $0 <command> [options]

Commands:
  talos           Reset all Talos nodes (graceful)
  k3s             Uninstall K3s from all Armbian nodes
  full            Power off all nodes for reflash
  node <n> <type> Wipe specific node (type: talos|k3s|power)
  status          Show current cluster status
  help            Show this help message

Environment Variables:
  BMC_IP          BMC IP address (default: 10.10.88.70)
  BMC_USER        BMC SSH user (default: root)
  SSH_USER        Node SSH user for Armbian (default: root)

Examples:
  $0 talos              # Reset all Talos nodes
  $0 k3s                # Uninstall K3s from all nodes
  $0 full               # Power off all nodes
  $0 node 2 talos       # Reset Talos on node 2 only
  $0 node 3 k3s         # Uninstall K3s from node 3
  $0 status             # Check cluster status

EOF
}

# Main
case "${1:-help}" in
    talos)
        wipe_talos
        ;;
    k3s)
        wipe_k3s
        ;;
    full)
        wipe_full
        ;;
    node)
        wipe_node "$2" "$3"
        ;;
    status)
        show_status
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        print_error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
