#!/bin/bash

################################################################################
# Script 04: Configure QDevice for HA Quorum
# 
# This script configures a QDevice (external quorum device) to improve
# cluster availability. With 3 nodes + QDevice, the cluster can survive
# losing 2 nodes.
#
# Prerequisites:
# - QDevice VM/Instance running Debian/Ubuntu
# - QDevice accessible from all cluster nodes
#
# Run on: Node 1 (after Ceph installation)
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/config.sh"

check_root

print_header "QDevice Configuration"

# =============================================================================
# Configuration
# =============================================================================

QDEVICE_IP="${QDEVICE_IP:-172.16.28.10}"
QDEVICE_USER="${QDEVICE_USER:-root}"

echo "QDevice IP: ${QDEVICE_IP}"
echo ""

# =============================================================================
# Pre-flight checks
# =============================================================================

if ! is_in_cluster; then
    print_error "Node is not in a Proxmox cluster"
    exit 1
fi

# Check connectivity to QDevice
print_step "1/5" "Checking QDevice connectivity..."

if ! check_node_connectivity "$QDEVICE_IP"; then
    print_error "Cannot reach QDevice at ${QDEVICE_IP}"
    echo ""
    echo "Ensure the QDevice VM/Instance is:"
    echo "  1. Running and accessible"
    echo "  2. Connected to the same Private Network"
    echo "  3. Has IP ${QDEVICE_IP} configured"
    exit 1
fi

print_success "QDevice is reachable"

# =============================================================================
# Install corosync-qnetd on QDevice
# =============================================================================
print_step "2/5" "Installing corosync-qnetd on QDevice..."

echo "Connecting to QDevice to install packages..."
echo "You may be prompted for the QDevice root password."

ssh "${QDEVICE_USER}@${QDEVICE_IP}" << 'REMOTE_SCRIPT'
#!/bin/bash
set -e

# Update and install
apt update
apt install -y corosync-qnetd

# Enable and start service
systemctl enable corosync-qnetd
systemctl start corosync-qnetd

# Check status
systemctl status corosync-qnetd --no-pager

echo "corosync-qnetd installed successfully"
REMOTE_SCRIPT

if [ $? -ne 0 ]; then
    print_error "Failed to configure QDevice server"
    exit 1
fi

print_success "QDevice server configured"

# =============================================================================
# Install corosync-qdevice on cluster nodes
# =============================================================================
print_step "3/5" "Installing corosync-qdevice on cluster nodes..."

apt install -y corosync-qdevice

print_success "corosync-qdevice installed"

# =============================================================================
# Setup QDevice in cluster
# =============================================================================
print_step "4/5" "Configuring QDevice in Proxmox cluster..."

# Remove existing QDevice if any
pvecm qdevice remove 2>/dev/null || true

# Add QDevice
echo "Setting up QDevice connection..."
echo "You will be prompted for the QDevice root password."

pvecm qdevice setup "${QDEVICE_IP}"

if [ $? -ne 0 ]; then
    print_error "Failed to setup QDevice"
    echo ""
    echo "Manual setup:"
    echo "  pvecm qdevice setup ${QDEVICE_IP}"
    exit 1
fi

print_success "QDevice configured"

# =============================================================================
# Verify
# =============================================================================
print_step "5/5" "Verifying QDevice status..."

sleep 5

echo ""
echo "Cluster Status:"
echo "---------------"
pvecm status

echo ""
echo "QDevice Status:"
echo "---------------"
corosync-qdevice-tool -s 2>/dev/null || echo "Waiting for QDevice connection..."

echo ""
echo "Quorum Status:"
echo "--------------"
pvecm qdevice status 2>/dev/null || corosync-quorumtool -s

# =============================================================================
# Complete
# =============================================================================
print_header "QDevice Configuration Complete"

echo "The cluster now has improved quorum:"
echo "  - 3 cluster nodes = 3 votes"
echo "  - 1 QDevice = 1 vote"
echo "  - Total = 4 votes"
echo "  - Quorum = 3 votes (majority)"
echo ""
echo "Cluster can now survive losing 1 node without QDevice,"
echo "or losing 2 nodes with QDevice operational."
echo ""
echo "Next steps:"
echo "  1. Run 05-setup-ha.sh to configure VM high availability"
