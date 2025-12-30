################################################################################
# Terraform Outputs
# Useful information after provisioning
################################################################################

# =============================================================================
# VPC Outputs
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC"
  value       = scaleway_vpc.main.id
}

output "vpc_name" {
  description = "Name of the VPC"
  value       = scaleway_vpc.main.name
}

# =============================================================================
# Private Network Outputs
# =============================================================================

output "public_network_id" {
  description = "ID of the public private network"
  value       = scaleway_vpc_private_network.public.id
}

output "cluster_network_id" {
  description = "ID of the cluster private network"
  value       = scaleway_vpc_private_network.cluster.id
}

output "public_network_subnet" {
  description = "Subnet of the public network"
  value       = var.public_network_subnet
}

output "cluster_network_subnet" {
  description = "Subnet of the cluster network"
  value       = var.cluster_network_subnet
}

# =============================================================================
# Server Outputs
# =============================================================================

output "server_ids" {
  description = "IDs of all Elastic Metal servers"
  value       = scaleway_baremetal_server.nodes[*].id
}

output "server_names" {
  description = "Names of all servers"
  value       = local.node_names
}

output "server_ips_public" {
  description = "Server IPs on public network (from IPAM)"
  value       = local.actual_public_ips
}

output "server_ips_cluster" {
  description = "Server IPs on cluster network (from IPAM)"
  value       = local.actual_cluster_ips
}

output "server_details" {
  description = "Detailed server information"
  value = {
    for i, server in scaleway_baremetal_server.nodes : local.node_names[i] => {
      id              = server.id
      name            = server.name
      offer           = server.offer
      public_ip       = local.actual_public_ips[i]
      cluster_ip      = local.actual_cluster_ips[i]
      public_vlan     = try(local.server_vlans[i].public_vlan[0], null)
      cluster_vlan    = try(local.server_vlans[i].cluster_vlan[0], null)
      private_network_ids = [for pn in server.private_network : pn.id]
    }
  }
}

# =============================================================================
# QDevice Outputs
# =============================================================================

output "qdevice_id" {
  description = "ID of the QDevice instance"
  value       = var.enable_qdevice ? scaleway_instance_server.qdevice[0].id : null
}

output "qdevice_ip" {
  description = "IP of the QDevice"
  value       = var.enable_qdevice ? var.qdevice_ip : null
}

# =============================================================================
# Connection Information
# =============================================================================

output "ssh_commands" {
  description = "SSH commands to connect to nodes"
  value = {
    for i, server in scaleway_baremetal_server.nodes :
    local.node_names[i] => "ssh root@${[for ip in server.ips : ip.address if ip.version == "IPv4"][0]}"
  }
}

output "proxmox_urls" {
  description = "Proxmox Web UI URLs"
  value = {
    for i, server in scaleway_baremetal_server.nodes :
    local.node_names[i] => "https://${[for ip in server.ips : ip.address if ip.version == "IPv4"][0]}:8006"
  }
}

# =============================================================================
# Configuration Summary
# =============================================================================

output "cluster_summary" {
  description = "Summary of the cluster configuration"
  value = {
    cluster_name    = var.cluster_name
    region          = var.region
    zone            = var.zone
    node_count      = var.node_count
    server_type     = var.server_type
    public_network  = var.public_network_subnet
    cluster_network = var.cluster_network_subnet
    qdevice_enabled = var.enable_qdevice
  }
}

# =============================================================================
# Next Steps
# =============================================================================

output "next_steps" {
  description = "Next steps after Terraform apply"
  value       = <<-EOT

    ============================================================
    Proxmox Ceph HCI Cluster Deployed!
    ============================================================

    Servers are installing with custom partitioning. This takes 10-15 minutes.
    
    Monitor progress:
      scw baremetal server list zone=${var.zone}

    Once status is 'ready':

    1. Setup SSH access (run once after servers are ready):
       ./setup-ssh.sh

    2. Re-run terraform to configure network:
       terraform apply

    3. Run deployment scripts:
       cd ..
       cp .env.generated .env
       
       # On each node:
       ./scripts/proxmox/01-initial-setup.sh
       
       # On first node only:
       ./scripts/proxmox/02-create-cluster.sh
       
       # On other nodes:
       ./scripts/proxmox/02-create-cluster.sh
       
       # On first node:
       ./scripts/proxmox/03-install-ceph.sh

    4. Access Proxmox Web UI:
       terraform output proxmox_urls
       Username: root
       Password: (from terraform.tfvars service_password)

    ============================================================
  EOT
}

# =============================================================================
# Export for Scripts
# =============================================================================

output "env_file_path" {
  description = "Path to generated .env file"
  value       = var.generate_env_file ? abspath("${path.root}/../.env.generated") : null
}

output "inventory_file_path" {
  description = "Path to generated Ansible inventory"
  value       = var.generate_inventory ? abspath("${path.root}/../inventory/hosts.ini") : null
}

# =============================================================================
# Custom Partitioning Outputs
# =============================================================================

output "custom_partitioning_enabled" {
  description = "Whether custom partitioning is enabled"
  value       = var.enable_custom_partitioning
}

output "partitioning_mode" {
  description = "Selected partitioning mode"
  value       = var.partitioning_mode
}

output "partitioning_schema" {
  description = "Partitioning schema applied to servers"
  value       = var.enable_custom_partitioning ? local.selected_schema : null
}

# =============================================================================
# Network Configuration Outputs
# =============================================================================

output "vlan_ids" {
  description = "VLAN IDs assigned to each server"
  value = {
    for i, server in scaleway_baremetal_server.nodes : local.node_names[i] => {
      public_vlan  = try([for pn in server.private_network : pn.vlan if pn.id == scaleway_vpc_private_network.public.id][0], null)
      cluster_vlan = try([for pn in server.private_network : pn.vlan if pn.id == scaleway_vpc_private_network.cluster.id][0], null)
    }
  }
}

output "server_public_ips" {
  description = "Public IPv4 addresses of servers (for SSH access)"
  value = {
    for i, server in scaleway_baremetal_server.nodes : local.node_names[i] => 
    try([for ip in server.ips : ip.address if ip.version == "IPv4"][0], null)
  }
}

output "server_private_ips" {
  description = "Private IPs assigned by IPAM on each network"
  value = {
    for i in range(var.node_count) : local.node_names[i] => {
      public_network  = local.actual_public_ips[i]
      cluster_network = local.actual_cluster_ips[i]
    }
  }
}
