################################################################################
# Main Terraform Configuration
# Proxmox Ceph HCI on Scaleway Elastic Metal
################################################################################

locals {
  # Generate node names
  node_names = [for i in range(var.node_count) : "${var.cluster_name}-pve${i + 1}"]

  # Common tags
  common_tags = concat(var.tags, ["cluster:${var.cluster_name}"])
  
  # Load partitioning schema from JSON file (standard only)
  partitioning_schema = jsondecode(file("${path.module}/partitioning-schemas.json"))["standard"]
}

# =============================================================================
# VPC
# =============================================================================

resource "scaleway_vpc" "main" {
  name   = "${var.cluster_name}-vpc"
  region = var.region
  tags   = local.common_tags
}

# =============================================================================
# Private Networks
# =============================================================================

# Public Network (Ceph client traffic, MON communication, iSCSI)
resource "scaleway_vpc_private_network" "public" {
  name   = "${var.cluster_name}-public"
  vpc_id = scaleway_vpc.main.id
  region = var.region
  tags   = concat(local.common_tags, ["network:public"])

  ipv4_subnet {
    subnet = var.public_network_subnet
  }
}

# Cluster Network (OSD replication, recovery)
resource "scaleway_vpc_private_network" "cluster" {
  name   = "${var.cluster_name}-cluster"
  vpc_id = scaleway_vpc.main.id
  region = var.region
  tags   = concat(local.common_tags, ["network:cluster"])

  ipv4_subnet {
    subnet = var.cluster_network_subnet
  }
}

# =============================================================================
# Elastic Metal Servers
# =============================================================================

# Private Network option must be enabled for Elastic Metal
# =============================================================================
# IPAM IP Reservations
# Reserve IPs before server creation so we know them in advance
# =============================================================================

resource "scaleway_ipam_ip" "public_ips" {
  count = var.node_count

  address = cidrhost(var.public_network_subnet, 10 + count.index)
  
  source {
    private_network_id = scaleway_vpc_private_network.public.id
  }
  
  tags = ["node:${count.index + 1}", "network:public"]
}

resource "scaleway_ipam_ip" "cluster_ips" {
  count = var.node_count

  address = cidrhost(var.cluster_network_subnet, 10 + count.index)
  
  source {
    private_network_id = scaleway_vpc_private_network.cluster.id
  }
  
  tags = ["node:${count.index + 1}", "network:cluster"]
}

# =============================================================================
# Elastic Metal Servers
# =============================================================================

data "scaleway_baremetal_option" "private_network" {
  zone = var.zone
  name = "Private Network"
}

resource "scaleway_baremetal_server" "nodes" {
  count = var.node_count

  name        = local.node_names[count.index]
  zone        = var.zone
  offer       = data.scaleway_baremetal_offer.selected.offer_id
  os          = var.os_id
  ssh_key_ids = var.ssh_key_ids
  tags        = concat(local.common_tags, ["node:${count.index + 1}"])

  # Custom partitioning - uses JSON schema directly
  # This installs the OS with our custom partition layout
  partitioning = var.enable_custom_partitioning ? jsonencode(local.partitioning_schema) : null

  # Service password for Proxmox web UI (root user)
  service_password = var.service_password

  # Enable Private Network option
  options {
    id = data.scaleway_baremetal_option.private_network.option_id
  }

  # Private network attachments with reserved IPAM IPs
  private_network {
    id          = scaleway_vpc_private_network.public.id
    ipam_ip_ids = [scaleway_ipam_ip.public_ips[count.index].id]
  }

  private_network {
    id          = scaleway_vpc_private_network.cluster.id
    ipam_ip_ids = [scaleway_ipam_ip.cluster_ips[count.index].id]
  }

  # Timeouts for bare metal provisioning
  timeouts {
    create = "45m"
    delete = "15m"
  }

  lifecycle {
    # Prevent accidental destruction
    # prevent_destroy = true
    
    ignore_changes = [
      # Ignore changes to SSH keys after creation
      ssh_key_ids,
    ]
  }
}

# =============================================================================
# QDevice Instance (Optional)
# =============================================================================

resource "scaleway_instance_server" "qdevice" {
  count = var.enable_qdevice ? 1 : 0

  name  = "${var.cluster_name}-qdevice"
  type  = var.qdevice_type
  image = "debian_bookworm"
  zone  = var.zone
  tags  = concat(local.common_tags, ["role:qdevice"])

  # Attach to public network only
  private_network {
    pn_id = scaleway_vpc_private_network.public.id
  }

  # User data for initial configuration
  user_data = {
    cloud-init = <<-EOF
      #cloud-config
      package_update: true
      packages:
        - corosync-qnetd
      runcmd:
        - systemctl enable corosync-qnetd
        - systemctl start corosync-qnetd
    EOF
  }
}

# =============================================================================
# Wait for servers to be ready and configure network
# =============================================================================

resource "null_resource" "wait_for_servers" {
  count = var.node_count

  depends_on = [scaleway_baremetal_server.nodes]

  triggers = {
    server_id = scaleway_baremetal_server.nodes[count.index].id
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for ${local.node_names[count.index]} to be ready..."
      sleep 60
    EOT
  }
}

# =============================================================================
# Configure Network on Servers (Post-Installation)
# =============================================================================

# Local values to extract VLAN IDs and IPs
locals {
  # Convert private_network sets to maps keyed by network ID for each server
  server_vlans = {
    for i in range(var.node_count) : i => {
      public_vlan = [
        for pn in scaleway_baremetal_server.nodes[i].private_network :
        pn.vlan if pn.id == scaleway_vpc_private_network.public.id
      ]
      cluster_vlan = [
        for pn in scaleway_baremetal_server.nodes[i].private_network :
        pn.vlan if pn.id == scaleway_vpc_private_network.cluster.id
      ]
    }
  }
  
  # Get server public IPs (Scaleway public, for SSH/Web access)
  server_ssh_ips = [
    for i in range(var.node_count) : [
      for ip in scaleway_baremetal_server.nodes[i].ips : ip.address if ip.version == "IPv4"
    ][0]
  ]
  
  # Get reserved IPAM IPs (known in advance!)
  public_ips = [
    for i in range(var.node_count) : scaleway_ipam_ip.public_ips[i].address
  ]
  
  cluster_ips = [
    for i in range(var.node_count) : scaleway_ipam_ip.cluster_ips[i].address
  ]
  
  # Private network IDs
  public_network_id  = scaleway_vpc_private_network.public.id
  cluster_network_id = scaleway_vpc_private_network.cluster.id
  
  # Hosts entries for all nodes (full name + short name)
  hosts_entries = join("\n", [
    for i in range(var.node_count) : 
    "${local.public_ips[i]} ${local.node_names[i]} ${replace(local.node_names[i], "${var.cluster_name}-", "")}"
  ])
}

# Generate post-deployment scripts for each node (to run via Proxmox Shell)
# IPs are pre-filled from reserved IPAM IPs
resource "local_file" "post_deploy_scripts" {
  count = var.node_count

  filename        = "${path.module}/generated/post-deploy-pve${count.index + 1}.sh"
  file_permission = "0755"
  
  content = <<-EOF
#!/bin/bash
# Post-deployment script for ${local.node_names[count.index]}
# Run this via Proxmox Shell: https://${local.server_ssh_ips[count.index]}:8006
# Node > Shell > paste this script

set -e

echo "Configuring ${local.node_names[count.index]}..."

# =============================================================================
# CONFIGURATION (pre-filled from Terraform IPAM reservations)
# =============================================================================
PUBLIC_IP="${local.public_ips[count.index]}"
CLUSTER_IP="${local.cluster_ips[count.index]}"
PUBLIC_VLAN="${try(local.server_vlans[count.index].public_vlan[0], "")}"
CLUSTER_VLAN="${try(local.server_vlans[count.index].cluster_vlan[0], "")}"
PUBLIC_CIDR="${split("/", var.public_network_subnet)[1]}"
CLUSTER_CIDR="${split("/", var.cluster_network_subnet)[1]}"

# SSH public key
read -r -d '' SSH_PUBLIC_KEY << 'SSHKEYEOF' || true
${try(file(pathexpand("${var.ssh_private_key_path}.pub")), "# SSH key not found - add manually")}
SSHKEYEOF

# Hosts entries for cluster
HOSTS_ENTRIES="${local.hosts_entries}"

# =============================================================================
# Step 1: Enable SSH
# =============================================================================
echo "[1/4] Enabling SSH..."
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
systemctl restart sshd

# =============================================================================
# Step 2: Fix apt repositories
# =============================================================================
echo "[2/4] Fixing apt repositories..."
rm -f /etc/apt/sources.list.d/pve-no-subscription.list 2>/dev/null || true

# =============================================================================
# Step 3: Configure network
# =============================================================================
echo "[3/4] Configuring network..."

# Find the physical interface that is bridge-port of vmbr0
# Method 1: Parse /etc/network/interfaces (handles multi-line format)
PRIMARY_IF=$(awk '/iface vmbr0/,/^auto|^iface/{if(/bridge-ports/) print $2}' /etc/network/interfaces | head -1)

# Method 2: Check what interface is actually in vmbr0 bridge
if [ -z "$PRIMARY_IF" ]; then
    PRIMARY_IF=$(ls /sys/class/net/vmbr0/brif/ 2>/dev/null | grep -v "^\." | head -1)
fi

# Method 3: Find first physical interface with carrier (link up)
if [ -z "$PRIMARY_IF" ]; then
    for iface in /sys/class/net/en*; do
        ifname=$(basename "$iface")
        if [ -f "$iface/carrier" ] && [ "$(cat $iface/carrier 2>/dev/null)" = "1" ]; then
            PRIMARY_IF="$ifname"
            break
        fi
    done
fi

echo "Detected physical interface: $PRIMARY_IF"

if [ -z "$PRIMARY_IF" ]; then
    echo "ERROR: Could not detect physical interface!"
    echo "Please set PRIMARY_IF manually and re-run, e.g.:"
    echo "  PRIMARY_IF=enp67s0f0"
    exit 1
fi

# Ensure physical interface is set to manual if not already
if ! grep -q "iface $PRIMARY_IF inet manual" /etc/network/interfaces; then
    sed -i "/bridge-ports $PRIMARY_IF/a\\
\\niface $PRIMARY_IF inet manual" /etc/network/interfaces 2>/dev/null || true
fi

# Configure Public VLAN interface if not exists
if ! grep -q "$${PRIMARY_IF}.$${PUBLIC_VLAN}" /etc/network/interfaces; then
    echo "Adding VLAN interface $${PRIMARY_IF}.$${PUBLIC_VLAN}..."
    cat >> /etc/network/interfaces << VLAN1EOF

auto $${PRIMARY_IF}.$${PUBLIC_VLAN}
iface $${PRIMARY_IF}.$${PUBLIC_VLAN} inet manual
VLAN1EOF
fi

# Configure Cluster VLAN interface if not exists
if ! grep -q "$${PRIMARY_IF}.$${CLUSTER_VLAN}" /etc/network/interfaces; then
    echo "Adding VLAN interface $${PRIMARY_IF}.$${CLUSTER_VLAN}..."
    cat >> /etc/network/interfaces << VLAN2EOF

auto $${PRIMARY_IF}.$${CLUSTER_VLAN}
iface $${PRIMARY_IF}.$${CLUSTER_VLAN} inet manual
VLAN2EOF
fi

# Configure vmbr1 (Public Network) if not exists
if ! grep -q "iface vmbr1" /etc/network/interfaces; then
    echo "Adding vmbr1 (Public Network)..."
    cat >> /etc/network/interfaces << VMBR1EOF

# Public Network (Ceph MON, client traffic) - VLAN $${PUBLIC_VLAN}
auto vmbr1
iface vmbr1 inet static
	address $${PUBLIC_IP}/$${PUBLIC_CIDR}
	bridge-ports $${PRIMARY_IF}.$${PUBLIC_VLAN}
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 2-4094
	mtu 1500
#Public Network
VMBR1EOF
else
    echo "vmbr1 already configured"
fi

# Configure vmbr2 (Cluster Network) if not exists
if ! grep -q "iface vmbr2" /etc/network/interfaces; then
    echo "Adding vmbr2 (Cluster Network)..."
    cat >> /etc/network/interfaces << VMBR2EOF

# Cluster Network (Ceph OSD replication) - VLAN $${CLUSTER_VLAN}
auto vmbr2
iface vmbr2 inet static
	address $${CLUSTER_IP}/$${CLUSTER_CIDR}
	bridge-ports $${PRIMARY_IF}.$${CLUSTER_VLAN}
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 2-4094
	mtu 1500
#Cluster Network
VMBR2EOF
else
    echo "vmbr2 already configured"
fi

# =============================================================================
# Step 4: Update /etc/hosts
# =============================================================================
echo "[4/4] Updating /etc/hosts..."
if ! grep -q "# Proxmox Cluster" /etc/hosts; then
cat >> /etc/hosts << HOSTSEOF

# Proxmox Cluster Nodes
$HOSTS_ENTRIES
HOSTSEOF
fi

# =============================================================================
# Apply network configuration
# =============================================================================
echo "Applying network configuration..."

# Create VLAN interfaces immediately if they don't exist
ip link add link $${PRIMARY_IF} name $${PRIMARY_IF}.$${PUBLIC_VLAN} type vlan id $${PUBLIC_VLAN} 2>/dev/null || true
ip link add link $${PRIMARY_IF} name $${PRIMARY_IF}.$${CLUSTER_VLAN} type vlan id $${CLUSTER_VLAN} 2>/dev/null || true
ip link set $${PRIMARY_IF}.$${PUBLIC_VLAN} up 2>/dev/null || true
ip link set $${PRIMARY_IF}.$${CLUSTER_VLAN} up 2>/dev/null || true

# Apply full configuration
ifreload -a 2>/dev/null || systemctl restart networking

echo ""
echo "========================================"
echo "  ${local.node_names[count.index]} configured!"
echo "========================================"
echo ""
echo "SSH: ssh root@${local.server_ssh_ips[count.index]}"
echo "Private IPs: vmbr1=$${PUBLIC_IP}, vmbr2=$${CLUSTER_IP}"
echo "Physical interface: $${PRIMARY_IF}"
echo "VLANs: public=$${PUBLIC_VLAN}, cluster=$${CLUSTER_VLAN}"
echo ""
echo "Verify with: ip a | grep -E 'vmbr1|vmbr2|172.16'"
echo "If no IP on vmbr1/vmbr2, run: reboot"
EOF

  depends_on = [scaleway_baremetal_server.nodes]
}

# =============================================================================
# Generate Configuration Files
# =============================================================================

# Generate .env file for scripts
resource "local_file" "env_file" {
  count = var.generate_env_file ? 1 : 0

  depends_on = [scaleway_baremetal_server.nodes]

  filename = "${path.root}/../.env.generated"
  content  = <<-EOF
    # Generated by Terraform - ${timestamp()}
    # Proxmox Ceph HCI Configuration

    # Cluster
    CLUSTER_NAME="${var.cluster_name}"

    # Node Scaleway Public IPs (for SSH access)
    %{for i, ip in local.server_ssh_ips~}
    NODE${i + 1}_SSH_IP="${ip}"
    %{endfor~}

    # Node Private IPs - Public Network (from IPAM)
    %{for i, ip in local.public_ips~}
    NODE${i + 1}_PUBLIC_IP="${ip}"
    %{endfor~}

    # Node Private IPs - Cluster Network (from IPAM)
    %{for i, ip in local.cluster_ips~}
    NODE${i + 1}_CLUSTER_IP="${ip}"
    %{endfor~}

    # Node Hostnames
    %{for i, name in local.node_names~}
    NODE${i + 1}_HOSTNAME="${replace(name, "${var.cluster_name}-", "")}"
    %{endfor~}

    # VLAN IDs
    %{for i in range(var.node_count)~}
    NODE${i + 1}_PUBLIC_VLAN="${try(local.server_vlans[i].public_vlan[0], "")}"
    NODE${i + 1}_CLUSTER_VLAN="${try(local.server_vlans[i].cluster_vlan[0], "")}"
    %{endfor~}

    # Network Configuration
    PUBLIC_NETWORK="${var.public_network_subnet}"
    CLUSTER_NETWORK="${var.cluster_network_subnet}"
    PUBLIC_BRIDGE="vmbr1"
    CLUSTER_BRIDGE="vmbr2"
    MTU="9000"

    # Ceph Configuration
    OSD_DISKS="nvme1n1 nvme2n1 nvme3n1"
    CEPH_POOL_VM="vm-storage"
    CEPH_POOL_CT="ct-storage"
    CEPH_REPLICA_SIZE="3"
    CEPH_MIN_SIZE="2"

    # QDevice
    QDEVICE_ENABLED="${var.enable_qdevice}"
    QDEVICE_IP="${var.qdevice_ip}"

    # Server IDs (for reference)
    %{for i, server in scaleway_baremetal_server.nodes~}
    NODE${i + 1}_ID="${server.id}"
    %{endfor~}
  EOF

  lifecycle {
    ignore_changes = [content]
  }
}

# Generate Ansible inventory (YAML format for lae.proxmox role)
resource "local_file" "ansible_inventory" {
  count = var.generate_inventory ? 1 : 0

  depends_on = [scaleway_baremetal_server.nodes]

  filename = "${path.root}/../ansible/inventory/hosts.yml"
  content  = <<-EOF
---
# Generated by Terraform - ${timestamp()}
# Ansible Inventory for Proxmox Ceph HCI
# Compatible with lae.proxmox role
all:
  children:
    proxmox:
      hosts:
%{for i, server in scaleway_baremetal_server.nodes~}
        ${local.node_names[i]}:
          ansible_host: ${local.server_ssh_ips[i]}
          pve_cluster_addr0: ${local.public_ips[i]}
          pve_cluster_addr1: ${local.cluster_ips[i]}
          ceph_osd_devices:
            - /dev/nvme1n1
            - /dev/nvme2n1
            - /dev/nvme3n1
%{endfor~}
      vars:
        ansible_user: root
        ansible_python_interpreter: /usr/bin/python3
        ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
EOF

  lifecycle {
    ignore_changes = [content]
  }
}

# Generate Ansible group_vars
resource "local_file" "ansible_group_vars" {
  count = var.generate_inventory ? 1 : 0

  depends_on = [scaleway_baremetal_server.nodes]

  filename = "${path.root}/../ansible/inventory/group_vars/proxmox.yml"
  content  = <<-EOF
---
# Generated by Terraform - ${timestamp()}
# Group variables for Proxmox cluster

# =============================================================================
# Proxmox Cluster Configuration
# =============================================================================
pve_group: proxmox
pve_cluster_enabled: true
pve_cluster_clustername: ${var.cluster_name}

pve_reboot_on_kernel_update: false
pve_repository_line: "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"
pve_remove_subscription_warning: true

pve_extra_packages:
  - ifupdown2
  - vim
  - htop

# =============================================================================
# Network Configuration (from Scaleway)
# =============================================================================
public_network: "${var.public_network_subnet}"
cluster_network: "${var.cluster_network_subnet}"
public_vlan: ${try(local.server_vlans[0].public_vlan[0], 0)}
cluster_vlan: ${try(local.server_vlans[0].cluster_vlan[0], 0)}

# =============================================================================
# Ceph Configuration
# =============================================================================
pve_ceph_enabled: true
pve_ceph_repository_line: "deb http://download.proxmox.com/debian/ceph-reef bookworm main"
pve_ceph_network: "{{ public_network }}"
pve_ceph_cluster_network: "{{ cluster_network }}"

pve_ceph_pools:
  - name: ceph-pool
    pgs: 128
    rule: replicated_rule
    application: rbd
    storage: true
    size: 3
    min_size: 2

# =============================================================================
# Datacenter Configuration
# =============================================================================
pve_datacenter_cfg:
  keyboard: fr
  console: html5
EOF

  lifecycle {
    ignore_changes = [content]
  }
}

# Generate hosts file entries
resource "local_file" "hosts_entries" {
  depends_on = [scaleway_baremetal_server.nodes]

  filename = "${path.root}/../config/hosts.generated"
  content  = <<-EOF
    # Generated by Terraform - ${timestamp()}
    # Add these entries to /etc/hosts on each node

    # Proxmox Cluster Nodes - Public Network (vmbr1)
    %{for i, ip in local.public_ips~}
    ${ip} ${local.node_names[i]} ${replace(local.node_names[i], "${var.cluster_name}-", "")}
    %{endfor~}

    # Proxmox Cluster Nodes - Cluster Network (vmbr2)
    %{for i, ip in local.cluster_ips~}
    ${ip} ${replace(local.node_names[i], "${var.cluster_name}-", "")}-cluster
    %{endfor~}

    %{if var.enable_qdevice~}
    # QDevice
    ${var.qdevice_ip} qdevice.local qdevice
    %{endif~}
  EOF
}
