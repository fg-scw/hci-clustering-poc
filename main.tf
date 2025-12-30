################################################################################
# Main Terraform Configuration
# Proxmox Ceph HCI on Scaleway Elastic Metal
################################################################################

locals {
  # Generate node names
  node_names = [for i in range(var.node_count) : "${var.cluster_name}-pve${i + 1}"]

  # Common tags
  common_tags = concat(var.tags, ["cluster:${var.cluster_name}"])
  
  # Load partitioning schema from JSON file
  partitioning_schemas = jsondecode(file("${path.module}/partitioning-schemas.json"))
  
  # Get the selected schema (remove metadata fields starting with _)
  selected_schema = {
    for k, v in local.partitioning_schemas[var.partitioning_mode] : k => v
    if !startswith(k, "_")
  }
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
   partitioning = var.enable_custom_partitioning ? jsonencode(local.selected_schema) : null

  # Service password for Proxmox web UI (root user)
  service_password = var.service_password

  # Enable Private Network option
  options {
    id = data.scaleway_baremetal_option.private_network.option_id
  }

  # Private network attachments (IPs auto-assigned by Scaleway IPAM)
  private_network {
    id = scaleway_vpc_private_network.public.id
  }

  private_network {
    id = scaleway_vpc_private_network.cluster.id
  }

  # Timeouts for bare metal provisioning
  timeouts {
    create = "45m"
    delete = "15m"
  }
    
    ignore_changes = [
      # Ignore changes to SSH keys after creation
      ssh_key_ids,
    ]
  }
}

# =============================================================================
# QDevice Instance 
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

# Fetch assigned IPAM IPs for each server on public network
data "scaleway_ipam_ip" "server_public_ips" {
  count = var.node_count
  
  resource {
    id   = scaleway_baremetal_server.nodes[count.index].id
    type = "baremetal_private_nic"
  }
  private_network_id = scaleway_vpc_private_network.public.id
  type               = "ipv4"
  region             = var.region
  
  depends_on = [scaleway_baremetal_server.nodes]
}

# Fetch assigned IPAM IPs for each server on cluster network
data "scaleway_ipam_ip" "server_cluster_ips" {
  count = var.node_count
  
  resource {
    id   = scaleway_baremetal_server.nodes[count.index].id
    type = "baremetal_private_nic"
  }
  private_network_id = scaleway_vpc_private_network.cluster.id
  type               = "ipv4"
  region             = var.region
  
  depends_on = [scaleway_baremetal_server.nodes]
}

# Local values to extract VLAN IDs and real IPs
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
  
  # Get the actual IPs assigned by IPAM
  actual_public_ips = [
    for i in range(var.node_count) : data.scaleway_ipam_ip.server_public_ips[i].address
  ]
  
  actual_cluster_ips = [
    for i in range(var.node_count) : data.scaleway_ipam_ip.server_cluster_ips[i].address
  ]
  
  # Get server public IPs (Scaleway public, for SSH access)
  server_ssh_ips = [
    for i in range(var.node_count) : [
      for ip in scaleway_baremetal_server.nodes[i].ips : ip.address if ip.version == "IPv4"
    ][0]
  ]
}

# Generate network configuration scripts for each node
resource "local_file" "network_config_scripts" {
  count = var.enable_network_config ? var.node_count : 0

  filename = "${path.module}/generated/configure-network-${count.index + 1}.sh"
  
  content = templatefile("${path.module}/templates/configure-network.sh.tpl", {
    hostname       = local.node_names[count.index]
    public_vlan    = try(local.server_vlans[count.index].public_vlan[0], 0)
    cluster_vlan   = try(local.server_vlans[count.index].cluster_vlan[0], 0)
    public_ip      = local.actual_public_ips[count.index]
    public_cidr    = split("/", var.public_network_subnet)[1]
    cluster_ip     = local.actual_cluster_ips[count.index]
    cluster_cidr   = split("/", var.cluster_network_subnet)[1]
    hosts_entries  = join("\n", [
      for i in range(var.node_count) : 
      "${local.actual_public_ips[i]} ${replace(local.node_names[i], "${var.cluster_name}-", "")}"
    ])
    cluster_hosts  = join("\n", [
      for i in range(var.node_count) : 
      "${local.actual_cluster_ips[i]} ${replace(local.node_names[i], "${var.cluster_name}-", "")}-cluster"
    ])
  })

  depends_on = [
    data.scaleway_ipam_ip.server_public_ips,
    data.scaleway_ipam_ip.server_cluster_ips,
  ]
}

# Configure network on servers using sshpass (requires SSH setup first)
resource "null_resource" "configure_network" {
  count = var.enable_network_config ? var.node_count : 0

  depends_on = [
    null_resource.wait_for_servers,
    local_file.network_config_scripts,
  ]

  triggers = {
    server_id        = scaleway_baremetal_server.nodes[count.index].id
    public_vlan      = try(local.server_vlans[count.index].public_vlan[0], 0)
    cluster_vlan     = try(local.server_vlans[count.index].cluster_vlan[0], 0)
    public_ip        = local.actual_public_ips[count.index]
    cluster_ip       = local.actual_cluster_ips[count.index]
    script_hash      = local_file.network_config_scripts[count.index].content_md5
  }

  # Use local-exec with sshpass to configure network
  # This works even before SSH key auth is configured
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      SERVER_IP="${local.server_ssh_ips[count.index]}"
      SCRIPT_PATH="${local_file.network_config_scripts[count.index].filename}"
      SSH_KEY="${var.ssh_private_key_path}"
      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
      
      echo "Configuring network on $SERVER_IP..."
      
      # Try SSH key first, fall back to sshpass
      if ssh $SSH_OPTS -i "$SSH_KEY" -o BatchMode=yes root@"$SERVER_IP" "echo 'SSH key works'" 2>/dev/null; then
        echo "Using SSH key authentication..."
        scp $SSH_OPTS -i "$SSH_KEY" "$SCRIPT_PATH" root@"$SERVER_IP":/tmp/configure-network.sh
        ssh $SSH_OPTS -i "$SSH_KEY" root@"$SERVER_IP" "chmod +x /tmp/configure-network.sh && /tmp/configure-network.sh"
      elif command -v sshpass &> /dev/null; then
        echo "Using sshpass with service password..."
        sshpass -p "${var.service_password}" scp $SSH_OPTS "$SCRIPT_PATH" root@"$SERVER_IP":/tmp/configure-network.sh
        sshpass -p "${var.service_password}" ssh $SSH_OPTS root@"$SERVER_IP" "chmod +x /tmp/configure-network.sh && /tmp/configure-network.sh"
      else
        echo "ERROR: Neither SSH key auth works nor sshpass is available"
        echo "Please run: ./setup-ssh.sh first, or install sshpass"
        exit 1
      fi
      
      echo "Network configured on $SERVER_IP"
    EOT
    
    environment = {
      # Pass sensitive value via environment to avoid showing in logs
      TF_VAR_service_password = var.service_password
    }
  }
}

# =============================================================================
# Generate Configuration Files
# =============================================================================

# Generate .env file for scripts
resource "local_file" "env_file" {
  count = var.generate_env_file ? 1 : 0

  depends_on = [
    data.scaleway_ipam_ip.server_public_ips,
    data.scaleway_ipam_ip.server_cluster_ips,
  ]

  filename = "${path.root}/../.env.generated"
  content  = <<-EOF
    # Generated by Terraform - ${timestamp()}
    # Proxmox Ceph HCI Configuration

    # Cluster
    CLUSTER_NAME="${var.cluster_name}"

    # Node IPs - Public Network (from IPAM)
    %{for i, ip in local.actual_public_ips~}
    NODE${i + 1}_PUBLIC_IP="${ip}"
    %{endfor~}

    # Node IPs - Cluster Network (from IPAM)
    %{for i, ip in local.actual_cluster_ips~}
    NODE${i + 1}_CLUSTER_IP="${ip}"
    %{endfor~}

    # Node Hostnames
    %{for i, name in local.node_names~}
    NODE${i + 1}_HOSTNAME="${replace(name, "${var.cluster_name}-", "")}"
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
    SERVER${i + 1}_ID="${server.id}"
    %{endfor~}
  EOF

  lifecycle {
    ignore_changes = [content]
  }
}

# Generate Ansible inventory
resource "local_file" "ansible_inventory" {
  count = var.generate_inventory ? 1 : 0

  depends_on = [
    data.scaleway_ipam_ip.server_public_ips,
    data.scaleway_ipam_ip.server_cluster_ips,
  ]

  filename = "${path.root}/../inventory/hosts.ini"
  content  = <<-EOF
    # Generated by Terraform - ${timestamp()}
    # Ansible Inventory for Proxmox Ceph HCI

    [proxmox_nodes]
    %{for i, server in scaleway_baremetal_server.nodes~}
    ${local.node_names[i]} ansible_host=${local.actual_public_ips[i]} ansible_user=root
    %{endfor~}

    [proxmox_nodes:vars]
    ansible_ssh_common_args='-o StrictHostKeyChecking=no'

    [ceph_mons]
    %{for i, server in scaleway_baremetal_server.nodes~}
    ${local.node_names[i]}
    %{endfor~}

    [ceph_osds]
    %{for i, server in scaleway_baremetal_server.nodes~}
    ${local.node_names[i]}
    %{endfor~}

    [ceph_mgrs]
    %{for i, server in scaleway_baremetal_server.nodes~}
    ${local.node_names[i]}
    %{endfor~}

    %{if var.enable_qdevice~}
    [qdevice]
    ${var.cluster_name}-qdevice ansible_host=${var.qdevice_ip} ansible_user=root
    %{endif~}

    [all:vars]
    cluster_name=${var.cluster_name}
    public_network=${var.public_network_subnet}
    cluster_network=${var.cluster_network_subnet}
  EOF

  lifecycle {
    ignore_changes = [content]
  }
}

# Generate hosts file entries
resource "local_file" "hosts_entries" {
  depends_on = [
    data.scaleway_ipam_ip.server_public_ips,
    data.scaleway_ipam_ip.server_cluster_ips,
  ]

  filename = "${path.root}/../config/hosts.generated"
  content  = <<-EOF
    # Generated by Terraform - ${timestamp()}
    # Add these entries to /etc/hosts on each node

    # Proxmox Cluster Nodes - Public Network
    %{for i, ip in local.actual_public_ips~}
    ${ip} ${replace(local.node_names[i], "${var.cluster_name}-", "")}.local ${replace(local.node_names[i], "${var.cluster_name}-", "")}
    %{endfor~}

    # Proxmox Cluster Nodes - Cluster Network
    %{for i, ip in local.actual_cluster_ips~}
    ${ip} ${replace(local.node_names[i], "${var.cluster_name}-", "")}-cluster
    %{endfor~}

    %{if var.enable_qdevice~}
    # QDevice
    ${var.qdevice_ip} qdevice.local qdevice
    %{endif~}
  EOF
}