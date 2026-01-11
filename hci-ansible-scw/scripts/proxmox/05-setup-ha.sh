#!/bin/bash

################################################################################
# Script 05: Setup High Availability
# 
# This script configures High Availability for VMs:
# - Creates HA groups
# - Adds VMs to HA
# - Configures watchdog for fencing
#
# Usage: ./05-setup-ha.sh [VMID]
#
# Run on: Any cluster node
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/config.sh"

check_root

print_header "High Availability Setup"

# =============================================================================
# Pre-flight checks
# =============================================================================

if ! is_in_cluster; then
    print_error "Node is not in a Proxmox cluster"
    exit 1
fi

# Check quorum
if ! pvecm status | grep -q "Quorate:.*Yes"; then
    print_error "Cluster does not have quorum"
    print_error "Ensure all nodes are online or QDevice is configured"
    exit 1
fi

print_success "Cluster has quorum"

# =============================================================================
# Step 1: Configure Watchdog
# =============================================================================
print_step "1/4" "Configuring hardware watchdog..."

# Load softdog module
if ! lsmod | grep -q softdog; then
    modprobe softdog
    print_success "softdog module loaded"
fi

# Make persistent
if ! grep -q "^softdog" /etc/modules; then
    echo "softdog" >> /etc/modules
    print_success "softdog added to /etc/modules"
fi

# Verify watchdog
if [ -e /dev/watchdog ]; then
    print_success "Watchdog device available: /dev/watchdog"
else
    print_warning "Watchdog device not found"
fi

# =============================================================================
# Step 2: Create HA Group
# =============================================================================
print_step "2/4" "Creating HA group..."

HA_GROUP="production"
CLUSTER_NODES=$(pvecm nodes | awk '/^[[:space:]]*[0-9]/{print $3}' | paste -sd ',')

if ha-manager groupconfig "${HA_GROUP}" &>/dev/null; then
    print_warning "HA group '${HA_GROUP}' already exists"
else
    ha-manager groupadd "${HA_GROUP}" \
        --nodes "${CLUSTER_NODES}" \
        --nofailback 0 \
        --restricted 0
    
    print_success "HA group '${HA_GROUP}' created with nodes: ${CLUSTER_NODES}"
fi

# =============================================================================
# Step 3: Add VM to HA (if VMID provided)
# =============================================================================
print_step "3/4" "Configuring VM HA..."

VMID="$1"

if [ -n "$VMID" ]; then
    # Verify VM exists
    if ! qm status "$VMID" &>/dev/null; then
        print_error "VM ${VMID} does not exist"
        echo ""
        echo "Available VMs:"
        qm list
        exit 1
    fi
    
    # Check if already in HA
    if ha-manager status | grep -q "vm:${VMID}"; then
        print_warning "VM ${VMID} already in HA"
    else
        ha-manager add "vm:${VMID}" \
            --state started \
            --max_restart 3 \
            --max_relocate 3 \
            --group "${HA_GROUP}"
        
        print_success "VM ${VMID} added to HA group '${HA_GROUP}'"
    fi
else
    echo "No VMID provided. Skipping VM HA configuration."
    echo ""
    echo "To add a VM to HA later:"
    echo "  ha-manager add vm:<VMID> --state started --group ${HA_GROUP}"
    echo ""
    echo "Or run: $0 <VMID>"
fi

# =============================================================================
# Step 4: Verify HA Status
# =============================================================================
print_step "4/4" "Verifying HA status..."

echo ""
echo "HA Manager Status:"
echo "------------------"
ha-manager status

echo ""
echo "HA Groups:"
echo "----------"
ha-manager groupconfig "${HA_GROUP}" 2>/dev/null || echo "Group config not available"

echo ""
echo "HA Resources:"
echo "-------------"
ha-manager config

# =============================================================================
# Complete
# =============================================================================
print_header "HA Configuration Complete"

echo "High Availability is now configured."
echo ""
echo "HA Behavior:"
echo "  - VMs will automatically restart on node failure"
echo "  - Max restart attempts: 3"
echo "  - Max relocations: 3"
echo "  - Typical failover time: 30-60 seconds"
echo ""
echo "Useful commands:"
echo "  ha-manager status              # View HA status"
echo "  ha-manager add vm:<VMID>       # Add VM to HA"
echo "  ha-manager remove vm:<VMID>    # Remove VM from HA"
echo "  ha-manager set vm:<VMID> --state stopped  # Stop VM via HA"
echo ""
echo "Test HA (CAUTION - will disrupt services):"
echo "  systemctl stop pve-cluster     # Simulate node failure"
