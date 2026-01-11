#!/bin/bash

################################################################################
# Script 03: Install and Configure Ceph
# 
# This script installs Ceph Squid and creates the storage cluster:
# - Installs Ceph packages
# - Initializes Ceph cluster
# - Creates MONs and MGRs on all nodes
# - Creates OSDs on available NVMe disks
# - Creates storage pools
# - Enables dashboard
#
# Run on: Node 1 (after all nodes joined cluster)
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/config.sh"

check_root

print_header "Ceph Installation and Configuration"

# =============================================================================
# Pre-flight checks
# =============================================================================

if ! is_in_cluster; then
    print_error "Node is not in a Proxmox cluster"
    print_error "Run 02-create-cluster.sh first"
    exit 1
fi

# Get cluster node count
NODE_COUNT=$(pvecm nodes 2>/dev/null | grep -c "^[[:space:]]*[0-9]" || echo "1")
echo "Cluster nodes detected: ${NODE_COUNT}"

if [ "$NODE_COUNT" -lt 3 ]; then
    print_warning "Only ${NODE_COUNT} node(s) in cluster. Ceph requires 3+ nodes for production."
    confirm_continue "Continue anyway?"
fi

# =============================================================================
# Step 1: Install Ceph
# =============================================================================
print_step "1/8" "Installing Ceph packages..."

pveceph install --repository no-subscription --version squid

print_success "Ceph installed"

# =============================================================================
# Step 2: Initialize Ceph
# =============================================================================
print_step "2/8" "Initializing Ceph cluster..."

if [ -f /etc/ceph/ceph.conf ]; then
    print_warning "Ceph already initialized. Skipping."
else
    pveceph init \
        --network "${PUBLIC_NETWORK}" \
        --cluster-network "${CLUSTER_NETWORK}"
    
    print_success "Ceph initialized"
fi

# =============================================================================
# Step 3: Create MONs
# =============================================================================
print_step "3/8" "Creating Ceph Monitors..."

# Get list of cluster nodes
CLUSTER_NODES=$(pvecm nodes | awk '/^[[:space:]]*[0-9]/{print $3}')

for node in $CLUSTER_NODES; do
    echo "Creating MON on ${node}..."
    pveceph mon create --mon-address "" || print_warning "MON may already exist on ${node}"
done

print_success "Monitors created"

# Verify MONs
echo ""
ceph mon stat

# =============================================================================
# Step 4: Create MGRs
# =============================================================================
print_step "4/8" "Creating Ceph Managers..."

for node in $CLUSTER_NODES; do
    echo "Creating MGR on ${node}..."
    pveceph mgr create || print_warning "MGR may already exist on ${node}"
done

print_success "Managers created"

# =============================================================================
# Step 5: Create OSDs
# =============================================================================
print_step "5/8" "Creating OSDs..."

echo ""
echo "This step requires creating OSDs on each node."
echo "OSDs should be created on: ${OSD_DISKS}"
echo ""

# Check if any OSDs exist
EXISTING_OSDS=$(ceph osd tree 2>/dev/null | grep -c "osd\." || echo "0")

if [ "$EXISTING_OSDS" -gt 0 ]; then
    print_warning "${EXISTING_OSDS} OSDs already exist"
    echo ""
    ceph osd tree
    echo ""
    read -p "Skip OSD creation? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        print_success "Skipping OSD creation"
    fi
else
    echo "Creating OSDs on local node..."
    echo ""
    
    # Create OSDs on local node's disks
    for disk in $OSD_DISKS; do
        DEVICE="/dev/${disk}"
        
        if [ -b "$DEVICE" ]; then
            echo "Creating OSD on ${DEVICE}..."
            
            # Check if disk is already used
            if pvesm list local-lvm 2>/dev/null | grep -q "$disk"; then
                print_warning "${DEVICE} appears to be in use. Skipping."
                continue
            fi
            
            # Create OSD
            pveceph osd create "${DEVICE}" || print_warning "Failed to create OSD on ${DEVICE}"
        else
            print_warning "Device ${DEVICE} not found"
        fi
    done
    
    echo ""
    print_warning "Remember to create OSDs on other nodes via Proxmox Web UI"
    echo "  Go to: Node → Ceph → OSD → Create"
    echo "  Select disks: ${OSD_DISKS}"
fi

# Wait for OSDs to come up
echo ""
echo "Waiting for OSDs..."
sleep 10

ceph osd tree

# =============================================================================
# Step 6: Create Pools
# =============================================================================
print_step "6/8" "Creating storage pools..."

# VM Storage Pool
if ! ceph osd pool ls | grep -q "^${CEPH_POOL_VM}$"; then
    pveceph pool create "${CEPH_POOL_VM}" --add_storages
    ceph osd pool set "${CEPH_POOL_VM}" size "${CEPH_REPLICA_SIZE}"
    ceph osd pool set "${CEPH_POOL_VM}" min_size "${CEPH_MIN_SIZE}"
    ceph osd pool set "${CEPH_POOL_VM}" pg_num "${CEPH_PG_NUM}"
    ceph osd pool set "${CEPH_POOL_VM}" pgp_num "${CEPH_PG_NUM}"
    print_success "Pool '${CEPH_POOL_VM}' created"
else
    print_warning "Pool '${CEPH_POOL_VM}' already exists"
fi

# Container Storage Pool
if ! ceph osd pool ls | grep -q "^${CEPH_POOL_CT}$"; then
    pveceph pool create "${CEPH_POOL_CT}" --add_storages
    ceph osd pool set "${CEPH_POOL_CT}" size "${CEPH_REPLICA_SIZE}"
    ceph osd pool set "${CEPH_POOL_CT}" min_size "${CEPH_MIN_SIZE}"
    ceph osd pool set "${CEPH_POOL_CT}" pg_num "${CEPH_PG_NUM}"
    ceph osd pool set "${CEPH_POOL_CT}" pgp_num "${CEPH_PG_NUM}"
    print_success "Pool '${CEPH_POOL_CT}' created"
else
    print_warning "Pool '${CEPH_POOL_CT}' already exists"
fi

# iSCSI Pool (if enabled)
if [ "${ISCSI_ENABLED}" == "true" ]; then
    if ! ceph osd pool ls | grep -q "^${CEPH_POOL_ISCSI}$"; then
        pveceph pool create "${CEPH_POOL_ISCSI}"
        ceph osd pool set "${CEPH_POOL_ISCSI}" size "${CEPH_REPLICA_SIZE}"
        ceph osd pool set "${CEPH_POOL_ISCSI}" min_size "${CEPH_MIN_SIZE}"
        ceph osd pool set "${CEPH_POOL_ISCSI}" pg_num "${CEPH_PG_NUM}"
        ceph osd pool set "${CEPH_POOL_ISCSI}" pgp_num "${CEPH_PG_NUM}"
        print_success "Pool '${CEPH_POOL_ISCSI}' created"
    fi
fi

echo ""
ceph df

# =============================================================================
# Step 7: Configure Dashboard
# =============================================================================
print_step "7/8" "Configuring Ceph Dashboard..."

# Install dashboard module
apt install -y ceph-mgr-dashboard

# Enable dashboard
ceph mgr module enable dashboard || print_warning "Dashboard may already be enabled"

# Create self-signed certificate
ceph dashboard create-self-signed-cert 2>/dev/null || true

# Set dashboard credentials
DASH_USER="${DASHBOARD_ADMIN_USER:-admin}"
DASH_PASS="${DASHBOARD_ADMIN_PASSWORD}"

if [ -z "$DASH_PASS" ]; then
    echo ""
    read -s -p "Enter dashboard admin password: " DASH_PASS
    echo ""
fi

# Create admin user
echo "$DASH_PASS" | ceph dashboard ac-user-create "$DASH_USER" -i - administrator 2>/dev/null || \
    echo "$DASH_PASS" | ceph dashboard ac-user-set-password "$DASH_USER" -i - 2>/dev/null || \
    print_warning "Dashboard user may already exist"

print_success "Dashboard configured"

# Get dashboard URL
DASHBOARD_URL=$(ceph mgr services | jq -r '.dashboard // empty')
if [ -n "$DASHBOARD_URL" ]; then
    echo "Dashboard URL: ${DASHBOARD_URL}"
fi

# =============================================================================
# Step 8: Final Status
# =============================================================================
print_step "8/8" "Checking Ceph health..."

echo ""
ceph -s
echo ""
ceph health detail

# =============================================================================
# Complete
# =============================================================================
print_header "Ceph Installation Complete"

echo "Summary:"
echo "--------"
ceph -s | head -20

echo ""
echo "Storage pools:"
ceph df

echo ""
echo "Dashboard: ${DASHBOARD_URL:-https://$(get_public_ip):8443}"
echo "Username:  ${DASH_USER}"
echo ""

echo "Next steps:"
echo "  1. Create OSDs on other nodes via Web UI if not done"
echo "  2. (Optional) Run 04-configure-qdevice.sh for HA quorum"
echo "  3. (Optional) Run 05-setup-ha.sh to configure VM HA"
echo "  4. Run 06-optimize.sh for performance tuning"
