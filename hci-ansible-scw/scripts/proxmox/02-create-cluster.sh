#!/bin/bash

################################################################################
# Script 02: Create/Join Proxmox Cluster
# 
# This script either creates a new cluster (on node 1) or joins an existing
# cluster (on nodes 2+).
#
# Run on: All nodes (node 1 first)
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/config.sh"

check_root

print_header "Proxmox Cluster Setup"

# Get current node's IP
CURRENT_IP=$(get_public_ip)

if [ -z "$CURRENT_IP" ]; then
    print_error "Cannot determine current node IP on ${PUBLIC_BRIDGE}"
    print_error "Ensure network is configured correctly"
    exit 1
fi

echo "Current node:     $(hostname)"
echo "Current IP:       ${CURRENT_IP}"
echo "Cluster name:     ${CLUSTER_NAME}"
echo "First node IP:    ${NODE1_PUBLIC_IP:-172.16.28.2}"
echo ""

# =============================================================================
# Check if already in cluster
# =============================================================================

if is_in_cluster; then
    print_success "Already in a cluster"
    echo ""
    pvecm status
    exit 0
fi

# =============================================================================
# Determine if this is node 1 (cluster creator) or joining node
# =============================================================================

NODE1_IP="${NODE1_PUBLIC_IP:-172.16.28.2}"

if [ "$CURRENT_IP" == "$NODE1_IP" ]; then
    # =============================================================================
    # Create new cluster (Node 1)
    # =============================================================================
    print_step "1/2" "Creating new cluster..."
    
    echo "This will create a new cluster named '${CLUSTER_NAME}'"
    confirm_continue
    
    # Create cluster with link on public network
    pvecm create "${CLUSTER_NAME}" --link0 "${CURRENT_IP}"
    
    print_success "Cluster '${CLUSTER_NAME}' created"
    
    print_step "2/2" "Verifying cluster status..."
    sleep 3
    pvecm status
    
    print_header "Cluster Created Successfully"
    echo ""
    echo "Next steps:"
    echo "  1. Run this script on nodes 2 and 3 to join them"
    echo "  2. Then run 03-install-ceph.sh on this node"
    echo ""
    echo "Join command for other nodes:"
    echo "  pvecm add ${CURRENT_IP} --link0 <NODE_IP>"
    
else
    # =============================================================================
    # Join existing cluster (Nodes 2+)
    # =============================================================================
    print_step "1/3" "Checking connectivity to cluster..."
    
    if ! check_node_connectivity "$NODE1_IP"; then
        print_error "Cannot reach node 1 at ${NODE1_IP}"
        print_error "Ensure network is configured and node 1 has cluster created"
        exit 1
    fi
    
    print_success "Node 1 is reachable"
    
    print_step "2/3" "Joining cluster..."
    
    echo "This will join the cluster at ${NODE1_IP}"
    echo "You will need to enter the root password for ${NODE1_IP}"
    confirm_continue
    
    # Join cluster
    pvecm add "${NODE1_IP}" --link0 "${CURRENT_IP}"
    
    print_success "Joined cluster"
    
    print_step "3/3" "Verifying cluster status..."
    sleep 5
    pvecm status
    pvecm nodes
    
    print_header "Node Joined Successfully"
    echo ""
    echo "Cluster nodes:"
    pvecm nodes
fi
