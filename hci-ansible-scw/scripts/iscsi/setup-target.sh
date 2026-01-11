#!/bin/bash

################################################################################
# Script: Setup iSCSI Target
# 
# This script configures iSCSI target to export Ceph RBD volumes:
# - Installs targetcli
# - Creates RBD image in Ceph
# - Configures LIO target
# - Sets up CHAP authentication
#
# Prerequisites:
# - Ceph cluster operational
# - ISCSI_ENABLED=true in .env
#
# Run on: Any cluster node (typically node 1)
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/config.sh"

check_root

print_header "iSCSI Target Configuration"

# =============================================================================
# Configuration
# =============================================================================

POOL="${CEPH_POOL_ISCSI:-iscsi-pool}"
IMAGE="${ISCSI_DEFAULT_IMAGE:-disk1}"
SIZE="${ISCSI_DEFAULT_SIZE:-100G}"
TARGET_IQN="${ISCSI_TARGET_IQN:-iqn.2025-01.com.scaleway:storage}"
CHAP_USER="${ISCSI_CHAP_USERNAME:-iscsi-user}"
CHAP_PASS="${ISCSI_CHAP_PASSWORD}"
PORTAL_IP=$(get_public_ip)
PORTAL_PORT="${ISCSI_PORTAL_PORT:-3260}"

echo "Configuration:"
echo "  Pool:       ${POOL}"
echo "  Image:      ${IMAGE}"
echo "  Size:       ${SIZE}"
echo "  Target IQN: ${TARGET_IQN}"
echo "  Portal:     ${PORTAL_IP}:${PORTAL_PORT}"
echo "  CHAP User:  ${CHAP_USER}"
echo ""

# Prompt for CHAP password if not set
if [ -z "$CHAP_PASS" ]; then
    read -s -p "Enter CHAP password: " CHAP_PASS
    echo ""
fi

# =============================================================================
# Pre-flight checks
# =============================================================================

if ! is_ceph_installed; then
    print_error "Ceph is not installed"
    exit 1
fi

if ! ceph -s &>/dev/null; then
    print_error "Cannot connect to Ceph cluster"
    exit 1
fi

print_success "Ceph cluster is accessible"

# =============================================================================
# Step 1: Install targetcli
# =============================================================================
print_step "1/6" "Installing targetcli..."

apt install -y targetcli-fb

print_success "targetcli installed"

# =============================================================================
# Step 2: Create Ceph pool (if not exists)
# =============================================================================
print_step "2/6" "Ensuring iSCSI pool exists..."

if ! ceph osd pool ls | grep -q "^${POOL}$"; then
    pveceph pool create "${POOL}"
    ceph osd pool set "${POOL}" size "${CEPH_REPLICA_SIZE:-3}"
    ceph osd pool set "${POOL}" min_size "${CEPH_MIN_SIZE:-2}"
    ceph osd pool set "${POOL}" pg_num "${CEPH_PG_NUM:-32}"
    print_success "Pool '${POOL}' created"
else
    print_success "Pool '${POOL}' exists"
fi

# =============================================================================
# Step 3: Create RBD image
# =============================================================================
print_step "3/6" "Creating RBD image..."

if rbd info "${POOL}/${IMAGE}" &>/dev/null; then
    print_warning "Image '${POOL}/${IMAGE}' already exists"
else
    rbd create "${POOL}/${IMAGE}" --size "${SIZE}"
    print_success "Image '${POOL}/${IMAGE}' created (${SIZE})"
fi

# Disable incompatible features for iSCSI
rbd feature disable "${POOL}/${IMAGE}" exclusive-lock object-map fast-diff deep-flatten 2>/dev/null || true

# =============================================================================
# Step 4: Map RBD image
# =============================================================================
print_step "4/6" "Mapping RBD image..."

# Check if already mapped
MAPPED_DEVICE=$(rbd showmapped | grep "${POOL}.*${IMAGE}" | awk '{print $5}')

if [ -n "$MAPPED_DEVICE" ]; then
    print_warning "Image already mapped to ${MAPPED_DEVICE}"
else
    rbd map "${POOL}/${IMAGE}"
    MAPPED_DEVICE=$(rbd showmapped | grep "${POOL}.*${IMAGE}" | awk '{print $5}')
    print_success "Image mapped to ${MAPPED_DEVICE}"
fi

if [ -z "$MAPPED_DEVICE" ]; then
    print_error "Failed to map RBD image"
    exit 1
fi

# =============================================================================
# Step 5: Configure iSCSI target
# =============================================================================
print_step "5/6" "Configuring iSCSI target..."

# Clear existing configuration for this target
targetcli /backstores/block delete "${IMAGE}" 2>/dev/null || true
targetcli /iscsi delete "${TARGET_IQN}" 2>/dev/null || true

# Create backstore
targetcli /backstores/block create name="${IMAGE}" dev="${MAPPED_DEVICE}"

# Create target
targetcli /iscsi create "${TARGET_IQN}"

# Create LUN
targetcli /iscsi/${TARGET_IQN}/tpg1/luns create /backstores/block/${IMAGE}

# Configure portal
targetcli /iscsi/${TARGET_IQN}/tpg1/portals delete 0.0.0.0 3260 2>/dev/null || true
targetcli /iscsi/${TARGET_IQN}/tpg1/portals create "${PORTAL_IP}" "${PORTAL_PORT}"

# Enable authentication
targetcli /iscsi/${TARGET_IQN}/tpg1 set attribute authentication=1
targetcli /iscsi/${TARGET_IQN}/tpg1 set attribute generate_node_acls=0
targetcli /iscsi/${TARGET_IQN}/tpg1 set attribute demo_mode_write_protect=0

# Configure allowed initiators
INITIATORS="${ISCSI_ALLOWED_INITIATORS}"

if [ -n "$INITIATORS" ]; then
    IFS=',' read -ra INITIATOR_ARRAY <<< "$INITIATORS"
    for initiator in "${INITIATOR_ARRAY[@]}"; do
        initiator=$(echo "$initiator" | xargs)  # trim whitespace
        echo "Adding initiator: ${initiator}"
        targetcli /iscsi/${TARGET_IQN}/tpg1/acls create "${initiator}"
        targetcli /iscsi/${TARGET_IQN}/tpg1/acls/${initiator} set auth userid="${CHAP_USER}"
        targetcli /iscsi/${TARGET_IQN}/tpg1/acls/${initiator} set auth password="${CHAP_PASS}"
    done
else
    print_warning "No initiators configured. Add them manually or update ISCSI_ALLOWED_INITIATORS"
    echo ""
    echo "To add an initiator manually:"
    echo "  targetcli /iscsi/${TARGET_IQN}/tpg1/acls create <initiator_iqn>"
    echo "  targetcli /iscsi/${TARGET_IQN}/tpg1/acls/<initiator_iqn> set auth userid=${CHAP_USER}"
    echo "  targetcli /iscsi/${TARGET_IQN}/tpg1/acls/<initiator_iqn> set auth password=<password>"
fi

# Save configuration
targetcli saveconfig

# Enable and restart service
systemctl enable rtslib-fb-targetctl
systemctl restart rtslib-fb-targetctl

print_success "iSCSI target configured"

# =============================================================================
# Step 6: Verify and display connection info
# =============================================================================
print_step "6/6" "Verifying configuration..."

echo ""
echo "iSCSI Target Configuration:"
echo "==========================="
targetcli ls

# =============================================================================
# Complete
# =============================================================================
print_header "iSCSI Target Setup Complete"

echo "Connection Information:"
echo "-----------------------"
echo "  Portal Address: ${PORTAL_IP}"
echo "  Portal Port:    ${PORTAL_PORT}"
echo "  Target IQN:     ${TARGET_IQN}"
echo "  CHAP Username:  ${CHAP_USER}"
echo "  CHAP Password:  <configured>"
echo ""
echo "RBD Image:"
echo "  Pool/Image:     ${POOL}/${IMAGE}"
echo "  Size:           ${SIZE}"
echo "  Device:         ${MAPPED_DEVICE}"
echo ""
echo "Client Setup:"
echo "  Linux:   ./scripts/clients/linux-initiator.sh"
echo "  Windows: ./scripts/clients/windows-initiator.ps1"
echo "  VMware:  See docs/05-iscsi-clients.md"
echo ""
echo "To add more LUNs:"
echo "  1. Create RBD image: rbd create ${POOL}/disk2 --size 100G"
echo "  2. Map image: rbd map ${POOL}/disk2"
echo "  3. Add to target: targetcli /backstores/block create name=disk2 dev=/dev/rbdX"
echo "  4. Create LUN: targetcli /iscsi/${TARGET_IQN}/tpg1/luns create /backstores/block/disk2"
