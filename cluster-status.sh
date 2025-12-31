#!/bin/bash
#
# Turing RK1 Cluster Status Script
# Detects cluster type (Talos or K3s) and provides health summary
#
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/cluster-config"

# Node IPs
CONTROL_PLANE_IP="10.10.88.73"
WORKER_IPS=("10.10.88.74" "10.10.88.75" "10.10.88.76")
ALL_NODE_IPS=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Cluster type (detected)
CLUSTER_TYPE=""

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

# =============================================================================
# Cluster Detection
# =============================================================================

detect_cluster_type() {
    print_section "Detecting Cluster Type"

    # Check if control plane is reachable
    if ! check_reachable "$CONTROL_PLANE_IP"; then
        log_error "Control plane ($CONTROL_PLANE_IP) is not reachable"
        exit 1
    fi

    # Method 1: Check for Talos API (port 50000 for maintenance, or talosctl)
    if talosctl --nodes "$CONTROL_PLANE_IP" version &>/dev/null 2>&1; then
        CLUSTER_TYPE="talos"
        log_success "Detected: Talos Linux cluster"
        return 0
    fi

    # Method 2: Check for K3s via SSH
    if ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$CONTROL_PLANE_IP" "which k3s" &>/dev/null 2>&1; then
        CLUSTER_TYPE="k3s"
        log_success "Detected: K3s on Armbian cluster"
        return 0
    fi

    # Method 3: Check for SSH access (likely K3s/Armbian)
    if ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$CONTROL_PLANE_IP" "echo ok" &>/dev/null 2>&1; then
        # SSH works but no k3s - might be pre-setup Armbian
        if ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$CONTROL_PLANE_IP" "systemctl is-active k3s" &>/dev/null 2>&1; then
            CLUSTER_TYPE="k3s"
            log_success "Detected: K3s on Armbian cluster"
            return 0
        fi
        log_warn "SSH accessible but K3s not detected - may be unconfigured Armbian"
        CLUSTER_TYPE="armbian"
        return 0
    fi

    # Method 4: Check Talos maintenance mode
    if nc -zw2 "$CONTROL_PLANE_IP" 50000 &>/dev/null 2>&1; then
        CLUSTER_TYPE="talos-maintenance"
        log_warn "Detected: Talos in maintenance mode (not configured)"
        return 0
    fi

    log_error "Unable to detect cluster type"
    log_info "Ensure nodes are running and accessible"
    exit 1
}

# =============================================================================
# Talos Cluster Status
# =============================================================================

get_talos_status() {
    print_header "Talos Linux Cluster Status"

    # Set talosconfig if available
    if [ -f "$CONFIG_DIR/talosconfig" ]; then
        export TALOSCONFIG="$CONFIG_DIR/talosconfig"
    fi

    # Node reachability
    print_section "Node Reachability"
    for ip in "${ALL_NODE_IPS[@]}"; do
        if check_reachable "$ip"; then
            echo -e "  $ip: ${GREEN}reachable${NC}"
        else
            echo -e "  $ip: ${RED}unreachable${NC}"
        fi
    done

    # Talos health
    print_section "Talos Health"
    if talosctl --nodes "$CONTROL_PLANE_IP" health --wait-timeout 10s 2>/dev/null; then
        log_success "Cluster health check passed"
    else
        log_warn "Health check reported issues (see above)"
    fi

    # Talos services
    print_section "Talos Services (Control Plane)"
    talosctl --nodes "$CONTROL_PLANE_IP" services 2>/dev/null | head -20 || log_warn "Could not get services"

    # etcd status
    print_section "etcd Status"
    talosctl --nodes "$CONTROL_PLANE_IP" etcd status 2>/dev/null || log_warn "Could not get etcd status"

    # Get kubeconfig if needed
    get_kubernetes_status "talos"
}

# =============================================================================
# K3s Cluster Status
# =============================================================================

get_k3s_status() {
    print_header "K3s on Armbian Cluster Status"

    # Node reachability and SSH check
    print_section "Node Reachability & SSH"
    for ip in "${ALL_NODE_IPS[@]}"; do
        if check_reachable "$ip"; then
            if ssh -o ConnectTimeout=3 -o BatchMode=yes root@"$ip" "echo ok" &>/dev/null 2>&1; then
                echo -e "  $ip: ${GREEN}reachable${NC} | SSH: ${GREEN}OK${NC}"
            else
                echo -e "  $ip: ${GREEN}reachable${NC} | SSH: ${YELLOW}no access${NC}"
            fi
        else
            echo -e "  $ip: ${RED}unreachable${NC}"
        fi
    done

    # K3s service status
    print_section "K3s Service Status"
    echo "Control Plane ($CONTROL_PLANE_IP):"
    ssh -o ConnectTimeout=5 root@"$CONTROL_PLANE_IP" "systemctl is-active k3s && k3s --version" 2>/dev/null || log_warn "Could not check K3s server"

    echo ""
    for ip in "${WORKER_IPS[@]}"; do
        echo "Agent ($ip):"
        ssh -o ConnectTimeout=5 root@"$ip" "systemctl is-active k3s-agent" 2>/dev/null || echo "  K3s agent not running or not accessible"
    done

    # System resources on each node
    print_section "Node Resources"
    for ip in "${ALL_NODE_IPS[@]}"; do
        echo -e "${BOLD}Node $ip:${NC}"
        ssh -o ConnectTimeout=5 root@"$ip" "
            echo \"  CPU: \$(nproc) cores\"
            echo \"  Memory: \$(free -h | awk '/^Mem:/ {print \$3 \"/\" \$2}')\"
            echo \"  Disk (root): \$(df -h / | awk 'NR==2 {print \$3 \"/\" \$2 \" (\" \$5 \" used)\"}')\"
            if mountpoint -q /var/lib/longhorn 2>/dev/null; then
                echo \"  Disk (longhorn): \$(df -h /var/lib/longhorn | awk 'NR==2 {print \$3 \"/\" \$2 \" (\" \$5 \" used)\"}')\"
            fi
        " 2>/dev/null || echo "  Could not get resources"
        echo ""
    done

    # Get kubernetes status
    get_kubernetes_status "k3s"
}

# =============================================================================
# Kubernetes Status (Common)
# =============================================================================

get_kubernetes_status() {
    local cluster_type=$1

    # Determine kubeconfig location
    local kubeconfig=""
    if [ "$cluster_type" = "talos" ]; then
        if [ -f "$CONFIG_DIR/kubeconfig" ]; then
            kubeconfig="$CONFIG_DIR/kubeconfig"
        else
            log_warn "No kubeconfig found at $CONFIG_DIR/kubeconfig"
            log_info "Run: talosctl kubeconfig --nodes $CONTROL_PLANE_IP -f $CONFIG_DIR/kubeconfig"
            return
        fi
    else
        # K3s kubeconfig locations
        if [ -f "$HOME/.kube/config-k3s-turing" ]; then
            kubeconfig="$HOME/.kube/config-k3s-turing"
        elif [ -f "$CONFIG_DIR/kubeconfig-k3s" ]; then
            kubeconfig="$CONFIG_DIR/kubeconfig-k3s"
        else
            # Try to fetch from server
            log_info "Fetching kubeconfig from K3s server..."
            mkdir -p "$CONFIG_DIR"
            if scp -o ConnectTimeout=5 root@"$CONTROL_PLANE_IP":/etc/rancher/k3s/k3s.yaml "$CONFIG_DIR/kubeconfig-k3s" 2>/dev/null; then
                sed -i "s/127.0.0.1/$CONTROL_PLANE_IP/g" "$CONFIG_DIR/kubeconfig-k3s"
                kubeconfig="$CONFIG_DIR/kubeconfig-k3s"
            else
                log_warn "Could not fetch kubeconfig"
                return
            fi
        fi
    fi

    export KUBECONFIG="$kubeconfig"

    # Test connectivity
    if ! kubectl cluster-info &>/dev/null 2>&1; then
        log_warn "Cannot connect to Kubernetes API"
        return
    fi

    # Kubernetes nodes
    print_section "Kubernetes Nodes"
    kubectl get nodes -o wide 2>/dev/null || log_warn "Could not get nodes"

    # Node conditions
    print_section "Node Conditions"
    kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,MEMORY:.status.conditions[?(@.type=="MemoryPressure")].status,DISK:.status.conditions[?(@.type=="DiskPressure")].status,PID:.status.conditions[?(@.type=="PIDPressure")].status' 2>/dev/null || true

    # Cluster resources
    print_section "Cluster Resources"
    echo "Namespaces: $(kubectl get namespaces --no-headers 2>/dev/null | wc -l)"
    echo "Pods (all): $(kubectl get pods -A --no-headers 2>/dev/null | wc -l)"
    echo "Services: $(kubectl get svc -A --no-headers 2>/dev/null | wc -l)"
    echo "Deployments: $(kubectl get deployments -A --no-headers 2>/dev/null | wc -l)"
    echo "PVCs: $(kubectl get pvc -A --no-headers 2>/dev/null | wc -l)"

    # Pod status summary
    print_section "Pod Status Summary"
    kubectl get pods -A --no-headers 2>/dev/null | awk '{status[$4]++} END {for (s in status) printf "  %-15s %d\n", s":", status[s]}' | sort || true

    # Workloads by namespace
    print_section "Workloads by Namespace"
    kubectl get pods -A --no-headers 2>/dev/null | awk '{ns[$1]++} END {for (n in ns) printf "  %-25s %d pods\n", n":", ns[n]}' | sort || true

    # Problem pods
    print_section "Problem Pods (non-Running/Completed)"
    local problem_pods
    problem_pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep -v -E "Running|Completed" || true)
    if [ -n "$problem_pods" ]; then
        echo "$problem_pods"
    else
        log_success "No problem pods found"
    fi

    # LoadBalancer services
    print_section "LoadBalancer Services"
    kubectl get svc -A --field-selector spec.type=LoadBalancer 2>/dev/null || echo "  No LoadBalancer services"

    # Ingresses
    print_section "Ingress Resources"
    kubectl get ingress -A 2>/dev/null || echo "  No ingress resources"

    # Storage
    print_section "Persistent Volume Claims"
    kubectl get pvc -A 2>/dev/null || echo "  No PVCs"

    # Longhorn status (if installed)
    if kubectl get namespace longhorn-system &>/dev/null 2>&1; then
        print_section "Longhorn Storage Status"
        echo "Longhorn Nodes:"
        kubectl get nodes.longhorn.io -n longhorn-system 2>/dev/null || echo "  Could not get Longhorn nodes"
        echo ""
        echo "Longhorn Volumes:"
        kubectl get volumes.longhorn.io -n longhorn-system 2>/dev/null || echo "  No Longhorn volumes"
    fi

    # Recent events
    print_section "Recent Warning Events (last 10)"
    kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -11 | head -10 || echo "  No warning events"
}

# =============================================================================
# Armbian (Pre-K3s) Status
# =============================================================================

get_armbian_status() {
    print_header "Armbian Node Status (K3s Not Installed)"

    print_section "Node Status"
    for ip in "${ALL_NODE_IPS[@]}"; do
        echo -e "${BOLD}Node $ip:${NC}"
        if ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$ip" "
            echo \"  Hostname: \$(hostname)\"
            echo \"  Uptime: \$(uptime -p)\"
            echo \"  OS: \$(cat /etc/os-release | grep PRETTY_NAME | cut -d'\"' -f2)\"
            echo \"  Kernel: \$(uname -r)\"
            echo \"  CPU: \$(nproc) cores\"
            echo \"  Memory: \$(free -h | awk '/^Mem:/ {print \$3 \"/\" \$2}')\"
        " 2>/dev/null; then
            :
        else
            echo "  Could not connect"
        fi
        echo ""
    done

    log_info "To install K3s, run: ./scripts/deploy-k3s-cluster.sh"
}

# =============================================================================
# Talos Maintenance Mode Status
# =============================================================================

get_talos_maintenance_status() {
    print_header "Talos Maintenance Mode Status"

    print_section "Node Status"
    for ip in "${ALL_NODE_IPS[@]}"; do
        if nc -zw2 "$ip" 50000 &>/dev/null 2>&1; then
            echo -e "  $ip: ${YELLOW}maintenance mode${NC}"
        elif check_reachable "$ip"; then
            echo -e "  $ip: ${GREEN}reachable${NC} (not in maintenance)"
        else
            echo -e "  $ip: ${RED}unreachable${NC}"
        fi
    done

    log_info "Nodes are in maintenance mode - not yet configured"
    log_info "To deploy cluster, run: ./deploy-cluster.sh deploy"
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Turing RK1 Cluster Status"

    # Detect cluster type
    detect_cluster_type

    # Get status based on cluster type
    case "$CLUSTER_TYPE" in
        talos)
            get_talos_status
            ;;
        k3s)
            get_k3s_status
            ;;
        armbian)
            get_armbian_status
            ;;
        talos-maintenance)
            get_talos_maintenance_status
            ;;
        *)
            log_error "Unknown cluster type: $CLUSTER_TYPE"
            exit 1
            ;;
    esac

    print_header "Status Check Complete"
}

main "$@"
