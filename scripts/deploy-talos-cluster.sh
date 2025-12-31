#!/bin/bash
#
# Turing RK1 Talos Kubernetes Cluster Deployment Script
# Deploys a 4-node cluster with Talos Linux, Longhorn storage, and NPU support preparation
#
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-turing-cluster}"
CONFIG_DIR="${SCRIPT_DIR}/cluster-config"
IMAGE_DIR="${SCRIPT_DIR}/images/latest"
TALOS_IMAGE="${IMAGE_DIR}/metal-arm64.raw"
TALOS_VERSION="v1.11.6"

# Network configuration
BMC_HOST="${BMC_HOST:-10.10.88.70}"
BMC_SSH="ssh turing-bmc"
CONTROL_PLANE_IP="10.10.88.73"

# TPI CLI Configuration (for local tpi commands)
# Set USE_LOCAL_TPI=1 to use local tpi instead of SSH to BMC
USE_LOCAL_TPI="${USE_LOCAL_TPI:-0}"
export TPI_HOSTNAME="${TPI_HOSTNAME:-$BMC_HOST}"
# TPI_USERNAME and TPI_PASSWORD should be set in environment if using local tpi
WORKER_IPS=("10.10.88.74" "10.10.88.75" "10.10.88.76")
ALL_NODE_IPS=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")
KUBERNETES_ENDPOINT="https://${CONTROL_PLANE_IP}:6443"

# Timeouts
BOOT_TIMEOUT=180
CONFIG_APPLY_WAIT=30
BOOTSTRAP_WAIT=300

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

confirm() {
    local prompt="${1:-Continue?}"
    read -r -p "$prompt [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

wait_for_node() {
    local ip=$1
    local timeout=${2:-$BOOT_TIMEOUT}
    local elapsed=0

    log_info "Waiting for node $ip to respond (timeout: ${timeout}s)..."
    while ! ping -c 1 -W 2 "$ip" &>/dev/null; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [ "$elapsed" -ge "$timeout" ]; then
            log_error "Timeout waiting for node $ip"
            return 1
        fi
        echo -n "."
    done
    echo ""
    log_success "Node $ip is reachable"
}

wait_for_talos_api() {
    local ip=$1
    local timeout=${2:-$BOOT_TIMEOUT}
    local elapsed=0

    log_info "Waiting for Talos API on $ip (timeout: ${timeout}s)..."
    while ! talosctl --nodes "$ip" version --insecure &>/dev/null 2>&1; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [ "$elapsed" -ge "$timeout" ]; then
            log_error "Timeout waiting for Talos API on $ip"
            return 1
        fi
        echo -n "."
    done
    echo ""
    log_success "Talos API responding on $ip"
}

# =============================================================================
# BMC Operations
# =============================================================================

bmc_cmd() {
    if [[ "$USE_LOCAL_TPI" == "1" ]]; then
        # Run tpi locally (requires TPI_HOSTNAME, TPI_USERNAME, TPI_PASSWORD)
        bash -c "$*"
    else
        # Run via SSH to BMC
        $BMC_SSH "$@"
    fi
}

bmc_power_status() {
    log_info "Checking power status of all nodes..."
    bmc_cmd "tpi power status" || {
        log_error "Failed to get power status. Is BMC accessible?"
        return 1
    }
}

bmc_power_on() {
    local node=$1
    log_info "Powering on node $node..."
    bmc_cmd "tpi power on -n $node"
}

bmc_power_off() {
    local node=$1
    log_info "Powering off node $node..."
    bmc_cmd "tpi power off -n $node"
}

bmc_power_cycle() {
    local node=$1
    log_info "Power cycling node $node..."
    bmc_cmd "tpi power cycle -n $node"
}

bmc_flash_node() {
    local node=$1
    local image=$2
    log_info "Flashing node $node with $image..."
    log_warn "This may take 10-15 minutes per node"
    bmc_cmd "tpi flash -n $node -i $image"
}

bmc_uart_output() {
    local node=$1
    log_info "Getting UART output from node $node..."
    bmc_cmd "tpi uart -n $node get"
}

# =============================================================================
# Phase 1: Prerequisites Check
# =============================================================================

check_prerequisites() {
    log_info "=== Phase 1: Checking Prerequisites ==="

    local missing=()

    # Check required tools
    for cmd in talosctl kubectl helm ssh ping; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install talosctl: curl -sL https://talos.dev/install | sh"
        log_info "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
        log_info "Install helm: https://helm.sh/docs/intro/install/"
        return 1
    fi

    # Check BMC access
    log_info "Checking BMC access..."
    if [[ "$USE_LOCAL_TPI" == "1" ]]; then
        # Using local tpi
        if ! command -v tpi &>/dev/null; then
            log_error "tpi CLI not found. Install from: https://github.com/turing-machines/tpi"
            return 1
        fi
        if ! tpi info &>/dev/null 2>&1; then
            log_error "Cannot connect to BMC via tpi at $TPI_HOSTNAME"
            log_info "Ensure TPI_USERNAME and TPI_PASSWORD are set, or run:"
            log_info "  tpi --host $TPI_HOSTNAME --user <user> info"
            return 1
        fi
        log_success "BMC accessible via local tpi"
    else
        # Using SSH to BMC
        if ! $BMC_SSH "echo 'BMC OK'" &>/dev/null; then
            log_error "Cannot connect to BMC. Ensure SSH config has 'turing-bmc' host."
            log_info "Add to ~/.ssh/config:"
            echo "  Host turing-bmc"
            echo "    HostName $BMC_HOST"
            echo "    User root"
            log_info ""
            log_info "Alternatively, set USE_LOCAL_TPI=1 with TPI credentials"
            return 1
        fi
        log_success "BMC accessible via SSH"

        # Check tpi tool on BMC
        log_info "Checking tpi tool on BMC..."
        if ! bmc_cmd "which tpi" &>/dev/null; then
            log_error "tpi tool not found on BMC"
            return 1
        fi
        log_success "tpi tool available on BMC"
    fi

    # Check Talos image
    log_info "Checking Talos image..."
    if [ ! -f "$TALOS_IMAGE" ]; then
        log_warn "Talos image not found at $TALOS_IMAGE"
        log_info "Download from https://factory.talos.dev or run: $0 download-image"
        return 1
    fi
    log_success "Talos image found: $(stat -c%s "$TALOS_IMAGE" | awk '{printf "%.1fM", $1/1024/1024}')"

    # Create config directory
    mkdir -p "$CONFIG_DIR"

    log_success "Prerequisites check passed"
}

# =============================================================================
# Phase 2: Download/Build Talos Image
# =============================================================================

download_talos_image() {
    log_info "=== Phase 2: Downloading Talos Image ==="

    # Read schematic configuration
    if [ -f "${SCRIPT_DIR}/talos-schematic.yaml" ]; then
        log_info "Found talos-schematic.yaml with extensions:"
        cat "${SCRIPT_DIR}/talos-schematic.yaml"
        echo ""
    fi

    log_info "To get the custom image with extensions:"
    echo "  1. Go to https://factory.talos.dev"
    echo "  2. Select: Talos Linux $TALOS_VERSION"
    echo "  3. Select: Single Board Computers → Turing RK1"
    echo "  4. Add extensions:"
    echo "     - siderolabs/iscsi-tools"
    echo "     - siderolabs/util-linux-tools"
    echo "  5. Download metal-arm64.raw.xz"
    echo "  6. Decompress: xz -d metal-arm64.raw.xz"
    echo "  7. Move to: $IMAGE_DIR/"
    echo ""

    if confirm "Do you have a schematic ID to download directly?"; then
        read -r -p "Enter schematic ID: " schematic_id
        local url="https://factory.talos.dev/image/${schematic_id}/${TALOS_VERSION}/metal-arm64.raw.xz"

        log_info "Downloading from $url..."
        mkdir -p "$IMAGE_DIR"
        curl -L -o "${IMAGE_DIR}/metal-arm64.raw.xz" "$url"

        log_info "Decompressing..."
        xz -d -f "${IMAGE_DIR}/metal-arm64.raw.xz"

        log_success "Image downloaded to $TALOS_IMAGE"
    fi
}

# =============================================================================
# Phase 3: Flash Nodes
# =============================================================================

flash_nodes() {
    log_info "=== Phase 3: Flashing Nodes ==="

    if [ ! -f "$TALOS_IMAGE" ]; then
        log_error "Talos image not found at $TALOS_IMAGE"
        return 1
    fi

    # Check image on BMC or copy it
    local bmc_image_path="/tmp/metal-arm64.raw"

    log_info "The image needs to be accessible from the BMC."
    echo "Options:"
    echo "  1. Copy image to BMC (recommended for reliability)"
    echo "  2. Use local path (if BMC can access this machine via NFS/SMB)"
    echo ""

    if confirm "Copy image to BMC? (~2.2GB transfer)"; then
        log_info "Copying image to BMC..."
        scp "$TALOS_IMAGE" "turing-bmc:$bmc_image_path"
        log_success "Image copied to BMC"
    else
        read -r -p "Enter path accessible from BMC: " bmc_image_path
    fi

    # Power off all nodes first
    log_info "Powering off all nodes before flashing..."
    for node in 1 2 3 4; do
        bmc_power_off $node || true
    done
    sleep 5

    # Flash each node
    for node in 1 2 3 4; do
        if confirm "Flash node $node?"; then
            bmc_flash_node $node "$bmc_image_path"
            log_success "Node $node flashed"
        else
            log_warn "Skipping node $node"
        fi
    done

    log_success "Node flashing complete"
}

# =============================================================================
# Phase 4: Boot Nodes
# =============================================================================

boot_nodes() {
    log_info "=== Phase 4: Booting Nodes ==="

    # Power on all nodes
    for node in 1 2 3 4; do
        bmc_power_on $node
        sleep 2
    done

    log_info "Waiting for nodes to boot..."
    sleep 30

    # Wait for each node to become reachable
    for ip in "${ALL_NODE_IPS[@]}"; do
        wait_for_node "$ip" || {
            log_warn "Node $ip not reachable, continuing..."
        }
    done

    # Wait for Talos API
    for ip in "${ALL_NODE_IPS[@]}"; do
        wait_for_talos_api "$ip" || {
            log_warn "Talos API not ready on $ip"
        }
    done

    log_success "Nodes booted"
}

# =============================================================================
# Phase 5: Generate Cluster Configuration
# =============================================================================

generate_configs() {
    log_info "=== Phase 5: Generating Cluster Configuration ==="

    cd "$CONFIG_DIR"

    # Generate secrets if not exists
    if [ ! -f "secrets.yaml" ]; then
        log_info "Generating cluster secrets..."
        talosctl gen secrets -o secrets.yaml
        log_success "Secrets generated (KEEP secrets.yaml SAFE!)"
    else
        log_info "Using existing secrets.yaml"
    fi

    # Generate base configs
    log_info "Generating base machine configurations..."
    talosctl gen config \
        --with-secrets secrets.yaml \
        "$CLUSTER_NAME" \
        "$KUBERNETES_ENDPOINT" \
        --install-disk /dev/mmcblk0 \
        --output-dir . \
        --force

    log_success "Base configs generated: controlplane.yaml, worker.yaml"

    # Create worker patches for each worker with unique hostnames
    create_worker_patches

    # Apply patches to create final configs
    apply_config_patches

    log_success "Configuration generation complete"
}

create_worker_patches() {
    log_info "Creating worker-specific patches..."

    local worker_num=1
    for ip in "${WORKER_IPS[@]}"; do
        local patch_file="${CONFIG_DIR}/worker${worker_num}-patch.yaml"

        # Only create if it doesn't exist (preserve customizations)
        if [ ! -f "$patch_file" ]; then
            cat > "$patch_file" << EOF
machine:
  network:
    hostname: turing-w${worker_num}
    interfaces:
      - interface: eth0
        dhcp: true
  kubelet:
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/lib/longhorn
        options:
          - bind
          - rshared
          - rw
  disks:
    - device: /dev/nvme0n1
      partitions:
        - mountpoint: /var/lib/longhorn
EOF
            log_info "Created $patch_file"
        else
            log_info "Using existing $patch_file"
        fi

        worker_num=$((worker_num + 1))
    done
}

apply_config_patches() {
    log_info "Applying configuration patches..."

    cd "$CONFIG_DIR"

    # Patch control plane config
    if [ -f "controlplane-patch.yaml" ]; then
        log_info "Patching controlplane.yaml..."
        talosctl machineconfig patch controlplane.yaml \
            --patch @controlplane-patch.yaml \
            --output controlplane-patched.yaml
        log_success "Created controlplane-patched.yaml"
    else
        log_warn "controlplane-patch.yaml not found, using base config"
        cp controlplane.yaml controlplane-patched.yaml
    fi

    # Patch worker configs (each worker gets unique config)
    local worker_num=1
    for ip in "${WORKER_IPS[@]}"; do
        local patch_file="worker${worker_num}-patch.yaml"
        local output_file="worker${worker_num}-patched.yaml"

        if [ -f "$patch_file" ]; then
            log_info "Patching worker.yaml with $patch_file..."
            talosctl machineconfig patch worker.yaml \
                --patch @"$patch_file" \
                --output "$output_file"
            log_success "Created $output_file"
        else
            log_warn "$patch_file not found, using base worker config"
            cp worker.yaml "$output_file"
        fi

        worker_num=$((worker_num + 1))
    done
}

# =============================================================================
# Phase 6: Apply Configurations to Nodes
# =============================================================================

apply_configs() {
    log_info "=== Phase 6: Applying Configurations to Nodes ==="

    cd "$CONFIG_DIR"

    # Apply control plane config
    log_info "Applying config to control plane ($CONTROL_PLANE_IP)..."
    if talosctl apply-config --insecure \
        --nodes "$CONTROL_PLANE_IP" \
        --file controlplane-patched.yaml; then
        log_success "Control plane configured"
    else
        log_error "Failed to configure control plane"
        return 1
    fi

    # Wait for control plane to process config
    log_info "Waiting ${CONFIG_APPLY_WAIT}s for control plane to process..."
    sleep $CONFIG_APPLY_WAIT

    # Apply worker configs
    local worker_num=1
    for ip in "${WORKER_IPS[@]}"; do
        local config_file="worker${worker_num}-patched.yaml"

        log_info "Applying config to worker $worker_num ($ip)..."
        if talosctl apply-config --insecure \
            --nodes "$ip" \
            --file "$config_file"; then
            log_success "Worker $worker_num configured"
        else
            log_warn "Failed to configure worker $worker_num, continuing..."
        fi

        worker_num=$((worker_num + 1))
    done

    log_success "All configurations applied"
}

# =============================================================================
# Phase 7: Bootstrap Cluster
# =============================================================================

setup_talosctl() {
    log_info "Configuring talosctl..."

    cd "$CONFIG_DIR"

    # Configure endpoints and nodes
    talosctl --talosconfig=./talosconfig config endpoint "$CONTROL_PLANE_IP"
    talosctl --talosconfig=./talosconfig config node "$CONTROL_PLANE_IP"

    # Merge into default config
    if confirm "Merge talosconfig into ~/.talos/config?"; then
        mkdir -p ~/.talos
        talosctl config merge ./talosconfig
        log_success "talosconfig merged"
    else
        log_info "Using local talosconfig. Export with:"
        echo "  export TALOSCONFIG=$CONFIG_DIR/talosconfig"
    fi
}

bootstrap_cluster() {
    log_info "=== Phase 7: Bootstrapping Kubernetes Cluster ==="

    setup_talosctl

    # Wait for control plane to be ready
    log_info "Waiting for control plane Talos API..."
    wait_for_talos_api "$CONTROL_PLANE_IP" 300 || {
        log_error "Control plane not ready for bootstrap"
        return 1
    }

    # Check if already bootstrapped
    if talosctl --nodes "$CONTROL_PLANE_IP" get members &>/dev/null 2>&1; then
        log_warn "Cluster appears to be already bootstrapped"
        if ! confirm "Bootstrap anyway? (This can break the cluster if already running)"; then
            log_info "Skipping bootstrap"
            return 0
        fi
    fi

    # Bootstrap
    log_info "Bootstrapping cluster (this runs ONCE)..."
    if talosctl bootstrap --nodes "$CONTROL_PLANE_IP"; then
        log_success "Bootstrap initiated"
    else
        log_error "Bootstrap failed"
        return 1
    fi

    # Wait for bootstrap to complete
    log_info "Waiting for Kubernetes API to become available..."
    local elapsed=0
    while ! talosctl --nodes "$CONTROL_PLANE_IP" health --wait-timeout 30s &>/dev/null 2>&1; do
        sleep 10
        elapsed=$((elapsed + 10))
        if [ $elapsed -ge $BOOTSTRAP_WAIT ]; then
            log_warn "Health check timeout, but cluster may still be starting"
            break
        fi
        echo -n "."
    done
    echo ""

    log_success "Bootstrap complete"
}

# =============================================================================
# Phase 8: Get Kubernetes Access
# =============================================================================

get_kubeconfig() {
    log_info "=== Phase 8: Getting Kubernetes Access ==="

    cd "$CONFIG_DIR"

    # Get kubeconfig
    log_info "Downloading kubeconfig..."
    if talosctl kubeconfig --nodes "$CONTROL_PLANE_IP" -f ./kubeconfig; then
        log_success "kubeconfig saved to $CONFIG_DIR/kubeconfig"
    else
        log_error "Failed to get kubeconfig"
        return 1
    fi

    # Test access
    log_info "Testing Kubernetes access..."
    if KUBECONFIG=./kubeconfig kubectl get nodes; then
        log_success "Kubernetes cluster is accessible"
    else
        log_warn "Could not get nodes, cluster may still be initializing"
    fi

    echo ""
    log_info "To use kubectl with this cluster:"
    echo "  export KUBECONFIG=$CONFIG_DIR/kubeconfig"
    echo "  # or"
    echo "  kubectl --kubeconfig=$CONFIG_DIR/kubeconfig get nodes"
}

# =============================================================================
# Phase 9: Install Longhorn Storage
# =============================================================================

install_longhorn() {
    log_info "=== Phase 9: Installing Longhorn Storage ==="

    cd "$CONFIG_DIR"
    export KUBECONFIG="$CONFIG_DIR/kubeconfig"

    # Check if nodes are ready
    log_info "Checking node status..."
    if ! kubectl get nodes &>/dev/null; then
        log_error "Cannot access Kubernetes cluster"
        return 1
    fi

    # Add Longhorn repo
    log_info "Adding Longhorn Helm repository..."
    helm repo add longhorn https://charts.longhorn.io
    helm repo update

    # Check if already installed
    if helm list -n longhorn-system | grep -q longhorn; then
        log_warn "Longhorn already installed"
        if ! confirm "Upgrade Longhorn?"; then
            return 0
        fi
        helm upgrade longhorn longhorn/longhorn \
            --namespace longhorn-system \
            --set defaultSettings.defaultDataPath=/var/lib/longhorn \
            --set defaultSettings.defaultReplicaCount=2 \
            --set persistence.defaultClassReplicaCount=2
    else
        log_info "Installing Longhorn..."
        helm install longhorn longhorn/longhorn \
            --namespace longhorn-system \
            --create-namespace \
            --set defaultSettings.defaultDataPath=/var/lib/longhorn \
            --set defaultSettings.defaultReplicaCount=2 \
            --set persistence.defaultClassReplicaCount=2
    fi

    # Wait for Longhorn to be ready
    log_info "Waiting for Longhorn pods to be ready..."
    kubectl -n longhorn-system wait --for=condition=ready pod -l app=longhorn-manager --timeout=300s || {
        log_warn "Longhorn manager pods not ready yet"
    }

    # Set as default storage class
    log_info "Setting Longhorn as default storage class..."
    kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true

    log_success "Longhorn installation complete"
    log_info "Access Longhorn UI:"
    echo "  kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80"
    echo "  Then open http://localhost:8080"
}

# =============================================================================
# Utility Commands
# =============================================================================

cluster_status() {
    log_info "=== Cluster Status ==="

    echo ""
    log_info "BMC Power Status:"
    bmc_power_status || true

    echo ""
    log_info "Node Reachability:"
    for ip in "${ALL_NODE_IPS[@]}"; do
        if ping -c 1 -W 2 "$ip" &>/dev/null; then
            echo -e "  $ip: ${GREEN}reachable${NC}"
        else
            echo -e "  $ip: ${RED}unreachable${NC}"
        fi
    done

    echo ""
    log_info "Talos Health:"
    talosctl --nodes "$CONTROL_PLANE_IP" health 2>/dev/null || {
        log_warn "Could not get Talos health"
    }

    echo ""
    log_info "Kubernetes Nodes:"
    export KUBECONFIG="$CONFIG_DIR/kubeconfig"
    kubectl get nodes 2>/dev/null || {
        log_warn "Could not get Kubernetes nodes"
    }
}

reset_cluster() {
    log_warn "=== CLUSTER RESET ==="
    log_warn "This will DESTROY the entire cluster and all data!"

    if ! confirm "Are you SURE you want to reset the cluster?"; then
        log_info "Aborted"
        return 0
    fi

    if ! confirm "FINAL WARNING: All data will be lost. Continue?"; then
        log_info "Aborted"
        return 0
    fi

    log_info "Resetting all nodes..."
    for ip in "${ALL_NODE_IPS[@]}"; do
        log_info "Resetting $ip..."
        talosctl reset --nodes "$ip" --graceful=false --reboot || true
    done

    # Clean up local configs
    log_info "Cleaning up local configuration..."
    rm -f "$CONFIG_DIR"/{controlplane,worker}*.yaml
    rm -f "$CONFIG_DIR"/talosconfig
    rm -f "$CONFIG_DIR"/kubeconfig
    # Keep secrets.yaml for redeployment

    log_success "Cluster reset complete"
    log_info "Nodes will reboot into maintenance mode"
}

# =============================================================================
# Main Entry Point
# =============================================================================

usage() {
    cat << EOF
Turing RK1 Talos Cluster Deployment Script

Usage: $0 <command>

Commands:
  deploy          Full deployment (all phases)
  prereq          Check prerequisites only
  download-image  Download Talos image from factory
  flash           Flash nodes with Talos image
  boot            Power on and boot all nodes
  generate        Generate cluster configurations
  apply           Apply configurations to nodes
  bootstrap       Bootstrap Kubernetes cluster
  kubeconfig      Get kubeconfig for kubectl access
  longhorn        Install Longhorn storage

  status          Show cluster status
  reset           Reset cluster (DESTRUCTIVE!)

  power-on        Power on all nodes
  power-off       Power off all nodes
  power-status    Show power status
  uart <node>     Get UART output from node (1-4)

Environment Variables:
  CLUSTER_NAME    Cluster name (default: turing-cluster)
  BMC_HOST        BMC IP address (default: 10.10.88.70)

Examples:
  $0 deploy       # Full deployment
  $0 status       # Check cluster status
  $0 uart 1       # View node 1 UART output
EOF
}

main() {
    local cmd="${1:-help}"

    case "$cmd" in
        deploy)
            check_prerequisites
            echo ""
            if confirm "Proceed with full deployment?"; then
                boot_nodes
                generate_configs
                apply_configs
                bootstrap_cluster
                get_kubeconfig
                echo ""
                if confirm "Install Longhorn storage?"; then
                    install_longhorn
                fi
            fi
            ;;
        prereq|prerequisites)
            check_prerequisites
            ;;
        download-image|download)
            download_talos_image
            ;;
        flash)
            check_prerequisites
            flash_nodes
            ;;
        boot)
            boot_nodes
            ;;
        generate|gen)
            generate_configs
            ;;
        apply)
            apply_configs
            ;;
        bootstrap)
            bootstrap_cluster
            ;;
        kubeconfig|kube)
            get_kubeconfig
            ;;
        longhorn|storage)
            install_longhorn
            ;;
        status)
            cluster_status
            ;;
        reset)
            reset_cluster
            ;;
        power-on)
            for node in 1 2 3 4; do bmc_power_on $node; done
            ;;
        power-off)
            for node in 1 2 3 4; do bmc_power_off $node; done
            ;;
        power-status|ps)
            bmc_power_status
            ;;
        uart)
            local node="${2:-1}"
            bmc_uart_output "$node"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            log_error "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
