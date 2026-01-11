#!/bin/bash

################################################################################
# Script 06: Network and Storage Optimizations
# 
# This script applies performance optimizations:
# - Jumbo frames (MTU 9000)
# - Ceph tuning
# - Network kernel parameters
# - RBD cache configuration
#
# Run on: All nodes
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/config.sh"

check_root

print_header "Performance Optimizations"

# =============================================================================
# Step 1: Jumbo Frames
# =============================================================================
print_step "1/5" "Configuring jumbo frames (MTU ${MTU})..."

# Apply immediately
for bridge in "${PUBLIC_BRIDGE}" "${CLUSTER_BRIDGE}"; do
    if ip link show "$bridge" &>/dev/null; then
        current_mtu=$(cat /sys/class/net/${bridge}/mtu)
        if [ "$current_mtu" != "${MTU}" ]; then
            ip link set "$bridge" mtu "${MTU}"
            print_success "${bridge} MTU set to ${MTU}"
        else
            print_success "${bridge} MTU already ${MTU}"
        fi
    fi
done

# Add to interfaces config for persistence
INTERFACES_FILE="/etc/network/interfaces"

if ! grep -q "mtu ${MTU}" "$INTERFACES_FILE" 2>/dev/null; then
    echo ""
    print_warning "Add the following to ${INTERFACES_FILE} for persistence:"
    echo "  # In vmbr1 and vmbr2 sections:"
    echo "  mtu ${MTU}"
    echo ""
    echo "Or add post-up commands:"
    echo "  post-up ip link set \$IFACE mtu ${MTU}"
fi

# =============================================================================
# Step 2: Ceph Tuning
# =============================================================================
print_step "2/5" "Applying Ceph optimizations..."

if [ -f /etc/ceph/ceph.conf ]; then
    # Check if already tuned
    if grep -q "osd_max_write_size" /etc/ceph/ceph.conf; then
        print_warning "Ceph tuning already applied"
    else
        # Backup original
        cp /etc/ceph/ceph.conf /etc/ceph/ceph.conf.bak.$(date +%Y%m%d)
        
        # Add OSD tuning
        cat >> /etc/ceph/ceph.conf << EOF

# Performance tuning - added by optimize script
[osd]
osd_max_write_size = ${OSD_MAX_WRITE_SIZE:-512}
osd_client_message_size_cap = 524288000
osd_deep_scrub_stride = 1048576
osd_op_threads = ${OSD_OP_THREADS:-8}
osd_disk_threads = ${OSD_DISK_THREADS:-4}
osd_recovery_max_active = ${OSD_RECOVERY_MAX_ACTIVE:-3}
osd_max_backfills = ${OSD_MAX_BACKFILLS:-1}

[client]
rbd_cache = ${RBD_CACHE_ENABLED:-true}
rbd_cache_size = ${RBD_CACHE_SIZE:-67108864}
rbd_cache_max_dirty = ${RBD_CACHE_MAX_DIRTY:-50331648}
rbd_cache_target_dirty = 33554432
rbd_cache_writethrough_until_flush = true
EOF
        
        print_success "Ceph configuration updated"
        
        # Restart OSDs to apply
        echo "Restarting OSDs to apply changes..."
        systemctl restart 'ceph-osd@*' || print_warning "Some OSDs may need manual restart"
    fi
else
    print_warning "/etc/ceph/ceph.conf not found. Is Ceph installed?"
fi

# =============================================================================
# Step 3: Network Kernel Parameters
# =============================================================================
print_step "3/5" "Tuning network kernel parameters..."

SYSCTL_FILE="/etc/sysctl.d/99-ceph-performance.conf"

if [ -f "$SYSCTL_FILE" ]; then
    print_warning "Sysctl config already exists: ${SYSCTL_FILE}"
else
    cat > "$SYSCTL_FILE" << 'EOF'
# Ceph and high-performance network tuning

# Increase socket buffer sizes
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432

# TCP buffer sizes
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# Increase backlog
net.core.netdev_max_backlog = 300000
net.core.somaxconn = 65535

# TCP optimizations
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1

# Reduce TCP TIME_WAIT
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Memory pressure
net.ipv4.tcp_mem = 134217728 134217728 134217728
vm.min_free_kbytes = 524288

# Disable IPv6 if not used
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

    # Apply
    sysctl -p "$SYSCTL_FILE"
    print_success "Network parameters applied"
fi

# =============================================================================
# Step 4: I/O Scheduler
# =============================================================================
print_step "4/5" "Configuring I/O scheduler for NVMe..."

# NVMe drives should use 'none' scheduler
for disk in /sys/block/nvme*; do
    if [ -d "$disk" ]; then
        disk_name=$(basename "$disk")
        current_scheduler=$(cat ${disk}/queue/scheduler | grep -oP '\[\K[^\]]+')
        
        if [ "$current_scheduler" != "none" ]; then
            echo "none" > ${disk}/queue/scheduler 2>/dev/null || true
            print_success "${disk_name}: scheduler set to 'none'"
        else
            print_success "${disk_name}: scheduler already 'none'"
        fi
    fi
done

# Make persistent via udev rule
UDEV_RULE="/etc/udev/rules.d/60-nvme-scheduler.rules"
if [ ! -f "$UDEV_RULE" ]; then
    echo 'ACTION=="add|change", KERNEL=="nvme*", ATTR{queue/scheduler}="none"' > "$UDEV_RULE"
    udevadm control --reload-rules
    print_success "NVMe scheduler udev rule created"
fi

# =============================================================================
# Step 5: Verify and Summary
# =============================================================================
print_step "5/5" "Verifying optimizations..."

echo ""
echo "Current Settings:"
echo "-----------------"

echo ""
echo "MTU:"
for bridge in "${PUBLIC_BRIDGE}" "${CLUSTER_BRIDGE}"; do
    if ip link show "$bridge" &>/dev/null; then
        mtu=$(cat /sys/class/net/${bridge}/mtu)
        echo "  ${bridge}: ${mtu}"
    fi
done

echo ""
echo "Ceph RBD Cache:"
ceph config get client.admin rbd_cache 2>/dev/null || echo "  (run on node with ceph.conf)"

echo ""
echo "Network Buffers:"
echo "  rmem_max: $(sysctl -n net.core.rmem_max)"
echo "  wmem_max: $(sysctl -n net.core.wmem_max)"

echo ""
echo "NVMe Schedulers:"
for disk in /sys/block/nvme*; do
    if [ -d "$disk" ]; then
        disk_name=$(basename "$disk")
        scheduler=$(cat ${disk}/queue/scheduler | grep -oP '\[\K[^\]]+')
        echo "  ${disk_name}: ${scheduler}"
    fi
done

# =============================================================================
# Complete
# =============================================================================
print_header "Optimizations Complete"

echo "Applied optimizations:"
echo "  ✓ Jumbo frames (MTU ${MTU})"
echo "  ✓ Ceph OSD and RBD cache tuning"
echo "  ✓ Network kernel parameters"
echo "  ✓ NVMe I/O scheduler"
echo ""
echo "Recommendations:"
echo "  1. Run this script on ALL cluster nodes"
echo "  2. Verify network MTU is consistent across nodes"
echo "  3. Monitor Ceph health after changes: ceph -s"
echo "  4. Reboot nodes during maintenance window for full effect"
echo ""
echo "Benchmark commands:"
echo "  iperf3 -s                    # Start server on one node"
echo "  iperf3 -c <node-ip>          # Test from another node"
echo "  ceph osd perf                # Check OSD performance"
