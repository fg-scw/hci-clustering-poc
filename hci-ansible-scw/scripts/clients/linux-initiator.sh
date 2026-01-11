#!/bin/bash

################################################################################
# Script: Linux iSCSI Initiator Setup
# 
# This script configures a Linux client to connect to the iSCSI target:
# - Installs open-iscsi
# - Discovers targets
# - Configures CHAP authentication
# - Connects and mounts volume
#
# Run on: Linux client machine
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }

# =============================================================================
# Configuration - UPDATE THESE VALUES
# =============================================================================

TARGET_PORTAL="${TARGET_PORTAL:-172.16.28.2}"
TARGET_PORT="${TARGET_PORT:-3260}"
TARGET_IQN="${TARGET_IQN:-iqn.2025-01.com.scaleway:storage}"
CHAP_USERNAME="${CHAP_USERNAME:-iscsi-user}"
CHAP_PASSWORD="${CHAP_PASSWORD:-}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/iscsi}"

echo "=== Linux iSCSI Initiator Setup ==="
echo ""
echo "Configuration:"
echo "  Target Portal: ${TARGET_PORTAL}:${TARGET_PORT}"
echo "  Target IQN:    ${TARGET_IQN}"
echo "  CHAP Username: ${CHAP_USERNAME}"
echo "  Mount Point:   ${MOUNT_POINT}"
echo ""

# Prompt for password if not set
if [ -z "$CHAP_PASSWORD" ]; then
    read -s -p "Enter CHAP password: " CHAP_PASSWORD
    echo ""
fi

# Check root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
fi

# =============================================================================
# Step 1: Install open-iscsi
# =============================================================================
echo ""
echo "[1/6] Installing open-iscsi..."

if command -v apt &>/dev/null; then
    apt update
    apt install -y open-iscsi
elif command -v yum &>/dev/null; then
    yum install -y iscsi-initiator-utils
elif command -v dnf &>/dev/null; then
    dnf install -y iscsi-initiator-utils
else
    print_error "Unsupported package manager"
    exit 1
fi

print_success "open-iscsi installed"

# =============================================================================
# Step 2: Configure initiator name
# =============================================================================
echo ""
echo "[2/6] Configuring initiator..."

# Get current initiator name
INITIATOR_NAME=$(cat /etc/iscsi/initiatorname.iscsi | grep -oP '(?<=InitiatorName=).*')
echo "Initiator Name: ${INITIATOR_NAME}"

# Configure CHAP authentication
cat > /etc/iscsi/iscsid.conf.d/chap.conf << EOF
# CHAP Authentication for ${TARGET_IQN}
node.session.auth.authmethod = CHAP
node.session.auth.username = ${CHAP_USERNAME}
node.session.auth.password = ${CHAP_PASSWORD}

# Discovery authentication (if required)
discovery.sendtargets.auth.authmethod = CHAP
discovery.sendtargets.auth.username = ${CHAP_USERNAME}
discovery.sendtargets.auth.password = ${CHAP_PASSWORD}
EOF

# Enable and start service
systemctl enable iscsid
systemctl restart iscsid

print_success "Initiator configured"

# =============================================================================
# Step 3: Discover targets
# =============================================================================
echo ""
echo "[3/6] Discovering targets..."

iscsiadm -m discovery -t sendtargets -p "${TARGET_PORTAL}:${TARGET_PORT}"

print_success "Discovery complete"

# =============================================================================
# Step 4: Connect to target
# =============================================================================
echo ""
echo "[4/6] Connecting to target..."

# Update node configuration with CHAP
iscsiadm -m node -T "${TARGET_IQN}" -p "${TARGET_PORTAL}:${TARGET_PORT}" \
    --op update -n node.session.auth.authmethod -v CHAP
iscsiadm -m node -T "${TARGET_IQN}" -p "${TARGET_PORTAL}:${TARGET_PORT}" \
    --op update -n node.session.auth.username -v "${CHAP_USERNAME}"
iscsiadm -m node -T "${TARGET_IQN}" -p "${TARGET_PORTAL}:${TARGET_PORT}" \
    --op update -n node.session.auth.password -v "${CHAP_PASSWORD}"

# Enable automatic login
iscsiadm -m node -T "${TARGET_IQN}" -p "${TARGET_PORTAL}:${TARGET_PORT}" \
    --op update -n node.startup -v automatic

# Login
iscsiadm -m node -T "${TARGET_IQN}" -p "${TARGET_PORTAL}:${TARGET_PORT}" --login

print_success "Connected to target"

# Wait for device to appear
sleep 3

# =============================================================================
# Step 5: Find and format disk
# =============================================================================
echo ""
echo "[5/6] Configuring disk..."

# Find the iSCSI device
ISCSI_DEVICE=$(lsblk -d -n -o NAME,TRAN | grep iscsi | awk '{print "/dev/"$1}' | head -1)

if [ -z "$ISCSI_DEVICE" ]; then
    print_error "No iSCSI device found"
    iscsiadm -m session -P 3
    exit 1
fi

echo "Found iSCSI device: ${ISCSI_DEVICE}"

# Check if already has filesystem
FSTYPE=$(lsblk -n -o FSTYPE "${ISCSI_DEVICE}" | head -1)

if [ -z "$FSTYPE" ]; then
    echo "Disk is not formatted."
    read -p "Format with ext4? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Create partition
        parted -s "${ISCSI_DEVICE}" mklabel gpt
        parted -s "${ISCSI_DEVICE}" mkpart primary ext4 0% 100%
        
        sleep 2
        
        # Format
        PARTITION="${ISCSI_DEVICE}1"
        if [ -b "$PARTITION" ]; then
            mkfs.ext4 -L "iscsi-data" "$PARTITION"
        else
            mkfs.ext4 -L "iscsi-data" "${ISCSI_DEVICE}"
            PARTITION="${ISCSI_DEVICE}"
        fi
        
        print_success "Disk formatted"
    else
        print_warning "Skipping format"
        PARTITION="${ISCSI_DEVICE}"
    fi
else
    echo "Disk already has filesystem: ${FSTYPE}"
    PARTITION="${ISCSI_DEVICE}"
    
    # Check for partition
    if [ -b "${ISCSI_DEVICE}1" ]; then
        PARTITION="${ISCSI_DEVICE}1"
    fi
fi

# =============================================================================
# Step 6: Mount disk
# =============================================================================
echo ""
echo "[6/6] Mounting disk..."

# Create mount point
mkdir -p "${MOUNT_POINT}"

# Mount
mount "${PARTITION}" "${MOUNT_POINT}"

print_success "Disk mounted at ${MOUNT_POINT}"

# Add to fstab for persistent mount
DISK_UUID=$(blkid -s UUID -o value "${PARTITION}")

if ! grep -q "${DISK_UUID}" /etc/fstab; then
    echo "UUID=${DISK_UUID} ${MOUNT_POINT} ext4 _netdev,nofail 0 0" >> /etc/fstab
    print_success "Added to /etc/fstab"
fi

# =============================================================================
# Complete
# =============================================================================
echo ""
echo "=== iSCSI Setup Complete ==="
echo ""
echo "Device:      ${ISCSI_DEVICE}"
echo "Mount Point: ${MOUNT_POINT}"
echo "Size:        $(lsblk -n -o SIZE ${ISCSI_DEVICE})"
echo ""
echo "Useful commands:"
echo "  iscsiadm -m session -P 3     # Show session details"
echo "  iscsiadm -m node             # List discovered targets"
echo "  df -h ${MOUNT_POINT}         # Check disk usage"
echo ""
echo "To disconnect:"
echo "  umount ${MOUNT_POINT}"
echo "  iscsiadm -m node -T ${TARGET_IQN} -p ${TARGET_PORTAL} --logout"
