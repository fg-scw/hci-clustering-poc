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