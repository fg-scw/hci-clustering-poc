#!/bin/bash

################################################################################
# Common Configuration Script
# Sources environment variables and provides utility functions
################################################################################

set -e

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# Find the repository root (where .env file should be)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load environment variables
ENV_FILE="${REPO_ROOT}/.env"

if [ -f "${ENV_FILE}" ]; then
    echo -e "${BLUE}Loading configuration from ${ENV_FILE}${NC}"
    set -a
    source "${ENV_FILE}"
    set +a
else
    echo -e "${YELLOW}Warning: ${ENV_FILE} not found. Using defaults.${NC}"
    echo -e "${YELLOW}Copy .env.example to .env and customize.${NC}"
fi

# =============================================================================
# Default Values (if not set in .env)
# =============================================================================

# Cluster
CLUSTER_NAME="${CLUSTER_NAME:-proxmox-hci}"

# Network defaults
PUBLIC_NETWORK="${PUBLIC_NETWORK:-172.16.28.0/22}"
CLUSTER_NETWORK="${CLUSTER_NETWORK:-172.16.36.0/22}"
PUBLIC_BRIDGE="${PUBLIC_BRIDGE:-vmbr1}"
CLUSTER_BRIDGE="${CLUSTER_BRIDGE:-vmbr2}"
MTU="${MTU:-9000}"

# Ceph defaults
OSD_DISKS="${OSD_DISKS:-nvme1n1 nvme2n1 nvme3n1}"
CEPH_POOL_VM="${CEPH_POOL_VM:-vm-storage}"
CEPH_POOL_CT="${CEPH_POOL_CT:-ct-storage}"
CEPH_POOL_ISCSI="${CEPH_POOL_ISCSI:-iscsi-pool}"
CEPH_REPLICA_SIZE="${CEPH_REPLICA_SIZE:-3}"
CEPH_MIN_SIZE="${CEPH_MIN_SIZE:-2}"
CEPH_PG_NUM="${CEPH_PG_NUM:-32}"

# iSCSI defaults
ISCSI_ENABLED="${ISCSI_ENABLED:-false}"
ISCSI_TARGET_IQN="${ISCSI_TARGET_IQN:-iqn.2025-01.com.scaleway:storage}"
ISCSI_PORTAL_PORT="${ISCSI_PORTAL_PORT:-3260}"

# =============================================================================
# Utility Functions
# =============================================================================

# Print section header
print_header() {
    echo -e "\n${GREEN}================================================================${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}================================================================${NC}\n"
}

# Print step
print_step() {
    echo -e "${YELLOW}[STEP $1] $2${NC}"
}

# Print success
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Print warning
print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Print error
print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Check if command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "Command not found: $1"
        return 1
    fi
    return 0
}

# Get current node's IP on public bridge
get_public_ip() {
    ip -4 addr show "${PUBLIC_BRIDGE}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo ""
}

# Get current node's IP on cluster bridge
get_cluster_ip() {
    ip -4 addr show "${CLUSTER_BRIDGE}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo ""
}

# Check if in Proxmox cluster
is_in_cluster() {
    pvecm status &>/dev/null && return 0 || return 1
}

# Check if Ceph is installed
is_ceph_installed() {
    command -v ceph &>/dev/null && return 0 || return 1
}

# Wait for user confirmation
confirm_continue() {
    local message="${1:-Continue?}"
    read -p "${message} (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
}

# Wait for service to be ready
wait_for_service() {
    local service="$1"
    local max_attempts="${2:-30}"
    local attempt=1
    
    echo -n "Waiting for ${service}..."
    while [ $attempt -le $max_attempts ]; do
        if systemctl is-active --quiet "${service}"; then
            echo -e " ${GREEN}ready${NC}"
            return 0
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done
    echo -e " ${RED}timeout${NC}"
    return 1
}

# Detect physical network interface
detect_physical_interface() {
    # Try common interface names on Scaleway Elastic Metal
    for iface in enp67s0f0 enp1s0f0 eth0; do
        if ip link show "$iface" &>/dev/null; then
            echo "$iface"
            return 0
        fi
    done
    
    # Fallback: find first non-loopback, non-bridge interface
    ip -o link show | awk -F': ' '!/lo|vmbr|docker|veth/{print $2; exit}'
}

# Detect assigned VLANs from interface names
detect_vlans() {
    local iface="${1:-$(detect_physical_interface)}"
    local vlans=""
    
    for vlan_iface in /sys/class/net/${iface}.*; do
        if [ -e "$vlan_iface" ]; then
            vlan=$(basename "$vlan_iface" | cut -d. -f2)
            vlans="${vlans} ${vlan}"
        fi
    done
    
    echo "$vlans" | xargs  # Trim whitespace
}

# Get list of NVMe devices suitable for OSDs
get_osd_candidates() {
    # List NVMe devices, excluding the first one (usually system disk)
    lsblk -d -n -o NAME,TYPE | grep nvme | awk 'NR>1 {print $1}'
}

# Check network connectivity to another node
check_node_connectivity() {
    local target_ip="$1"
    local timeout="${2:-5}"
    
    if ping -c 1 -W "$timeout" "$target_ip" &>/dev/null; then
        return 0
    fi
    return 1
}

# Export functions for use in other scripts
export -f print_header print_step print_success print_warning print_error
export -f check_root check_command confirm_continue wait_for_service
export -f get_public_ip get_cluster_ip is_in_cluster is_ceph_installed
export -f detect_physical_interface detect_vlans get_osd_candidates
export -f check_node_connectivity
