#!/bin/bash
################################################################################
# Proxmox Post-Deployment Setup
# Run this script via Proxmox Shell (Web UI > Node > Shell)
# 
# This script:
# 1. Enables SSH root login
# 2. Configures network interfaces (VLAN bridges)
# 3. Updates /etc/hosts
# 4. Removes duplicate apt repositories
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "========================================"
echo "  Proxmox Post-Deployment Setup"
echo "========================================"
echo

# =============================================================================
# CONFIGURATION - Edit these values from Terraform outputs
# =============================================================================

# Get from: terraform output server_private_ips
PUBLIC_IP="${PUBLIC_IP:-}"
CLUSTER_IP="${CLUSTER_IP:-}"

# Get from: terraform output vlan_ids
PUBLIC_VLAN="${PUBLIC_VLAN:-}"
CLUSTER_VLAN="${CLUSTER_VLAN:-}"

# Network settings
PUBLIC_CIDR="${PUBLIC_CIDR:-22}"
CLUSTER_CIDR="${CLUSTER_CIDR:-22}"

# Hosts entries (all nodes)
HOSTS_ENTRIES="${HOSTS_ENTRIES:-}"

# SSH public key (optional - for key-based auth)
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"

# =============================================================================
# Validation
# =============================================================================

if [ -z "$PUBLIC_IP" ] || [ -z "$CLUSTER_IP" ] || [ -z "$PUBLIC_VLAN" ] || [ -z "$CLUSTER_VLAN" ]; then
    log_error "Missing required configuration!"
    echo ""
    echo "Usage: Set environment variables before running:"
    echo ""
    echo "  export PUBLIC_IP='172.16.28.5'"
    echo "  export CLUSTER_IP='172.16.36.5'"
    echo "  export PUBLIC_VLAN='2243'"
    echo "  export CLUSTER_VLAN='2462'"
    echo "  export HOSTS_ENTRIES='172.16.28.5 pve1"
    echo "172.16.28.6 pve2"
    echo "172.16.28.7 pve3'"
    echo "  export SSH_PUBLIC_KEY='ssh-rsa AAAA... user@host'"
    echo ""
    echo "Then run: ./post-deploy.sh"
    exit 1
fi

# =============================================================================
# Step 1: Enable SSH
# =============================================================================

log_info "Step 1: Enabling SSH root login..."

# Backup sshd_config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Enable PermitRootLogin
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# Ensure PubkeyAuthentication is enabled
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Add SSH public key if provided
if [ -n "$SSH_PUBLIC_KEY" ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    if ! grep -qF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        log_info "SSH public key added"
    fi
fi

# Restart SSH
systemctl restart sshd
log_info "SSH enabled"

# =============================================================================
# Step 2: Fix duplicate apt repositories
# =============================================================================

log_info "Step 2: Fixing apt repositories..."

# Remove duplicate pve-no-subscription if exists
if [ -f /etc/apt/sources.list.d/pve-no-subscription.list ]; then
    rm -f /etc/apt/sources.list.d/pve-no-subscription.list
    log_info "Removed duplicate pve-no-subscription.list"
fi

# =============================================================================
# Step 3: Configure network interfaces
# =============================================================================

log_info "Step 3: Configuring network interfaces..."

# Detect primary interface
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$PRIMARY_IF" ]; then
    PRIMARY_IF=$(ip link | grep -E '^[0-9]+: (en|eth)' | head -1 | cut -d: -f2 | tr -d ' ')
fi

# If primary is a bridge, get the underlying interface
if [[ "$PRIMARY_IF" == vmbr* ]]; then
    PRIMARY_IF=$(grep -A5 "iface $PRIMARY_IF" /etc/network/interfaces | grep bridge-ports | awk '{print $2}')
fi

log_info "Primary interface: $PRIMARY_IF"

# Backup current config
cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%Y%m%d%H%M%S)

# Check if VLAN interfaces already exist
if grep -q "vmbr1" /etc/network/interfaces; then
    log_warn "vmbr1 already configured, skipping..."
else
    # Add VLAN and bridge configuration
    cat >> /etc/network/interfaces << EOF

# Public Network (Ceph MON, client traffic)
auto ${PRIMARY_IF}.${PUBLIC_VLAN}
iface ${PRIMARY_IF}.${PUBLIC_VLAN} inet manual

auto vmbr1
iface vmbr1 inet static
    address ${PUBLIC_IP}/${PUBLIC_CIDR}
    bridge-ports ${PRIMARY_IF}.${PUBLIC_VLAN}
    bridge-stp off
    bridge-fd 0
    mtu 9000
#Public Network

# Cluster Network (Ceph OSD replication)
auto ${PRIMARY_IF}.${CLUSTER_VLAN}
iface ${PRIMARY_IF}.${CLUSTER_VLAN} inet manual

auto vmbr2
iface vmbr2 inet static
    address ${CLUSTER_IP}/${CLUSTER_CIDR}
    bridge-ports ${PRIMARY_IF}.${CLUSTER_VLAN}
    bridge-stp off
    bridge-fd 0
    mtu 9000
#Cluster Network
EOF
    log_info "Network interfaces configured"
fi

# =============================================================================
# Step 4: Update /etc/hosts
# =============================================================================

log_info "Step 4: Updating /etc/hosts..."

if [ -n "$HOSTS_ENTRIES" ]; then
    # Add marker and entries if not present
    if ! grep -q "# Proxmox Cluster" /etc/hosts; then
        cat >> /etc/hosts << EOF

# Proxmox Cluster Nodes
$HOSTS_ENTRIES
EOF
        log_info "/etc/hosts updated"
    else
        log_warn "/etc/hosts already has cluster entries"
    fi
fi

# =============================================================================
# Step 5: Apply network configuration
# =============================================================================

log_info "Step 5: Applying network configuration..."

# Reload network
if command -v ifreload &> /dev/null; then
    ifreload -a
else
    systemctl restart networking
fi

# Wait for interfaces
sleep 3

# =============================================================================
# Summary
# =============================================================================

echo
echo "========================================"
echo "  Setup Complete!"
echo "========================================"
echo
echo "Network Configuration:"
ip -br addr show vmbr1 2>/dev/null || echo "  vmbr1: Not up yet (reboot may be required)"
ip -br addr show vmbr2 2>/dev/null || echo "  vmbr2: Not up yet (reboot may be required)"
echo
echo "SSH is now enabled. You can connect with:"
echo "  ssh root@$(hostname -I | awk '{print $1}')"
echo
echo "If network interfaces don't show IPs, reboot the server:"
echo "  reboot"
echo
