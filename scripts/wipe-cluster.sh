#!/bin/bash
#
# Turing RK1 Cluster Wipe Script
# Detects cluster type and wipes NVMe and eMMC storage to prepare for fresh deployment
#
# Usage: ./wipe-cluster.sh [command]
#
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
CONFIG_DIR="${PROJECT_DIR}/cluster-config"

# Load .env file if present
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${PROJECT_DIR}/.env"
    set +a
fi

# BMC Configuration
BMC_IP="${BMC_IP:-10.10.88.70}"
BMC_USER="${BMC_USER:-root}"

# TPI CLI Configuration (for local tpi commands)
export TPI_HOSTNAME="${TPI_HOSTNAME:-$BMC_IP}"
# TPI_USERNAME and TPI_PASSWORD should be set in environment if needed

# Node Configuration
CONTROL_PLANE_IP="10.10.88.73"
WORKER_IPS=("10.10.88.74" "10.10.88.75" "10.10.88.76")
ALL_NODE_IPS=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")
NODE_NUMBERS=(1 2 3 4)
SSH_USER="${SSH_USER:-root}"

# Storage devices
NVME_DEVICE="/dev/nvme0n1"
EMMC_DEVICE="/dev/mmcblk0"

# Cluster type (detected)
CLUSTER_TYPE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_section() {
    echo -e "\n${BOLD}${CYAN}─── $1 ───${NC}\n"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

check_reachable() {
    local ip=$1
    ping -c 1 -W 2 "$ip" &>/dev/null
}

confirm() {
    local message="${1:-This will destroy all cluster data!}"
    echo -e "${RED}${BOLD}WARNING: $message${NC}"
    read -r -p "Are you sure you want to proceed? (yes/no): " response
    if [[ "$response" != "yes" ]]; then
        echo "Aborted."
        exit 1
    fi
}

# Check for TPI CLI and connectivity
check_tpi() {
    if ! command -v tpi &> /dev/null; then
        log_error "TPI CLI not found. Install from: https://github.com/turing-machines/tpi"
        exit 1
    fi

    # Verify BMC connectivity
    if ! tpi info &>/dev/null 2>&1; then
        log_warn "TPI cannot connect to BMC at $TPI_HOSTNAME"
        log_info "Ensure TPI_USERNAME and TPI_PASSWORD are set, or run:"
        log_info "  tpi --host $TPI_HOSTNAME --user <user> info"
        log_info "to cache credentials"
        return 1
    fi
}

# =============================================================================
# Cluster Detection (from talos-cluster-status.sh)
# =============================================================================

detect_cluster_type() {
    print_section "Detecting Cluster Type"

    local reachable_nodes=0
    local talos_nodes=0
    local ssh_nodes=0
    local k3s_nodes=0
    local maintenance_nodes=0

    for ip in "${ALL_NODE_IPS[@]}"; do
        if check_reachable "$ip"; then
            ((++reachable_nodes))

            # Check for Talos API
            if talosctl --nodes "$ip" version &>/dev/null 2>&1; then
                ((++talos_nodes))
                continue
            fi

            # Check for Talos maintenance mode (port 50000)
            if nc -zw2 "$ip" 50000 &>/dev/null 2>&1; then
                ((++maintenance_nodes))
                continue
            fi

            # Check for SSH access
            if ssh -o ConnectTimeout=3 -o BatchMode=yes "$SSH_USER@$ip" "echo ok" &>/dev/null 2>&1; then
                ((++ssh_nodes))
                # Check if K3s is installed
                if ssh -o ConnectTimeout=3 -o BatchMode=yes "$SSH_USER@$ip" "which k3s" &>/dev/null 2>&1; then
                    ((++k3s_nodes))
                fi
            fi
        fi
    done

    echo "  Reachable nodes: $reachable_nodes / ${#ALL_NODE_IPS[@]}"
    echo "  Talos nodes: $talos_nodes"
    echo "  Talos maintenance: $maintenance_nodes"
    echo "  SSH accessible: $ssh_nodes"
    echo "  K3s installed: $k3s_nodes"
    echo ""

    # Determine cluster type
    if [[ $talos_nodes -gt 0 ]]; then
        CLUSTER_TYPE="talos"
        log_success "Detected: Talos Linux cluster"
    elif [[ $maintenance_nodes -gt 0 ]]; then
        CLUSTER_TYPE="talos-maintenance"
        log_success "Detected: Talos in maintenance mode"
    elif [[ $k3s_nodes -gt 0 ]]; then
        CLUSTER_TYPE="k3s"
        log_success "Detected: K3s on Armbian cluster"
    elif [[ $ssh_nodes -gt 0 ]]; then
        CLUSTER_TYPE="armbian"
        log_success "Detected: Armbian (no K3s)"
    elif [[ $reachable_nodes -eq 0 ]]; then
        CLUSTER_TYPE="offline"
        log_warn "All nodes appear offline"
    else
        CLUSTER_TYPE="unknown"
        log_warn "Unable to determine cluster type"
    fi

    return 0
}

# =============================================================================
# Storage Detection
# =============================================================================

detect_node_storage() {
    local ip=$1
    local method=$2  # "ssh" or "talos"

    echo "  Detecting storage on $ip..."

    if [[ "$method" == "ssh" ]]; then
        ssh -o ConnectTimeout=5 "$SSH_USER@$ip" "
            echo '    eMMC:'
            if [ -b $EMMC_DEVICE ]; then
                size=\$(lsblk -b -d -n -o SIZE $EMMC_DEVICE 2>/dev/null | awk '{printf \"%.1fGB\", \$1/1024/1024/1024}')
                echo \"      $EMMC_DEVICE: \$size\"
                lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINT $EMMC_DEVICE 2>/dev/null | sed 's/^/      /' || true
            else
                echo '      Not found'
            fi
            echo '    NVMe:'
            if [ -b $NVME_DEVICE ]; then
                size=\$(lsblk -b -d -n -o SIZE $NVME_DEVICE 2>/dev/null | awk '{printf \"%.1fGB\", \$1/1024/1024/1024}')
                echo \"      $NVME_DEVICE: \$size\"
                lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINT $NVME_DEVICE 2>/dev/null | sed 's/^/      /' || true
            else
                echo '      Not found'
            fi
        " 2>/dev/null || echo "    Could not detect storage"
    elif [[ "$method" == "talos" ]]; then
        talosctl --nodes "$ip" get disks 2>/dev/null | grep -E "(nvme|mmcblk)" | sed 's/^/    /' || echo "    Could not detect storage"
    fi
}

# =============================================================================
# Wipe Functions
# =============================================================================

wipe_nvme_ssh() {
    local ip=$1
    local node_num=$2

    log_info "Wiping NVMe on node $node_num ($ip)..."

    ssh -o ConnectTimeout=10 "$SSH_USER@$ip" "
        set -e
        if [ -b $NVME_DEVICE ]; then
            # Unmount any mounted partitions
            for mount in \$(mount | grep $NVME_DEVICE | awk '{print \$3}'); do
                echo \"  Unmounting \$mount...\"
                umount -f \"\$mount\" 2>/dev/null || true
            done

            # Stop any services using the disk
            systemctl stop longhorn* 2>/dev/null || true

            # Wipe filesystem signatures
            echo '  Wiping filesystem signatures...'
            wipefs -af $NVME_DEVICE 2>/dev/null || true

            # Zero out first and last 1MB (partition tables, GPT backup)
            echo '  Zeroing partition tables...'
            dd if=/dev/zero of=$NVME_DEVICE bs=1M count=1 conv=fsync 2>/dev/null || true

            # Get disk size and zero last 1MB
            size=\$(blockdev --getsize64 $NVME_DEVICE)
            dd if=/dev/zero of=$NVME_DEVICE bs=1M seek=\$((size/1048576 - 1)) count=1 conv=fsync 2>/dev/null || true

            # Inform kernel of partition changes
            partprobe $NVME_DEVICE 2>/dev/null || true

            echo '  NVMe wiped successfully'
        else
            echo '  NVMe device not found, skipping'
        fi
    " 2>/dev/null; local rc=$?
    if [[ $rc -eq 0 ]]; then
        log_success "Node $node_num NVMe wiped"
    else
        log_warn "Node $node_num NVMe wipe may have failed"
    fi
}

wipe_emmc_ssh() {
    local ip=$1
    local node_num=$2

    log_info "Wiping eMMC on node $node_num ($ip)..."

    ssh -o ConnectTimeout=10 "$SSH_USER@$ip" "
        set -e
        if [ -b $EMMC_DEVICE ]; then
            echo '  WARNING: Wiping eMMC will remove the operating system!'
            echo '  The node will not boot until reflashed.'

            # Unmount all eMMC partitions except root if we're running from it
            root_dev=\$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
            if [[ \"\$root_dev\" == \"$EMMC_DEVICE\"* ]]; then
                echo '  Running from eMMC - will wipe partition table only'
                echo '  Node will need to be reflashed via BMC'

                # Just wipe the partition table - system will be unbootable
                wipefs -af $EMMC_DEVICE 2>/dev/null || true
            else
                # Not running from eMMC, safe to fully wipe
                for mount in \$(mount | grep $EMMC_DEVICE | awk '{print \$3}'); do
                    echo \"  Unmounting \$mount...\"
                    umount -f \"\$mount\" 2>/dev/null || true
                done

                wipefs -af $EMMC_DEVICE 2>/dev/null || true
                dd if=/dev/zero of=$EMMC_DEVICE bs=1M count=1 conv=fsync 2>/dev/null || true
            fi

            echo '  eMMC wiped successfully'
        else
            echo '  eMMC device not found, skipping'
        fi
    " 2>/dev/null; local rc=$?
    if [[ $rc -eq 0 ]]; then
        log_success "Node $node_num eMMC wiped"
    else
        log_warn "Node $node_num eMMC wipe may have failed"
    fi
}

wipe_talos_node() {
    local ip=$1
    local node_num=$2

    log_info "Resetting Talos node $node_num ($ip)..."

    # Use talosctl reset to wipe the node
    if talosctl --nodes "$ip" reset \
        --graceful=false \
        --reboot=false \
        --system-labels-to-wipe STATE \
        --system-labels-to-wipe EPHEMERAL \
        2>/dev/null; then
        log_success "Node $node_num Talos reset complete"
    else
        log_warn "Node $node_num Talos reset failed (may already be wiped)"
    fi
}

# =============================================================================
# Main Wipe Commands
# =============================================================================

cmd_status() {
    print_header "Cluster Wipe Status"
    detect_cluster_type

    print_section "Storage Status"

    for i in "${!ALL_NODE_IPS[@]}"; do
        ip="${ALL_NODE_IPS[$i]}"
        node_num="${NODE_NUMBERS[$i]}"
        echo -e "${BOLD}Node $node_num ($ip):${NC}"

        if ! check_reachable "$ip"; then
            echo "  Unreachable"
            echo ""
            continue
        fi

        case "$CLUSTER_TYPE" in
            talos)
                detect_node_storage "$ip" "talos"
                ;;
            k3s|armbian)
                detect_node_storage "$ip" "ssh"
                ;;
            talos-maintenance)
                echo "  In maintenance mode - cannot detect storage"
                ;;
            *)
                echo "  Cannot detect storage"
                ;;
        esac
        echo ""
    done

    # BMC status
    print_section "BMC Status"
    if check_reachable "$BMC_IP"; then
        log_success "BMC ($BMC_IP) is reachable"
        if command -v tpi &>/dev/null; then
            echo ""
            echo "Power Status:"
            tpi power status 2>/dev/null || echo "  Unable to query"
        fi
    else
        log_warn "BMC ($BMC_IP) is not reachable"
    fi
}

cmd_wipe_nvme() {
    print_header "Wipe NVMe Storage"
    detect_cluster_type

    if [[ "$CLUSTER_TYPE" == "offline" ]]; then
        log_error "No nodes are reachable"
        exit 1
    fi

    confirm "This will wipe ALL NVMe drives on ALL reachable nodes!"

    print_section "Wiping NVMe Drives"

    for i in "${!ALL_NODE_IPS[@]}"; do
        ip="${ALL_NODE_IPS[$i]}"
        node_num="${NODE_NUMBERS[$i]}"

        if ! check_reachable "$ip"; then
            log_warn "Node $node_num ($ip) unreachable, skipping"
            continue
        fi

        case "$CLUSTER_TYPE" in
            k3s|armbian)
                wipe_nvme_ssh "$ip" "$node_num"
                ;;
            talos)
                log_warn "Node $node_num: Use 'wipe talos' for Talos nodes (includes NVMe)"
                ;;
            talos-maintenance)
                log_warn "Node $node_num in maintenance mode - reflash via BMC to wipe"
                ;;
        esac
    done

    print_section "NVMe Wipe Complete"
    log_info "NVMe drives have been wiped"
}

cmd_wipe_emmc() {
    print_header "Wipe eMMC Storage"
    detect_cluster_type

    if [[ "$CLUSTER_TYPE" == "offline" ]]; then
        log_error "No nodes are reachable"
        exit 1
    fi

    echo -e "${RED}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  DANGER: This will wipe eMMC boot drives!                        ║"
    echo "║  Nodes will NOT boot until reflashed via BMC.                    ║"
    echo "║  You will need to use 'tpi flash' to reinstall an OS.            ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    confirm "This will make ALL nodes UNBOOTABLE!"

    print_section "Wiping eMMC Drives"

    for i in "${!ALL_NODE_IPS[@]}"; do
        ip="${ALL_NODE_IPS[$i]}"
        node_num="${NODE_NUMBERS[$i]}"

        if ! check_reachable "$ip"; then
            log_warn "Node $node_num ($ip) unreachable, skipping"
            continue
        fi

        case "$CLUSTER_TYPE" in
            k3s|armbian)
                wipe_emmc_ssh "$ip" "$node_num"
                ;;
            talos)
                log_warn "Node $node_num: Use 'wipe talos' for Talos nodes"
                ;;
            talos-maintenance)
                log_warn "Node $node_num in maintenance mode - reflash via BMC"
                ;;
        esac
    done

    print_section "eMMC Wipe Complete"
    log_warn "Nodes will need to be reflashed via BMC before they can boot"
    log_info "Use: tpi flash -n <node> --image-path <image>"
}

cmd_wipe_all() {
    print_header "Full Storage Wipe (NVMe + eMMC)"
    detect_cluster_type

    if [[ "$CLUSTER_TYPE" == "offline" ]]; then
        log_error "No nodes are reachable"
        exit 1
    fi

    echo -e "${RED}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  DANGER: This will wipe BOTH NVMe AND eMMC on ALL nodes!         ║"
    echo "║  All data will be destroyed.                                     ║"
    echo "║  Nodes will NOT boot until reflashed via BMC.                    ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    confirm "This will DESTROY ALL DATA and make nodes UNBOOTABLE!"

    print_section "Wiping All Storage"

    for i in "${!ALL_NODE_IPS[@]}"; do
        ip="${ALL_NODE_IPS[$i]}"
        node_num="${NODE_NUMBERS[$i]}"

        if ! check_reachable "$ip"; then
            log_warn "Node $node_num ($ip) unreachable, skipping"
            continue
        fi

        case "$CLUSTER_TYPE" in
            k3s|armbian)
                wipe_nvme_ssh "$ip" "$node_num"
                wipe_emmc_ssh "$ip" "$node_num"
                ;;
            talos)
                wipe_talos_node "$ip" "$node_num"
                ;;
            talos-maintenance)
                log_warn "Node $node_num in maintenance mode - power off and reflash"
                ;;
        esac
    done

    print_section "Full Wipe Complete"
    log_warn "All storage has been wiped"
    log_info "Reflash nodes via BMC: tpi flash -n <node> --image-path <image>"
}

cmd_wipe_talos() {
    print_header "Wipe Talos Cluster"
    detect_cluster_type

    if [[ "$CLUSTER_TYPE" != "talos" && "$CLUSTER_TYPE" != "talos-maintenance" ]]; then
        log_error "No Talos cluster detected (found: $CLUSTER_TYPE)"
        log_info "Use 'wipe all' or 'wipe nvme/emmc' for non-Talos nodes"
        exit 1
    fi

    confirm "This will reset all Talos nodes and destroy cluster state!"

    print_section "Resetting Talos Nodes"

    # Set talosconfig if available
    if [ -f "$CONFIG_DIR/talosconfig" ]; then
        export TALOSCONFIG="$CONFIG_DIR/talosconfig"
    fi

    for i in "${!ALL_NODE_IPS[@]}"; do
        ip="${ALL_NODE_IPS[$i]}"
        node_num="${NODE_NUMBERS[$i]}"

        if ! check_reachable "$ip"; then
            log_warn "Node $node_num ($ip) unreachable, skipping"
            continue
        fi

        if [[ "$CLUSTER_TYPE" == "talos-maintenance" ]]; then
            log_warn "Node $node_num in maintenance mode - will power off for reflash"
        else
            wipe_talos_node "$ip" "$node_num"
        fi
    done

    print_section "Talos Reset Complete"
    echo ""
    echo "To reinstall Talos:"
    echo "  1. Power off nodes: tpi power off -n <node>"
    echo "  2. Flash image: tpi flash -n <node> --image-path images/latest/metal-arm64.raw"
    echo "  3. Deploy: ./scripts/deploy-talos-cluster.sh deploy"
}

cmd_wipe_k3s() {
    print_header "Wipe K3s Cluster"
    detect_cluster_type

    if [[ "$CLUSTER_TYPE" != "k3s" && "$CLUSTER_TYPE" != "armbian" ]]; then
        log_error "No K3s/Armbian cluster detected (found: $CLUSTER_TYPE)"
        exit 1
    fi

    confirm "This will uninstall K3s and optionally wipe storage!"

    print_section "Uninstalling K3s"

    # Uninstall K3s server first
    if ssh -o ConnectTimeout=5 "$SSH_USER@$CONTROL_PLANE_IP" "test -f /usr/local/bin/k3s-uninstall.sh" 2>/dev/null; then
        log_info "Uninstalling K3s server on $CONTROL_PLANE_IP..."
        ssh "$SSH_USER@$CONTROL_PLANE_IP" '/usr/local/bin/k3s-uninstall.sh' 2>/dev/null || true
        log_success "K3s server uninstalled"
    fi

    # Uninstall K3s agents
    for ip in "${WORKER_IPS[@]}"; do
        if ssh -o ConnectTimeout=5 "$SSH_USER@$ip" "test -f /usr/local/bin/k3s-agent-uninstall.sh" 2>/dev/null; then
            log_info "Uninstalling K3s agent on $ip..."
            ssh "$SSH_USER@$ip" '/usr/local/bin/k3s-agent-uninstall.sh' 2>/dev/null || true
            log_success "K3s agent uninstalled on $ip"
        fi
    done

    # Ask about storage wipe
    echo ""
    read -r -p "Also wipe NVMe storage (Longhorn data)? (yes/no): " wipe_nvme
    if [[ "$wipe_nvme" == "yes" ]]; then
        for i in "${!ALL_NODE_IPS[@]}"; do
            wipe_nvme_ssh "${ALL_NODE_IPS[$i]}" "${NODE_NUMBERS[$i]}"
        done
    fi

    print_section "K3s Uninstall Complete"
    echo ""
    echo "To reinstall K3s:"
    echo "  1. Setup nodes: ./scripts/setup-k3s-node.sh"
    echo "  2. Deploy: ./scripts/deploy-k3s-cluster.sh"
    echo ""
    echo "To switch to Talos:"
    echo "  1. Wipe eMMC: ./scripts/wipe-cluster.sh emmc"
    echo "  2. Flash Talos: tpi flash -n <node> --image-path images/latest/metal-arm64.raw"
    echo "  3. Deploy: ./scripts/deploy-talos-cluster.sh deploy"
}

cmd_wipe_node() {
    local node_num=$1
    local target=${2:-all}

    if [[ -z "$node_num" || ! "$node_num" =~ ^[1-4]$ ]]; then
        log_error "Invalid node number. Use 1-4."
        exit 1
    fi

    local node_idx=$((node_num - 1))
    local ip="${ALL_NODE_IPS[$node_idx]}"

    print_header "Wipe Node $node_num ($ip)"
    detect_cluster_type

    if ! check_reachable "$ip"; then
        log_error "Node $node_num ($ip) is not reachable"
        exit 1
    fi

    confirm "This will wipe storage on node $node_num!"

    case "$target" in
        nvme)
            if [[ "$CLUSTER_TYPE" == "k3s" || "$CLUSTER_TYPE" == "armbian" ]]; then
                wipe_nvme_ssh "$ip" "$node_num"
            else
                log_error "NVMe wipe via SSH only works on Armbian/K3s nodes"
                exit 1
            fi
            ;;
        emmc)
            if [[ "$CLUSTER_TYPE" == "k3s" || "$CLUSTER_TYPE" == "armbian" ]]; then
                wipe_emmc_ssh "$ip" "$node_num"
            else
                log_error "eMMC wipe via SSH only works on Armbian/K3s nodes"
                exit 1
            fi
            ;;
        all)
            if [[ "$CLUSTER_TYPE" == "talos" ]]; then
                wipe_talos_node "$ip" "$node_num"
            elif [[ "$CLUSTER_TYPE" == "k3s" || "$CLUSTER_TYPE" == "armbian" ]]; then
                wipe_nvme_ssh "$ip" "$node_num"
                wipe_emmc_ssh "$ip" "$node_num"
            else
                log_error "Cannot wipe node in current state ($CLUSTER_TYPE)"
                exit 1
            fi
            ;;
        *)
            log_error "Unknown target: $target (use: nvme, emmc, or all)"
            exit 1
            ;;
    esac

    log_success "Node $node_num wipe complete"
}

cmd_power_off() {
    print_header "Power Off All Nodes"
    check_tpi

    confirm "This will power off all nodes!"

    for node in "${NODE_NUMBERS[@]}"; do
        log_info "Powering off node $node..."
        tpi power off -n "$node" 2>/dev/null || true
        sleep 1
    done

    sleep 3
    echo ""
    echo "Power status:"
    tpi power status 2>/dev/null || echo "Unable to query"

    log_success "All nodes powered off"
    log_info "Flash new images with: tpi flash -n <node> --image-path <image>"
}

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat << 'EOF'
Turing RK1 Cluster Wipe Script

Detects cluster type (Talos/K3s/Armbian) and wipes storage to prepare for
fresh deployment.

Usage: ./wipe-cluster.sh <command> [options]

Commands:
  status              Show cluster type and storage status
  nvme                Wipe NVMe drives on all nodes
  emmc                Wipe eMMC drives on all nodes (DANGER!)
  all                 Wipe both NVMe and eMMC (DANGER!)
  talos               Reset Talos cluster (graceful wipe)
  k3s                 Uninstall K3s and optionally wipe storage
  node <n> [target]   Wipe specific node (target: nvme|emmc|all)
  power-off           Power off all nodes via BMC
  help                Show this help message

Storage Targets:
  nvme    /dev/nvme0n1  - NVMe SSDs (worker data, Longhorn)
  emmc    /dev/mmcblk0  - eMMC flash (boot drive, OS)

Environment Variables:
  BMC_IP          BMC IP address (default: 10.10.88.70)
  SSH_USER        SSH user for Armbian nodes (default: root)
  TPI_HOSTNAME    TPI target host (default: BMC_IP)
  TPI_USERNAME    TPI authentication username
  TPI_PASSWORD    TPI authentication password

Examples:
  ./wipe-cluster.sh status           # Check cluster and storage status
  ./wipe-cluster.sh nvme             # Wipe NVMe on all nodes
  ./wipe-cluster.sh talos            # Reset Talos cluster
  ./wipe-cluster.sh k3s              # Uninstall K3s
  ./wipe-cluster.sh node 2 nvme      # Wipe NVMe on node 2 only
  ./wipe-cluster.sh all              # Full wipe for OS reinstall
  ./wipe-cluster.sh power-off        # Power off all nodes

Typical Workflows:

  Switch from K3s to Talos:
    1. ./wipe-cluster.sh k3s         # Uninstall K3s
    2. ./wipe-cluster.sh emmc        # Wipe boot drives
    3. tpi flash -n 1-4 --image-path images/latest/metal-arm64.raw
    4. ./scripts/deploy-talos-cluster.sh deploy

  Switch from Talos to K3s:
    1. ./wipe-cluster.sh talos       # Reset Talos
    2. ./wipe-cluster.sh power-off   # Power off nodes
    3. tpi flash -n 1-4 --image-path <armbian-image>
    4. ./scripts/deploy-k3s-cluster.sh

  Fresh Talos reinstall:
    1. ./wipe-cluster.sh talos       # Reset existing cluster
    2. ./scripts/deploy-talos-cluster.sh deploy

EOF
}

# =============================================================================
# Main
# =============================================================================

case "${1:-help}" in
    status)
        cmd_status
        ;;
    nvme)
        cmd_wipe_nvme
        ;;
    emmc)
        cmd_wipe_emmc
        ;;
    all)
        cmd_wipe_all
        ;;
    talos)
        cmd_wipe_talos
        ;;
    k3s)
        cmd_wipe_k3s
        ;;
    node)
        cmd_wipe_node "$2" "${3:-all}"
        ;;
    power-off|poweroff)
        cmd_power_off
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        log_error "Unknown command: $1"
        echo ""
        usage
        exit 1
        ;;
esac
